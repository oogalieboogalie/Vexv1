# Vex Roadmap (Day 1 Snapshot)

This is where we left off and where to go next.

## Current State

- Zig bootstrap interpreter (`bootstrap/main.zig`):
  - Requires a system Zig `0.13.x` install (not vendored in this repo).
  - Executes Core Vex: `let`, assignment (`=` / `+=`), index assignment (`xs[i] = v` / `xs[i] += v`), `print`, `fn` (any number of parameters), `return`, `if`/`else`, `while`, `for i in a..b { ... }`, `break`/`continue`, `xs[i]`, `true`/`false`/`null`.
  - Supports top-level `use "./file.vex"` includes (multi-file programs; functions are merged).
  - Operators: `+ - * /`, `< <= > >=`, `== !=` (ints + strings), `and` / `or`.
  - Supports `@accel`-tagged functions (registered with a CPU stub today).
  - Supports string interpolation: `{name}`, `{fib(16)}`, and `\n` escapes.
  - Supports dot: `.name` yields `"name"` and `obj.field` lowers to `env_find(obj, "field")`.
  - Has builtins for env, strings, lists, filesystem IO, and argv access.
  - Can run `.vbc` bytecode files via `vex runbc <file.vbc> [args...]`.
  - If `compiler_core.vbc` exists and is fresh (newer than `src/compiler_core.vex` and its `use` deps), `vex lex/parse/eval/bc/...` will run the compiler via stage-2 bytecode automatically.

- Core self-hosting compiler (`src/compiler_core.vex`):
  - Lexer/tokenizer implemented in Vex (`src/core/lex.vex`).
  - Dogfoods `use` internally: `src/compiler_core.vex` is split into small modules under `src/core/`.
  - Recursive-descent parser that builds a list-based AST.
  - Parses dot syntax: `.name` and `obj.field` (lowered to `env_find`).
  - Supports top-level `use "./file.vex"` includes (multi-file programs; functions are merged).
  - Parses/evals assignment (`=` / `+=`), index assignment (`xs[i] = v` / `xs[i] += v`), `for i in a..b { ... }`, `break`/`continue`, `xs[i]`, and `true`/`false`/`null` literals.
  - Bytecode compiler + VM for Core Vex:
    - `vex bc <file.vex> [args...]` compiles to bytecode and runs it.
    - `vex bcvex <file.vex> [args...]` compiles to bytecode and runs it via the Vex VM (debug).
    - `vex bcdump <file.vex>` dumps bytecode (debug).
    - `vex bcsave <file.vex> <out.vbc>` compiles to bytecode and writes a `.vbc` file.
  - Wired into CLI: `vex lex <file.vex>`, `vex parse <file.vex> [dump]`, `vex eval <file.vex> [args...]`, `vex bc <file.vex> [args...]`, `vex bcvex <file.vex> [args...]`, `vex bcdump <file.vex>`, `vex bcsave <file.vex> <out.vbc>`, and `vex runbc <file.vbc> [args...]`.

- Vex-side compiler sketch (`src/compiler.vex`):
  - Defines `TokenKind` / `Token` matching the interpreter's lexer.
  - Implements `vex_tokenize(src)` in Vex.
  - Defines AST types: `Expr`, `Stmt`, `FuncAst`, `ProgramAst`.
  - Implements a Pratt expression parser (`parse_expr`) for `+ - * / < <=`.
  - Implements `vex_parse_body` and `vex_parse` to build a function-level AST (functions + statement lists).
  - Sketches an evaluator: Vex `Env`, `eval_expr`, `eval_stmt`, `eval_block`, and `vex_eval(program)` that conceptually mirrors the Zig interpreter.

## Near-Term Goals

1. Align semantics
   - Make `vex_eval` in `compiler.vex` match the behavior of the Zig interpreter:
     - Same return semantics inside nested `if` / blocks.
     - Same truthiness rules (`0` vs non-zero).
     - Same handling of unknown variables/functions (panic vs default).
     - Same function call behavior (single parameter recursion, `@accel` tags ignored or recorded but not required for correctness).

