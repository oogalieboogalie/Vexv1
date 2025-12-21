# Status

## Current Focus
- Error reporting follow-ups: output validation.

## Recently Done
- Token stream carries line/col and dump prints positions.
- Parser emits basic location errors for missing delimiters and bad `use` / `@accel`.
- Errors now show caret snippets when source is available (path or in-memory src).
- Threaded `path` + `src` through vexc parse calls for consistent diagnostics.
- Eval errors now include file path when provided (`vexc_eval_program_path`).
- Added a parse error demo (`examples/vexc_input_error.vex` + runner).
- Added simple parser recovery (sync to next stmt/top-level marker after errors).
- Added a validation script for error output (`scripts/validate_vexc_errors.ps1`).

## Next Steps
1) Expand error recovery around malformed function headers.

## Commands
- `zig build run -- eval examples/vexc_run_file_demo.vex`
- `zig build run -- eval examples/vexc_run_error_demo.vex`
- `powershell -ExecutionPolicy Bypass -File scripts\validate_vexc_errors.ps1`
