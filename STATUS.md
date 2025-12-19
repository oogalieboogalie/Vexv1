# Status

## Current Focus
- vexc error reporting with file/line/col and caret snippets.

## Recently Done
- Token stream carries line/col and dump prints positions.
- Parser emits basic location errors for missing delimiters and bad `use` / `@accel`.
- Errors now show caret snippets when source is available (path or in-memory src).

## Next Steps
1) Add simple error recovery (skip to next `fn` or `}` after an error).
2) Thread path/src into eval errors (undefined var/function) for consistent reporting.
3) Add a tiny error demo file to exercise parse errors and caret output.

## Commands
- `zig build run -- eval examples/vexc_run_file_demo.vex`