2. Collapse `compiler.vex` to Core Vex
   - Preferred bootstrap path: keep Core minimal and only add the syntax/runtime features that unblock compiling/running the real compiler.
   - The big missing pieces for `src/compiler.vex` are mostly syntax:
      - `break`/`continue` propagation parity across all code paths
      - A minimal module/import story (or a single-file compiler pass first)
      - More robust strings + byte/slice handling (compiler-heavy workloads)
   - Once those land, focus shifts to pushing more of `src/compiler.vex` through `eval` without "throwaway" ports.

3. Mirror AST in Zig
   - Refactor `bootstrap/main.zig` to:
     - Build a Zig AST that mirrors `Expr` / `Stmt` / `FuncAst` / `ProgramAst`.
     - Evaluate that AST using the same logic as the Vex evaluator (even if still implemented in Zig).
   - This is the bridge: one AST spec, two implementations (Zig + Vex) sharing semantics.

4. Solidify Vex-level Env
   - Finish wiring the `env_*` story end-to-end:
     - Make `env_set` and `env_find` agree on key representation so `env_find(e, "test_key")` reliably returns `123`.
     - Add minimal debug/logging around key bytes if needed.
   - Once stable, port the `KVEnv` concept into `src/env.vex` as the first real runtime module written in Vex.

5. Execute a subset of `compiler.vex` under the interpreter
   - Pick a small, self-contained chunk of `compiler.vex` (e.g., `vex_tokenize` or a tiny `vex_eval` for expressions).
   - Port it fully into Core Vex and run it with the interpreter as a proof of concept.
   - (Started) `src/vexc/tokenize.vex` + `src/vexc/pratt.vex` + `src/vexc/stmt.vex` + `src/vexc/eval.vex` with demos:
     - `examples/vexc_expr_demo.vex`
     - `examples/vexc_stmt_demo.vex`
     - `examples/vexc_run_file_demo.vex` (parses + runs `examples/vexc_input_sum.vex`)
       - Also runs `examples/vexc_input_break_continue.vex`, `examples/vexc_input_builtins.vex`, and `examples/vexc_input_strings.vex`.
     - `examples/vexc_run_for_index_example.vex` (runs `examples/for_index.vex` under vexc; exercises `for`, `xs[i]`, and string interpolation)
     - `examples/vexc_run_index_assign_example.vex` (runs `examples/index_assign.vex` under vexc; exercises `xs[i] = v` / `xs[i] += v`)

## Medium-Term Goals

6. Full Vex-side interpreter
   - Incrementally move interpreter responsibilities from Zig into `compiler.vex`:
     - Expression evaluation.
     - Statement execution (`let`, `return`, `if`, calls).
     - Function/env management.
   - Aim for a mode where the Zig binary "just" loads `compiler.vex`, calls into it, and lets Vex drive evaluation.

7. Code generation path
   - Design an intermediate representation (IR) for Vex:
     - Either a small bytecode for a Vex VM, or a simple SSA-style IR.
   - (Done for Core Vex) `compiler_core.vex` lowers AST -> bytecode.
   - (Done) Zig runtime can execute that bytecode (`bc_run`).
   - (Done) Serialize bytecode to disk (`vex bcsave`) + run it without Vex parsing (`vex runbc`).
   - (Done) Stage-2 loop: `compiler_core.vbc` can rebuild itself.
   - Next: start pushing `src/compiler.vex` (the “real” compiler) through this pipeline.

8. GPU / @accel story
   - Decide on the first real `@accel` target (CUDA via LLVM, or a simpler CPU vector path).
   - Map `@accel` functions from AST -> specialized IR or direct LLVM IR.
   - Keep the CPU stub behavior as a fallback when accelerators aren't available.

## Long-Term Dream

9. Delete most Zig
   - Once the Vex compiler and interpreter are stable in `compiler.vex` and Core Vex is expressive enough, shrink Zig down to:
     - A tiny runtime and host for Vex code.
     - Platform bindings (FS, GPU, system APIs).
   - Everything else lives in Vex.

When you pick this back up, a good starting task is Step 2: simplify one part of `compiler.vex` (for example, the Env/map handling) into Core Vex style that the current interpreter could realistically learn to execute.
