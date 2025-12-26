# Status

## Current Focus
- Sprint 01: self-hosting runway (run compiler_core under vexc).

## Recently Done
- vexc can now parse and run `src/compiler_core.vex` for `lex`/`parse`/`eval`/`bc` (string-escape fixes + added `bc_run`/`bc_save`/`lex_tokenize_native_pos` builtins) with new runner demos under `examples/`.
- Fixed vexc long-run stability by freeing call-frame envs/results and adding host `env_destroy`/`list_destroy` builtins (prevents paging-file/OOM crashes on self-host demos).
- `compiler_core_parse` self-host demo now completes under vexc (slow): `examples/vexc_run_compiler_core_parse_selfhost_demo.vex go` (~5–6 min on this machine).
- Full compiler_core self-host demo now completes under vexc: `examples/vexc_run_compiler_core_selfhost_demo.vex go` (~12 min on this machine).
- vexc can `bcsave` a stage-2 artifact (`compiler_core_selfhost.vbc`), and that bytecode reaches a fixed point (rebuilds identically): `powershell -ExecutionPolicy Bypass -File scripts/selfhost_fixed_point.ps1`.
- Stage-3 bytecode can rebuild the default stage-2 artifact quickly: `zig build run -- runbc compiler_core_selfhost.vbc bcsave src/compiler_core.vex compiler_core.vbc` (~25s on this machine).
- `dump_tokens` now prints `@line:col` when token streams include positions.
- Added a vexc eval profiler (expr/stmt counts + builtin/function tallies) with a budgeted profile runner.
- Added scan-speed builtins (`consume_digits`, `consume_ident`, `skip_line_comment`, `vexc_consume_*`) to accelerate lex/tokenize.
- Added native `vexc_tokenize_native` and wired compiler_core eval to use fast scan helpers.
- Added a parse-only compiler_core slice for smaller self-hosting steps (`src/compiler_core_parse.vex`).
- Added native `str_eq` builtin wiring (bootstrap + vexc eval) to speed up string compares.
- Token stream carries line/col and dump prints positions.
- Parser emits basic location errors for missing delimiters and bad `use` / `@accel`.
- Errors now show caret snippets when source is available (path or in-memory src).
- Threaded `path` + `src` through vexc parse calls for consistent diagnostics.
- Eval errors now include file path when provided (`vexc_eval_program_path`).
- Added a parse error demo (`examples/vexc_input_error.vex` + runner).
- Added simple parser recovery (sync to next stmt/top-level marker after errors).
- Added a validation script for error output (`scripts/validate_vexc_errors.ps1`).
- Added a function-header error demo (`examples/vexc_input_error_func.vex` + runner).
- Added an eval error demo (`examples/vexc_input_eval_error.vex` + runner).
- Expanded top-level recovery for malformed `fn` headers.
- Added `arg_len` / `arg_get` support in vexc eval (program args).
- Added a compiler_core parse demo runner (currently very slow under vexc).

## Next Steps
1) Keep shrinking compiler_core self-host time under vexc (profiler + hot-path builtins).
2) Improve recovery for malformed parameter lists and bodies.
3) Identify the smallest compiler_core subset to self-host first.

## Commands
- `zig build run -- eval examples/vexc_run_file_demo.vex`
- `zig build run -- eval examples/vexc_run_error_demo.vex`
- `zig build run -- eval examples/vexc_run_error_func_demo.vex`
- `zig build run -- eval examples/vexc_run_eval_error_demo.vex`
- `zig build run -- eval examples/vexc_run_compiler_core_parse_demo.vex` (slow)
- `zig build run -- examples/vexc_run_compiler_core_parse_selfhost_demo.vex go` (slow)
- `zig build run -- examples/vexc_run_compiler_core_parse_selfhost_profile.vex` (budgeted)
- `zig build run -- examples/vexc_run_compiler_core_selfhost_demo.vex go` (slow)
- `zig build run -- examples/vexc_run_compiler_core_selfhost_profile.vex` (budgeted)
- `zig build run -- examples/vexc_run_compiler_core_bcsave_selfhost_demo.vex go` (writes `compiler_core_selfhost.vbc`)
- `powershell -ExecutionPolicy Bypass -File scripts/selfhost_fixed_point.ps1` (stage-2 via vexc, then stage-3 via `runbc`, hashes should match)
- `zig build run -- runbc compiler_core_selfhost.vbc bcsave src/compiler_core.vex compiler_core.vbc` (refresh default stage2; should make `[stage2] using compiler_core.vbc` show up with `--verbose`)
- `zig build run -- eval examples/vexc_run_compiler_core_parse_profile.vex` (still slow)
- `zig build run -- eval examples/vexc_run_profile_smoke.vex`
- `zig build run -- examples/vexc_run_compiler_core_parse_profile.vex` (fast under bootstrap)
- `zig build run -- eval examples/vexc_run_compiler_core_parse_probe.vex`
- `zig build run -- eval examples/vexc_run_compiler_core_parse_tokenize_probe.vex`
- `powershell -ExecutionPolicy Bypass -File scripts\validate_vexc_errors.ps1`
