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

## Next Steps
1) Add tests or a short script to validate error output format.

## Commands
- `zig build run -- eval examples/vexc_run_file_demo.vex`
- `zig build run -- eval examples/vexc_run_error_demo.vex`
