#!/usr/bin/env julia
using Luxor
using Colors

# ==============================================================================
# 1. PROJECTIVE GEOMETRY CORE (HPoint & HLine) & RGB COLOUR TYPE
# ==============================================================================
struct HPoint
    x::Float64
    y::Float64
    w::Float64
end
HPoint(x, y) = HPoint(Float64(x), Float64(y), 1.0)

struct HLine
    a::Float64
    b::Float64
    c::Float64
end

struct Col3
    r::Float64
    g::Float64
    b::Float64
end
Col3(v::Real) = Col3(Float64(v), Float64(v), Float64(v))

function parse_colour_name(name::AbstractString)
    c = parse(RGB, strip(name))
    return Col3(Float64(c.r), Float64(c.g), Float64(c.b))
end

function to_luxor(p::HPoint)
    w = abs(p.w) < 1e-6 ? (p.w >= 0 ? 1e-6 : -1e-6) : p.w
    return Luxor.Point(p.x / w, p.y / w)
end

lerp_pt(p0::HPoint, t::Real, p1::HPoint) = HPoint(
    (1 - t) * (p0.x / p0.w) + t * (p1.x / p1.w),
    (1 - t) * (p0.y / p0.w) + t * (p1.y / p1.w)
)

function step_perp(p0::HPoint, t::Real, p1::HPoint, turn::Int, s::Real)
    x0, y0 = p0.x / p0.w, p0.y / p0.w
    x1, y1 = p1.x / p1.w, p1.y / p1.w
    dx, dy = x1 - x0, y1 - y0
    return HPoint(x0 + t * dx + turn * s * (-dy), y0 + t * dy + turn * s * dx)
end

function par_pt(p0::HPoint, p1::HPoint, p2::HPoint)
    x0, y0 = p0.x / p0.w, p0.y / p0.w
    x1, y1 = p1.x / p1.w, p1.y / p1.w
    x2, y2 = p2.x / p2.w, p2.y / p2.w
    return HPoint(x2 + (x1 - x0), y2 + (y1 - y0))
end

make_line(p1::HPoint, p2::HPoint) = HLine(
    p1.y * p2.w - p1.w * p2.y,
    p1.w * p2.x - p1.x * p2.w,
    p1.x * p2.y - p1.y * p2.x
)

intersect_lines(l1::HLine, l2::HLine) = HPoint(
    l1.b * l2.c - l1.c * l2.b,
    l1.c * l2.a - l1.a * l2.c,
    l1.a * l2.b - l1.b * l2.a
)

function perp_line(l::HLine, p::HPoint)
    x, y = p.x / p.w, p.y / p.w
    return HLine(-l.b, l.a, l.b * x - l.a * y)
end

function reflect_pt(p::HPoint, l::HLine)
    x, y = p.x / p.w, p.y / p.w
    denom = l.a^2 + l.b^2
    denom < 1e-12 && return p
    d = (l.a * x + l.b * y + l.c) / denom
    return HPoint(x - 2 * l.a * d, y - 2 * l.b * d)
end

shift_rgb(c::Col3, dr, dg, db) = Col3(
    clamp(c.r + dr, 0.0, 1.0),
    clamp(c.g + dg, 0.0, 1.0),
    clamp(c.b + db, 0.0, 1.0)
)
invert_rgb(c::Col3) = Col3(1.0 - c.r, 1.0 - c.g, 1.0 - c.b)
rot_rgb(c::Col3)    = Col3(c.g, c.b, c.r)
rot2_rgb(c::Col3)   = Col3(c.b, c.r, c.g)
rand_col()          = Col3(rand(), rand(), rand())

# ==============================================================================
# 2. PARSING HELPERS
# ==============================================================================
tok(v, idx::Int) = getindex(v, idx)
parse_pt_idx(s::AbstractString) = parse(Int, match(r"\d+", s).match)
is_num(s::AbstractString) = occursin(r"^-?(\d+\.?\d*|\.\d+)$", s)

function parse_fract_expr(s::AbstractString)
    if s == "rand"
        return :(rand())
    elseif s == "crand"
        return rand()
    elseif occursin("/", s)
        parts = split(s, "/")
        return parse(Float64, first(parts)) / parse(Float64, last(parts))
    else
        return parse(Float64, s)
    end
end

