# ratsub2
vibe-coded julia port of ratsub compiler, very unfinished 

## Usage (Julia REPL)

Running `ratsub2.jl` inside the Julia REPL avoids restarting Julia and reloading `Luxor` between renders, making level sweeps and iterative `.sdv` edits much faster.

### 1. Load the Compiler

Start Julia in the directory containing `ratsub2.jl` and your `.sdv` files, then include the script once per session:

```julia
include("ratsub2.jl")
```

### 2. Function Signature

```julia
ratsub(prog_name,from_level,to_level = nothing; size = 1200,hd = false,format = "png",emit_jl = false,overwrite = false)
```

Arguments before `;` are **positional** (passed in order); arguments after `;` are **keyword** (`name=value`) options.

### 3. Parameters

#### Positional Arguments

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `prog_name` | `AbstractString` | *(required)* | Name of the `.sdv` source file (e.g. `"myprog"` or `"myprog.sdv"`). Trailing `.sdv` is stripped automatically. |
| `from_level` | `Int` | *(required)* | First subdivision level to render. |
| `to_level` | `Union{Int, Nothing}` | `nothing` | Optional ending level. Omit to render only `from_level`, or pass a second integer to render the inclusive range `from_level:to_level`. |

#### Keyword Arguments

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `size` | `Int` | `1200` | Output image width and height in pixels. |
| `hd` | `Bool` | `false` | When `true`, renders at least `2400` px and appends `hd` to the output filename (e.g. `myprog-4hd.png`). |
| `format` | `AbstractString` | `"png"` | Output format/extension passed to Luxor (e.g. `"png"`, `"svg"`). |
| `emit_jl` | `Bool` | `false` | When `true`, writes the generated `draw` and shape functions to `<prog_name>.jl`. |
| `overwrite` | `Bool` | `false` | Controls behavior when `emit_jl=true` and `<prog_name>.jl` already exists (`false` prompts `[y/N]`, `true` overwrites immediately). |

### 4. Examples

```julia
# Render a single level (myprog-5.png at 1200x1200)
ratsub("myprog", 5)

# Render levels 1 through 10 as 2000x2000 SVGs
ratsub("myprog", 1, 10; size=2000, format="svg")

# Render HD output (myprog-4hd.png) and export generated Julia code (myprog.jl)
ratsub("myprog", 4; hd=true, emit_jl=true)

# Export generated Julia code without prompting if myprog.jl already exists
ratsub("myprog", 4; emit_jl=true, overwrite=true)
```

### 5. Return Value & Inspection

`ratsub(...)` returns the compiled program `NamedTuple` (`main_shape`, `init_pts`, `bg_col`, `margins`, `colour_add_used`, `main_shape_col`, `run_mod`, `draw_expr`, `shape_exprs`), allowing you to inspect generated code directly in the REPL:

```julia
compiled = ratsub("myprog", 3)
compiled.shape_exprs
```

### 6. Command-Line Interface (CLI)

When run non-interactively from the shell, `ratsub2.jl` delegates to `main(ARGS)`:

```sh
julia ratsub2.jl <file.sdv> <from_level> [to_level] [-hd] [-4k] [-svg] [-jl] [-y] [-size=N]
```

| Flag | Equivalent in `ratsub(...)` | Behavior |
| :--- | :--- | :--- |
| `-hd`, `--hd` | `hd=true, size=2400` | Sets `hd=true` and `size=2400`. |
| `-4k`, `--4k` | `size=3840` | Sets `size=3840`. |
| `-svg`, `--svg` | `format="svg"` | Exports SVG instead of PNG. |
| `-jl`, `--emit-jl` | `emit_jl=true` | Writes generated Julia code to `<file>.jl`. |
| `-y`, `--overwrite` | `overwrite=true` | Overwrites an existing `<file>.jl` without prompting. |
| `-size=N` | `size=N` | Sets pixel width and height to `N`. |
