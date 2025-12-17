# Vex

Vex is an experimental bootstrapping language + runtime.

This repo currently contains:
- a Zig-based bootstrap interpreter (`bootstrap/main.zig`)
- a Vex-written "core compiler" (`src/compiler_core.vex`) that can tokenize/parse/eval Core Vex and compile it to bytecode (`.vbc`)
- small Vex modules under `src/core/` (pulled in via `use`)

**Current status**: early bootstrap (rapidly changing).

## Try it

Prereq: Zig `0.13.x` installed (`zig` on your PATH). This repo does not vendor Zig.

- Build: `zig build`
- Run the demo (`src/vex.vex`): `zig build run`
- Run a Vex file: `zig build run -- examples/hello.vex`
- Run with args: `zig build run -- run examples/args.vex one two`
- Lex a file using Vex code (self-hosting step): `zig build run -- lex examples/hello.vex`
- Parse a file using Vex code (self-hosting step): `zig build run -- parse examples/hello.vex`
- Dump parsed AST tree: `zig build run -- parse examples/hello.vex dump`
- Eval a file using Vex code (self-hosting step): `zig build run -- eval examples/hello.vex`
- Compile to bytecode + run (self-hosting step): `zig build run -- bc examples/hello.vex`
- Compile to bytecode + run using the Vex VM (debug): `zig build run -- bcvex examples/hello.vex`
- Dump bytecode (debug): `zig build run -- bcdump examples/hello.vex`
- Save bytecode to disk: `zig build run -- bcsave examples/hello.vex hello.vbc`
- Run saved bytecode (no Vex parsing): `zig build run -- runbc hello.vbc`
- Optional stage2 (faster compiler commands): `zig build run -- bcsave src/compiler_core.vex compiler_core.vbc` (freshness includes `use` deps)
- Imports (top-level): `use "./file.vex"` (demo: `zig build run -- examples/import_main.vex` or `zig build run -- eval examples/import_main.vex`)
- Self-host proof (compiled compiler runs itself): `zig build run -- bc src/compiler_core.vex eval examples/hello.vex`
- Varargs demo (5-arg function): `zig build run -- examples/varargs.vex` and `zig build run -- eval examples/varargs.vex`
- Dot demo (`obj.field` + `.name`): `zig build run -- examples/dot.vex` and `zig build run -- eval examples/dot.vex`
- Assignment + literals demo (`=`, `+=`, `true/false/null`): `zig build run -- examples/assign.vex` and `zig build run -- eval examples/assign.vex`
- For + indexing demo (`for i in a..b`, `xs[i]`): `zig build run -- examples/for_index.vex` and `zig build run -- eval examples/for_index.vex`
- Index assignment demo (`xs[i] = v`, `xs[i] += v`): `zig build run -- examples/index_assign.vex` and `zig build run -- eval examples/index_assign.vex`
- Break/continue demo: `zig build run -- examples/break_continue.vex` and `zig build run -- eval examples/break_continue.vex`
- Verbose interpreter logs: `zig build run -- --verbose examples/hello.vex`
- CLI help: `zig build run -- --help`

See `examples/` for small programs you can modify while iterating on the language.

## Core Vex (today)

- Statements: `let`, assignment (`=` / `+=`), `print`, `fn`, `return`, `if`/`else`, `while`, `for i in a..b { ... }`, `break`, `continue`
- Top-level: `use "./path.vex"` includes another file (functions are merged)
- Calls: arbitrary arity; builtins for env, strings, lists, filesystem IO, argv
- Indexing: `xs[i]` lowers to `list_get(xs, i)`
- Index assignment: `xs[i] = v` / `xs[i] += v` lowers to `list_set(xs, i, ...)`
- Literals: `true`, `false`, `null`
- Strings: interpolation like `"fib = {fib(16)}\n"` plus `==` / `!=`
- Records: `obj.field` lowers to `env_find(obj, "field")`; `.name` yields `"name"`

See `ROADMAP.md` for what's next.

## License

MIT. See `LICENSE`.