function expand_verts(vtoks::Vector{String})
    syms = Symbol[]
    for t in vtoks
        if startswith(t, ":")
            for ch in t[2:end]
                push!(syms, ch == 'c' ? :c : Symbol("p", ch))
            end
        elseif occursin("..", t)
            parts = split(replace(t, r"^[pP]" => ""), r"\.\.+")
            a, b = parse(Int, first(parts)), parse(Int, last(parts))
            for i in a:b
                push!(syms, Symbol("p", i))
            end
        else
            for sub in split(t, ',', keepempty = false)
                push!(syms, Symbol("p", parse_pt_idx(sub)))
            end
        end
    end
    return syms
end

# ==============================================================================
# 3. COMPILER: .SDV SOURCE -> NATIVE JULIA FUNCTIONS
# ==============================================================================
function compile_sdv(source::String)
    init_pts = HPoint[]
    bg_col = nothing
    line_width = 0.25
    no_edges = false
    only_edges = false
    margins = [5.0, 5.0, 5.0, 5.0] # left, top, right, bottom

    shape_exprs = Expr[]
    known_shapes = Set{Symbol}([:draw])
    main_shape = nothing
    current_shape = nothing
    current_n = 0
    default_calls = Expr[]
    branch_mode = nothing
    branch_val = 0
    branched_calls = Expr[]
    point_stmts = Expr[]
    shape_col_expr = nothing
    uses_centre = false
    last_fract_expr = 0.5

    # Pass 1: collect all shape names
    for raw in split(source, '\n')
        line = strip(first(split(raw, r"(#|//|%)")))
        isempty(line) && continue
        toks = String.(split(line))
        if first(toks) == "def" && length(toks) >= 2
            sname = Symbol(tok(toks, 2))
            push!(known_shapes, sname)
            main_shape === nothing && (main_shape = sname)
        end
    end

    function flush_shape!()
        current_shape === nothing && return
        args = [Symbol("p", i) for i in 0:(current_n - 1)]
        centre_expr = uses_centre ? :(c = HPoint(
            sum(p.x / p.w for p in [$(args...)]) / $current_n,
            sum(p.y / p.w for p in [$(args...)]) / $current_n
        )) : :()
        col_init = shape_col_expr === nothing ? :() : :(col = $shape_col_expr)
        leaf_draw = :(draw(step, max_level, dir, col, $(args...)))

        call_block = if branch_mode === nothing
            isempty(default_calls) ? leaf_draw : quote $(default_calls...) end
        elseif branch_mode == :gt
            cond = branch_val >= 0 ? :(step > $branch_val) : :(rem <= $(-branch_val - 1))
            quote
                if $cond
                    $(branched_calls...)
                else
                    $(default_calls...)
                end
            end
        else # branch_mode == :eq
            cond = branch_val >= 0 ? :(step == $branch_val) : :(rem == $(-branch_val - 1))
            quote
                if $cond
                    $(branched_calls...)
                else
                    $(default_calls...)
                end
            end
        end

        fn = quote
            function $current_shape(step::Int, max_level::Int, dir::Int, col::Col3, $(args...))
                step > max_level && return
                rem = max_level - step
                $col_init
                $(point_stmts...)
                $centre_expr
                if rem == 0 && $(branch_mode != :eq)
                    $leaf_draw
                    return
                end
                $call_block
            end
        end

        push!(shape_exprs, fn)
    end

   for raw in split(source, '\n')
        line = strip(first(split(raw, r"(#|//|%)")))
        isempty(line) && continue
        toks = String.(split(line))
        head = first(toks)

        if head == "levels" || head == "srand"
            continue
        elseif head == "width"
            line_width = parse(Float64, tok(toks, 2))
        elseif head == "margin"
            if length(toks) == 2
                m = parse(Float64, tok(toks, 2))
                margins .= m
            elseif length(toks) == 3
                mx, my = parse(Float64, tok(toks, 2)), parse(Float64, tok(toks, 3))
                margins .= [mx, my, mx, my]
            elseif length(toks) >= 5
                margins .= [parse(Float64, tok(toks, k)) for k in 2:5]
            end
        elseif head == "noedges" || (head == "no" && length(toks) >= 2 && tok(toks, 2) == "edges")
            no_edges = true
        elseif head == "onlyedges" || (head == "only" && length(toks) >= 2 && tok(toks, 2) == "edges")
            only_edges = true
        elseif head in ("background", "boxcolour", "boxcolor")
            if length(toks) == 2 && is_num(tok(toks, 2))
                bg_col = Col3(parse(Float64, tok(toks, 2)))
            elseif length(toks) == 4 && all(is_num, toks[2:4])
                bg_col = Col3(parse(Float64, tok(toks, 2)), parse(Float64, tok(toks, 3)), parse(Float64, tok(toks, 4)))
            else
                bg_col = parse_colour_name(join(toks[2:end], " "))
            end
        elseif head == "pbox"
            if length(toks) == 1
                append!(init_pts, [HPoint(0, 0), HPoint(100, 0), HPoint(100, 100), HPoint(0, 100)])
            elseif length(toks) == 3
                w, h = parse(Float64, tok(toks, 2)), parse(Float64, tok(toks, 3))
                append!(init_pts, [HPoint(0, 0), HPoint(w, 0), HPoint(w, h), HPoint(0, h)])
            elseif length(toks) >= 5
                x1, y1, x2, y2 = [parse(Float64, tok(toks, k)) for k in 2:5]
                append!(init_pts, [HPoint(x1, y1), HPoint(x2, y1), HPoint(x2, y2), HPoint(x1, y2)])
            end
        elseif head == "pgon" || head == "polygon"
            n, r = parse(Int, tok(toks, 2)), parse(Float64, tok(toks, 3))
            ang0 = length(toks) >= 4 ? parse(Float64, tok(toks, 4)) * pi / 180 : 0.0
            for i in 0:(n - 1)
                push!(init_pts, HPoint(r * cos(ang0 + 2pi * i / n), r * sin(ang0 + 2pi * i / n)))
            end
        elseif head == "def"
            flush_shape!()
            current_shape = Symbol(tok(toks, 2))
            current_n = parse(Int, tok(toks, 3))
            empty!(default_calls); empty!(branched_calls); empty!(point_stmts)
            branch_mode = nothing; shape_col_expr = nothing; uses_centre = false

        elseif current_shape !== nothing
            occursin(r"(:[0-9]*c|\bc\b)", line) && (uses_centre = true)

            if head == ">" || startswith(head, ">")
                branch_mode = :gt
                branch_val = head == ">" ? parse(Int, tok(toks, 2)) : parse(Int, head[2:end])
            elseif head == "=" || startswith(head, "=")
                branch_mode = :eq
                branch_val = head == "=" ? parse(Int, tok(toks, 2)) : parse(Int, head[2:end])

            elseif Symbol(head) in known_shapes
                target = Symbol(head)
                vtoks = String[]
                next_col = :col
                next_dir = :dir
                wait_steps = 1
                i = 2
                while i <= length(toks)
                    t = tok(toks, i)
                    if startswith(t, ":") || startswith(t, "p") || startswith(t, "P") || startswith(t, ",")
                        push!(vtoks, t); i += 1
                    elseif t == "flip"
                        next_dir = :(-dir); i += 1
                    elseif t == "wait"
                        if i + 1 <= length(toks) && occursin(r"^\d+$", tok(toks, i + 1))
                            wait_steps = 1 + parse(Int, tok(toks, i + 1)); i += 2
                        else
                            wait_steps = 2; i += 1
                        end
                    elseif t == "!" || t == "not"
                        next_col = :(invert_rgb(col)); i += 1
                    elseif t == "rot"
                        next_col = :(rot_rgb(col)); i += 1
                    elseif t == "rot2"
                        next_col = :(rot2_rgb(col)); i += 1
                    elseif t == "rand"
                        next_col = :(rand_col()); i += 1
                    elseif t == "+" || t == "-"
                        sgn = t == "+" ? 1.0 : -1.0
                        if i + 3 <= length(toks) && all(is_num, toks[(i+1):(i+3)])
                            dr = sgn * parse(Float64, tok(toks, i + 1)) / 10
                            dg = sgn * parse(Float64, tok(toks, i + 2)) / 10
                            db = sgn * parse(Float64, tok(toks, i + 3)) / 10
                            next_col = :(shift_rgb(col, $dr, $dg, $db)); i += 4
                        else
                            d = sgn * parse(Float64, tok(toks, i + 1)) / 10
                            next_col = :(shift_rgb(col, $d, $d, $d)); i += 2
                        end
                    elseif is_num(t) && i + 2 <= length(toks) && all(is_num, toks[i:(i+2)])
                        next_col = :(Col3($(parse(Float64, t)), $(parse(Float64, tok(toks, i + 1))), $(parse(Float64, tok(toks, i + 2)))))
                        i += 3
                    elseif all(x -> occursin(r"^[a-zA-Z]+$", x), toks[i:end])
                        cname = join(toks[i:end], " ")
                        next_col = parse_colour_name(cname)
                        break
                    else
                        i += 1
                    end
                end
                vsyms = expand_verts(vtoks)
                call_ex = :($target(step + $wait_steps, max_level, $next_dir, $next_col, $(vsyms...)))
                push!(branch_mode === nothing ? default_calls : branched_calls, call_ex)

            elseif startswith(head, "L")
                lhs = Symbol(head)
                if tok(toks, 2) == "perp"
                    push!(point_stmts, :($lhs = perp_line($(Symbol(tok(toks, 3))), $(Symbol(tok(toks, 4))))))
                else
                    push!(point_stmts, :($lhs = make_line($(Symbol(tok(toks, 2))), $(Symbol(tok(toks, 3))))))
                end

            elseif occursin(r"^[pP]\d+", head)
                if length(toks) == 3 && startswith(tok(toks, 2), "L") && startswith(tok(toks, 3), "L")
                    push!(point_stmts, :($(Symbol(head)) = intersect_lines($(Symbol(tok(toks, 2))), $(Symbol(tok(toks, 3))))))
                elseif length(toks) == 4 && tok(toks, 2) == "refl"
                    push!(point_stmts, :($(Symbol(head)) = reflect_pt($(Symbol(tok(toks, 3))), $(Symbol(tok(toks, 4))))))
                elseif tok(toks, 2) == "par"
                              elseif tok(toks, 2) == "par"
                    pa = Symbol(tok(toks, 3))
                    pb = Symbol(tok(toks, 4))
                    pc = Symbol(tok(toks, 5))
                    push!(point_stmts, :($(Symbol(head)) = par_pt($pa, $pb, $pc)))
  elseif occursin("..", head)
                    # Ranged point definitions: `p4..7 p0.. .5 p1..0`, `p3..6 p0 1..4/5 p1`, `p3..6 p0 1,3,5,8/9 p1`
                    rng = split(head[2:end], r"\.\.+")
                    p_start, p_end = parse(Int, first(rng)), parse(Int, last(rng))
                    count = p_end - p_start + 1

                    from_tok = tok(toks, 2)
                    from_base = parse_pt_idx(from_tok)
                    from_inc = occursin("..", from_tok) ? 1 : 0

                    t_tok = tok(toks, 3)
                    to_tok = tok(toks, 4)
                    to_inc = occursin("..", to_tok) ? 1 : 0
                    to_base = parse_pt_idx(to_tok)
                    wrap_val = (occursin("..", to_tok) && !endswith(to_tok, "..")) ?
                               parse(Int, last(split(to_tok, r"\.\.+"))) : -1

                    # Build vector of fraction expressions for the range
                    t_exprs = Any[]
                    if occursin("..", t_tok) && occursin("/", t_tok)
                        # e.g. `1..4/5`
                        fparts = split(t_tok, "/")
                        denom = parse(Float64, last(fparts))
                        nparts = split(first(fparts), r"\.\.+")
                        n1, n2 = parse(Int, first(nparts)), parse(Int, last(nparts))
                        for k in n1:n2
                            push!(t_exprs, k / denom)
                        end
                    elseif occursin(",", t_tok) && occursin("/", t_tok)
                        # e.g. `1,3,5,8/9`
                        fparts = split(t_tok, "/")
                        denom = parse(Float64, last(fparts))
                        for nstr in split(first(fparts), ",")
                            push!(t_exprs, parse(Float64, nstr) / denom)
                        end
                    else
                        for _ in 1:count
                            push!(t_exprs, parse_fract_expr(t_tok))
                        end
                    end

                    turn_sgn = 0
                    turn_d = 0.0
                    if length(toks) >= 6
                        turn_sgn = tok(toks, 5) in ("left", "l") ? -1 : 1
                        turn_d = parse(Float64, tok(toks, 6))
                    end

                    for idx in 0:(count - 1)
                        lhs = Symbol("p", p_start + idx)
                        p_a = Symbol("p", from_base + idx * from_inc)
                        b_num = wrap_val >= 0 ? mod(to_base + idx, max(from_base + count - 1, wrap_val) + 1) : (to_base + idx * to_inc)
                        p_b = Symbol("p", b_num)
                        tex = tok(t_exprs, idx + 1)
                        if turn_sgn != 0
                            push!(point_stmts, :($lhs = step_perp($p_a, $tex, $p_b, dir * $turn_sgn, $turn_d)))
                        else
                            push!(point_stmts, :($lhs = lerp_pt($p_a, $tex, $p_b)))
                        end
                    end
                else
                    # Single point definition
                    lhs = Symbol(head)
                    p_a = Symbol(tok(toks, 2))
                    t_tok = tok(toks, 3)
                    p_b = Symbol(tok(toks, 4))
                    t_ex = if t_tok == "\""
                        last_fract_expr
                    elseif t_tok == "rand" && length(toks) >= 6 && is_num(tok(toks, 4))
                        lo, hi = parse(Float64, tok(toks, 4)), parse(Float64, tok(toks, 5))
                        p_b = Symbol(tok(toks, 6))
                        :($lo + rand() * ($hi - $lo))
                    else
                        parse_fract_expr(t_tok)
                    end
                    last_fract_expr = t_ex

                    if length(toks) >= 6 && tok(toks, 5) in ("left", "l", "right", "r")
                        turn_sgn = tok(toks, 5) in ("left", "l") ? -1 : 1
                        turn_d = parse(Float64, tok(toks, 6))
                        push!(point_stmts, :($lhs = step_perp($p_a, $t_ex, $p_b, dir * $turn_sgn, $turn_d)))
                    else
                        push!(point_stmts, :($lhs = lerp_pt($p_a, $t_ex, $p_b)))
                    end
                end
            else
                # Shape-level colour line (`1`, `0.2 0.4 0.8`, `rand`, or `cornflower blue`)
                if length(toks) == 1 && is_num(head)
                    shape_col_expr = Col3(parse(Float64, head))
                elseif length(toks) == 3 && all(is_num, toks)
                    shape_col_expr = Col3(parse(Float64, tok(toks, 1)), parse(Float64, tok(toks, 2)), parse(Float64, tok(toks, 3)))
                elseif head == "rand"
                    shape_col_expr = :(rand_col())
                else
                    shape_col_expr = parse_colour_name(line)
                end
            end
        end
    end
    flush_shape!()

    isempty(init_pts) && append!(init_pts, [HPoint(0, 0), HPoint(100, 0), HPoint(100, 100), HPoint(0, 100)])

    @eval function draw(step::Int, max_level::Int, dir::Int, col::Col3, pts...)
        lpts = [to_luxor(p) for p in pts]
        if !$only_edges
            sethue(col.r, col.g, col.b)
            poly(lpts, :fill)
        end
        if !$no_edges
            sethue(0, 0, 0)
            setline($line_width)
            poly(lpts, :stroke, close = true)
        end
    end

    for ex in shape_exprs
           println(ex)
        @eval $ex
    end

    return (; main_shape, init_pts, bg_col, margins)
