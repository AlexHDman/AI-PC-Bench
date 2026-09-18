# EXPC AI Benchmark Portable

Portable local diagnostic package for comparative workstation analysis. Version: **0.1.2**.

v0.1.2 adds PnP/CIM-based NPU detection and an optional catalog-based NPU Rated Index. A rated index is a published TOPS reference, never a measured benchmark; the runtime NPU benchmark is deliberately `not_implemented` until v0.2.0. The portable package does not include an XLSX library, so the comparison-row export is a UTF-8 BOM CSV fallback in `reports`.

## Requirements and launch

- Windows 10 or Windows 11; installation and administrator rights are not required.
- A local folder under the current user profile is recommended. Do not run the Storage benchmark from a network/UNC path.
- Run `START.bat`. It collects system data, runs the safe CPU/RAM/Storage tests, and writes results locally.
- Run `CLEANUP.bat` to remove only the contents of `temp`.

## Output formats

- **JSON**: complete, structured run data for technical processing.
- **CSV**: one Excel-ready row per run, UTF-8 BOM with semicolon delimiters.
- **HTML**: an autonomous visual report that can be copied as a single file.

The CPU engine uses pre-created native .NET threads, a per-thread warm-up, a synchronized Stopwatch start/end interval, and three measured passes. The reported CPU Score is the median of those passes. It is an internal EXPC comparative index: compare results produced with the same EXPC version and similar conditions; temperature, background processes, power mode, and disk state affect results.

## Folder layout

- `scripts` — collector, tests, and report generation.
- `config` — benchmark configuration.
- `results` — JSON and CSV run data.
- `reports` — autonomous HTML reports.
- `logs` — execution logs.
- `temp` — temporary benchmark files, including the in-project CPU compilation workspace.
- `assets` — local CSS source.
- `backups` — pre-change file backups.

## v0.2 direction

Future v0.2 work may add AI workload tests. No AI runtime, model, or external service is included in v0.1.
