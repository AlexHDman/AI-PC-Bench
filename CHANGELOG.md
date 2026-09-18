# Changelog

## 0.1.2 — 2026-08-05

- Added portable PnP/CIM NPU detection with an honest unavailable status when no validated NPU provider exists.
- Added exact-match local NPU TOPS catalog and clearly labelled NPU Rated Index; real NPU inference remains deferred to v0.2.0.
- Added CPU/RAM/Storage display metrics, compact system ratings, NPU status, and a one-row comparison CSV fallback.
- Added generic system-NVMe normalization for the detailed disk table.

## 0.1.1 — 2026-08-05

- Replaced the CPU benchmark engine with a native C# `System.Threading.Thread` implementation; PowerShell Runspaces are not used.
- Added a synchronized warm-up pass, three measured passes, median scoring, and per-pass CPU metrics.
- Added a fail-fast ready-barrier path and retained all established CPU result fields.
- Localized unknown V2 report values as `Не определено` and recognizes Samsung SSD 9100 PRO as an NVMe SSD on the NVMe bus.
- Validated JSON, CSV V2, autonomous HTML V2, stable fallback reporting, UTF-8 BOM, and three complete local benchmark runs.
