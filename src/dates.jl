@inline function xparse(::Type{T}, source::IO, pos, len, options::Options) where {T <: Dates.TimeType}
    _, _code, vpos, vlen, tlen = xparse(String, source, pos, len, options)
    fastseek!(source, pos - 1)
    bytes = Vector{UInt8}(undef, tlen)
    tlen > 0 && readbytes!(source, bytes)
    return xparse(T, bytes, 1, tlen, options)
end

@inline function typeparser(::Type{T}, source, pos, len, b, code, options::Options) where {T <: Dates.TimeType}
    df = options.dateformat === nothing ? Dates.default_format(T) : options.dateformat
    ret = mytryparsenext_internal(T, source, Int(pos), len, df)
    # if debug
    #     if ret === nothing
    #         println("failed to parse $T")
    #     else
    #         println("parsed: $ret")
    #     end
    # end
    if ret === nothing
        x = default(T)
        code |= INVALID
    else
        values, pos = ret
        valid = Dates.validargs(T, values...)
        if valid !== nothing
            x = default(T)
            code |= INVALID
        else
            x = T(values...)
            code |= OK
        end
        if eof(source, pos, len)
            code |= EOF
        end
    end

    return x, code, pos
end

@generated function mytryparsenext_internal(::Type{T}, str, pos, len, df::DateFormat) where {T <: Dates.TimeType}
    letters = Dates.character_codes(df)

    tokens = Type[Dates.CONVERSION_SPECIFIERS[letter] for letter in letters]
    value_names = Symbol[Dates.genvar(t) for t in tokens]

    output_tokens = Dates.CONVERSION_TRANSLATIONS[T]
    output_names = Symbol[Dates.genvar(t) for t in output_tokens]
    output_defaults = Tuple(Dates.CONVERSION_DEFAULTS[t] for t in output_tokens)

    assign_defaults = Expr[
        quote
            $name = $default
        end
        for (name, default) in zip(output_names, output_defaults)
    ]
    value_tuple = Expr(:tuple, value_names...)

    return quote
        $(Expr(:meta, :inline))
        val = mytryparsenext_core(str, pos, len, df)
        val === nothing && return nothing
        values, pos, num_parsed = val
        $(assign_defaults...)
        $value_tuple = values
        return $(Expr(:tuple, output_names...)), pos
    end
end

@generated function mytryparsenext_core(str, pos, len, df::DateFormat)
    directives = Dates._directives(df)
    letters = Dates.character_codes(directives)

    tokens = Type[Dates.CONVERSION_SPECIFIERS[letter] for letter in letters]
    value_names = Symbol[Dates.genvar(t) for t in tokens]
    value_defaults = Tuple(Dates.CONVERSION_DEFAULTS[t] for t in tokens)

    assign_defaults = Expr[]
    for (name, default) in zip(value_names, value_defaults)
        push!(assign_defaults, quote
            $name = $default
        end)
    end

    vi = 1
    parsers = Expr[]
    for i = 1:length(directives)
        if directives[i] <: Dates.DatePart
            name = value_names[vi]
            vi += 1
            push!(parsers, quote
                pos > len && @goto done
                let val = Dates.tryparsenext(directives[$i], str, pos, len, locale)
                    if val === nothing
                        $i > 1 && @goto done
                        @goto error
                    end
                    $name, pos = val
                    if $name isa Integer
                        $name = Int64($name)
                    end
                end
                num_parsed += 1
                directive_index += 1
            end)
        else
            push!(parsers, quote
                pos > len && @goto done
                let val = Dates.tryparsenext(directives[$i], str, pos, len, locale)
                    if val === nothing
                        $i > 1 && @goto done
                        @goto error
                    end
                    delim, pos = val
                end
                directive_index += 1
            end)
        end
    end

    return quote
        $(Expr(:meta, :inline))
        directives = df.tokens
        locale::Dates.DateLocale = df.locale
        num_parsed = 0
        directive_index = 1
        $(assign_defaults...)
        $(parsers...)
        @label done
        return $(Expr(:tuple, value_names...)), pos, num_parsed
        @label error
        return nothing
    end
end

@inline function Dates.tryparsenext(d::Dates.Delim{<:AbstractChar, N}, str::AbstractVector{UInt8}, i::Int, len) where N
    for j = 1:N
        i > len && return nothing
        next = iterate(str, i)
        @assert next !== nothing
        c, i = next
        c != UInt8(d.d) && return nothing
    end
    return true, i
end

@inline function Dates.tryparsenext(d::Dates.Delim{String, N}, str::AbstractVector{UInt8}, i::Int, len) where N
    i1 = i
    i2 = firstindex(d.d)
    for j = 1:N
        if i1 > len
            return nothing
        end
        next1 = iterate(str, i1)
        @assert next1 !== nothing
        c1, i1 = next1
        next2 = iterate(d.d, i2)
        @assert next2 !== nothing
        c2, i2 = next2
        if c1 != UInt8(c2)
            return nothing
        end
    end
    return true, i1
end

ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

function Dates.tryparsenext(d::Dates.DatePart{'p'}, str::AbstractVector{UInt8}, i::Int, len)
    i+1 > len && return nothing
    c, ii = iterate(str, i)::Tuple{UInt8, Int}
    ap = ascii_lc(c)
    (ap == UInt8('a') || ap == UInt8('p')) || return nothing
    c, ii = iterate(str, ii)::Tuple{UInt8, Int}
    ascii_lc(c) == UInt8('m') || return nothing
    return ap == UInt8('a') ? Dates.AM : Dates.PM, ii
end

@inline function Dates.tryparsenext_base10(str::AbstractVector{UInt8}, i, len, min_width=1, max_width=0)
    i > len && return nothing
    min_pos = min_width <= 0 ? i : i + min_width - 1
    max_pos = max_width <= 0 ? len : min(i + max_width - 1, len)
    d::Int64 = 0
    @inbounds while i <= max_pos
        c, ii = iterate(str, i)
        if UInt8('0') <= c <= UInt8('9')
            d = d * 10 + (c - UInt8('0'))
        else
            break
        end
        i = ii
    end
    if i <= min_pos
        return nothing
    else
        return d, i
    end
end

@inline function Dates.tryparsenext_word(str::AbstractVector{UInt8}, i, len, locale, maxchars=0)
    word_start, word_end = i, 0
    max_pos = maxchars <= 0 ? len : min(len, i + (maxchars-1))
    @inbounds while i <= max_pos
        c, ii = iterate(str, i)
        if isletter(Char(c))
            word_end = i
        else
            break
        end
        i = ii
    end
    if word_end == 0
        return nothing
    else
        return unsafe_string(pointer(str, word_start), word_end - word_start + 1), i
    end
end
