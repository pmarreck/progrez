# progrez

Unified progress indication library for CLI/TUI applications.

Provides polished, professional progress bars that take advantage of modern
terminal features (truecolor, Unicode block elements, braille characters).
Decouples data reporting from display rendering: callers provide data points
at arbitrary rates, and the library renders independently on a configurable
timer via a dedicated render thread.

## Key concepts

- **Determinate mode**: Known total — shows a filling bar with %, counts, ETA
- **Indeterminate mode**: Unknown total — shows a braille spinner with counts
- **Completion summary**: On finish, replaces progress bar with a persistent summary line
- **Caller identity**: Optional tool name + context for rich completion messages

## Architecture

Pure Zig core (no I/O) → C FFI boundary (threading, terminal I/O) → Any consumer
