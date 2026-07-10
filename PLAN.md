# progrez — Implementation Plan

See `docs/plans/2026-02-27-progrez-implementation.md` for detailed plan.

## Status

## Mechatron Prime reproducibility repair (2026-07-10)

- [x] Add a package-level control that rejects host-native x86 ISA output and randomized build-root leaks. (2026-07-10 13:19 EDT)
  - Curiosity poke: scan complete emitted instruction/path sets so one missing example cannot make the control vacuous.
- [x] Pin package and test code generation to a portable CPU baseline. (2026-07-10 13:19 EDT)
  - Curiosity poke: keep optimization at ReleaseFast; portability must not silently become a Debug or unoptimized build.
- [x] Prove two clean package builds are byte-identical and run the full test/build/flake gates. (2026-07-10 13:19 EDT)
  - Curiosity poke: compare recursive NAR hashes, not only filenames or one executable.
- [x] Sweep every package artifact with deterministic ISA/path mutations and close classifier omissions. (2026-07-10 13:31 EDT)
  - Curiosity poke: require a clean specificity fixture so the gate cannot pass by rejecting every package.

- [x] Task 1: Project Scaffolding (2026-02-27)
- [x] Task 2: Core Data Model (2026-02-27)
- [x] Task 3: Unit Formatting (2026-02-27)
- [x] Task 4: EMA Rate Calculation (2026-02-27)
- [x] Task 5: Terminal Capability Detection (2026-02-27)
- [x] Task 6: Determinate Bar Rendering (2026-02-27)
- [x] Task 7: Indeterminate Spinner Rendering (2026-02-27)
- [x] Task 8: Completion Summary Rendering (2026-02-27)
- [x] Task 9: Non-Interactive Log Mode (2026-02-27)
- [x] Task 10: Render Dispatcher (2026-02-27)
- [x] Task 11: C FFI Layer (2026-02-27)
- [x] Task 12: C Header File (2026-02-27)
- [x] Task 13: Render Thread I/O Integration (2026-02-27)
- [x] Task 14: C Demo + CLI Tests (2026-02-27)
- [x] Task 15: Env Var Configuration (2026-02-27)
- [x] Task 16: Documentation and Final Polish (2026-02-27)

## v2 Features (2026-02-28)

See `docs/plans/2026-02-28-progrez-v2-implementation.md` for detailed plan.

- [x] Task 1: Throughput Formatter (formatThroughput)
- [x] Task 2: Throughput in Determinate Bar
- [x] Task 3: Sparkline Core State (rate history ring buffer)
- [x] Task 4: Sparkline Formatter (formatSparkline)
- [x] Task 5: Sparkline in Render + FFI
- [x] Task 6: Label Update (setLabel + progrez_set_label)
- [x] Task 7: GitHub Actions CI + Badges
- [x] Task 8: Flake Output Verification (header installation)
- [x] Task 9: System Notifications (cross-platform + callback)
- [x] Task 10: Documentation and Demos
