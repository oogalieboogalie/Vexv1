# Status

## Current Focus
- Sprint 01: diagnostics & recovery hardening.

## Recently Done
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

## Next Steps
1) Improve recovery for malformed parameter lists and bodies.
2) Pick and port the next `compiler.vex` slice into vexc/Core.

## Commands
- `zig build run -- eval examples/vexc_run_file_demo.vex`
- `zig build run -- eval examples/vexc_run_error_demo.vex`
- `zig build run -- eval examples/vexc_run_error_func_demo.vex`
- `zig build run -- eval examples/vexc_run_eval_error_demo.vex`
- `powershell -ExecutionPolicy Bypass -File scripts\validate_vexc_errors.ps1`