end

# ==============================================================================
# 4. RENDERER & CLI RUNNER (`julia ratsub2.jl myprog 1 7`)
# ==============================================================================
function render_level(prog, level::Int, outfile::String; size_px::Int = 1200)
      outfile = abspath(outfile)   # <-- Forces Luxor to use your current folder instead of ~/

    xs = [p.x / p.w for p in prog.init_pts]
    ys = [p.y / p.w for p in prog.init_pts]
    minx = minimum(xs) - first(prog.margins)
    miny = minimum(ys) - tok(prog.margins, 2)
    maxx = maximum(xs) + tok(prog.margins, 3)
    maxy = maximum(ys) + last(prog.margins)

    span = max(maxx - minx, maxy - miny)
    sc = size_px / span
    cx, cy = (minx + maxx) / 2, (miny + maxy) / 2

    @png begin
background(prog.bg_col === nothing ? "white" : RGB(prog.bg_col.r, prog.bg_col.g, prog.bg_col.b))
Luxor.scale(sc, -sc) # Flip Y so positive Y points UP just like PostScript!
Luxor.translate(-cx, -cy)
@eval $(prog.main_shape)(0, $level, 1, Col3(1.0, 1.0, 1.0), $(prog.init_pts)...)
end size_px size_px outfile
println("Saved $outfile")
end
function main(args::Vector{String})
    flags = filter(a -> startswith(a, "-"), args)
    pos_args = filter(a -> !startswith(a, "-"), args)

    size_px = 1000
    ext = "png"

    for f in flags
        if f in ("-hd", "--hd")
            size_px = 2400
        elseif f in ("-4k", "--4k")
            size_px = 3840
        elseif f in ("-svg", "--svg")
            ext = "svg"
        elseif startswith(f, "-size=")
            size_px = parse(Int, last(split(f, "=")))
        end
    end

    if length(pos_args) >= 2
        name = replace(first(pos_args), r"\.sdv$" => "")
        src = read(abspath("$name.sdv"), String)
        prog = compile_sdv(src)
        l1 = parse(Int, tok(pos_args, 2))
        l2 = length(pos_args) >= 3 ? parse(Int, tok(pos_args, 3)) : l1

        for lv in l1:l2
            out_file = abspath("$name-$lv.$ext")
            render_level(prog, lv, out_file; size_px = size_px)
        end
    else
        println("Usage: julia ratsub2.jl <file.sdv> <level> [end_level] [-hd] [-4k] [-svg] [-size=N]")
    end
end

if !isinteractive()
    main(ARGS)
end
