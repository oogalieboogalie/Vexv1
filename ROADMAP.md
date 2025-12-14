# Vex Roadmap (Day 1 Snapshot)

This is where we left off and where to go next.

## Current State

- Zig bootstrap interpreter (`bootstrap/main.zig`):
  - Executes Core Vex: `let`, `print`, `fn`, up to 3 parameters, `return`, `if`/`else`, `while`.
  - Operators: `+ - * /`, `< <= > >=`, `== !=`, `and` / `or`.
  - Supports `@accel`-tagged functions (registered with a CPU stub today).
  - Supports string interpolation: `{name}`, `{fib(16)}`, and `\n` escapes.
  - Has builtins for env, strings, lists, filesystem IO, and argv access.

- Core self-hosting compiler (`src/compiler_core.vex`):
  - `tokenize(src)` implemented in Vex.
  - Recursive-descent parser that builds a list-based AST.
  - Wired into CLI: `vex lex <file.vex>`, `vex parse <file.vex> [dump]`, and `vex eval <file.vex> [args...]`.

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
   - Replace fantasy types like `Map[...]`, `[]T{}`, and `new Env` with Core-Vex-expressible patterns:
     - Represent maps as `[]Pair` plus simple `for`-loops and linear lookup.
     - Avoid generics; use concrete types like `[]u8`, `[]Token`.
     - Replace method-style calls (`tokens.append`) with free functions (`tokens_push(&tokens, value)`).

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
   - Add lowering from `ProgramAst` -> IR in `compiler.vex`.
   - In Zig, write a small VM to execute that IR as a first non-interpreter backend.

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
