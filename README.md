# Vex - the final systems language

- Rust-level safety (zero-cost, zero-annotation)
- Go-level simplicity
- Zig-level comptime
- Mojo-level AI acceleration
- Compiles 10× faster than anything that has ever existed

We are not building another language.  
We are ending the war.

**Current status**: Day 0 - bootstrap armed on RTX 4060 Ti.

## Try it

Prereq: Zig `0.13.x`

- Build: `zig build`
- Run the demo (`src/vex.vex`): `zig build run`
- Run a Vex file: `zig build run -- examples/hello.vex`
- Run with args: `zig build run -- run examples/args.vex one two`
- Lex a file using Vex code (self-hosting step): `zig build run -- lex examples/hello.vex`
- Parse a file using Vex code (self-hosting step): `zig build run -- parse examples/hello.vex`
- Dump parsed AST tree: `zig build run -- parse examples/hello.vex dump`
- Verbose interpreter logs: `zig build run -- --verbose examples/hello.vex`
- CLI help: `zig build run -- --help`

See `examples/` for small programs you can modify while iterating on the language.

Join or be obsolete.
