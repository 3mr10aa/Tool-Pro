AMR V1 - Overview / Performance update

Changes:
- Corrected Windows family detection so Windows 7/8/8.1 are not mislabeled as Windows 10.
- Improved Device Class detection using Win32_SystemEnclosure chassis codes, with BIOS/model fallback.
- Added the detected manufacturer/model to the Device identity card.
- Rebuilt the Overview performance strip to include CPU, Memory, GPU Load and Network, plus system-drive usage.
- Added live GPU load to the Overview card, sourced from the isolated GPU telemetry worker.
- Added network download/upload throughput to the Overview network detail when two valid byte-counter samples are available.
- Renamed Live Performance to Performance.
- Removed the separate Security & Protection and Network & Windows cards from Overview.
- Manual Overview Refresh now requests a fresh inventory snapshot as well as live telemetry.
- Tuned independent Network and GPU polling intervals while retaining separate workers and timeouts.

Validation performed in this environment:
- Primary WPF XAML extracted and parsed as valid XML.
- Required Overview controls and renamed tab verified.
- Removed Overview cards verified absent from XAML.
- Static source checks verified the Windows version mappings and telemetry intervals.

Not performed:
- The WPF application was not executed on Windows in this environment. Runtime sensor availability depends on the Windows build, GPU driver, and hardware providers. Unsupported sensors should report N/A with a reason rather than fabricated values.

OVERVIEW TELEMETRY HOTFIX (2026-11-17)
- Fixed the DispatcherTimer closure to capture the telemetry state object explicitly. The prior callback looked up a script-scoped state variable from inside GetNewClosure(), which could resolve to the closure module's empty script scope and silently return on every timer tick. This prevented completed CPU/RAM and independent sensor jobs from being applied to the Overview UI.
- Completed the initial fast snapshot schema with optional sensor fields (including CPURaw, InventoryUpdated, network counters/status and sensor error fields) so StrictMode cannot abort the first UI update when the initial snapshot is applied.
- Applied the same Windows build-family mapping to the immediate snapshot as to the slower inventory worker.

Validation: static source checks and archive integrity only. This environment does not provide Windows PowerShell/WPF, so the application has not been executed on Windows here. Please verify live values on the target PC; unavailable GPU/network providers should report N/A with a reason rather than remain in a perpetual loading state.


PARSER-STARTUP CORRECTION (2026-11-17)
- Removed duplicate DiskSensorError and NetworkSensorError entries from the initial Overview snapshot hashtable. The duplicate keys caused a PowerShell ParserError before the application could start, so no telemetry worker or Refresh action could run.
- Ran a static scan across PowerShell hashtable literals for duplicate top-level keys; no duplicates were reported after this correction. This is not a substitute for executing the script with the Windows PowerShell 5.1 parser/runtime.

REQUESTED OVERVIEW / PERFORMANCE / SYSTEM CENTER UPDATE (2026-11-17)

Scope: only the requested Overview telemetry, Overview Storage list, Performance status/polling presentation, and System Center sizing were changed. Driver Center, Backup Safe, and unrelated application features were not intentionally modified.

1) NETWORK TELEMETRY
- Fixed the pending/connected flicker caused by clearing the internet probe result on every fast interface sample.
- The network worker now receives and retains the previous internet probe result between samples.
- Internet connectivity is re-probed every 5 seconds (previously 10 seconds).
- Adapter discovery, IP/gateway/DNS, and byte counters remain independently sampled.

2) GPU TELEMETRY
- GPU Engine PDH counters are now sampled over a one-second window and the newest sample is used to reduce stale/single-read spikes.
- WMI GPU Engine counters remain as a fallback if PDH sampling is unavailable.
- GPU worker polling interval changed from 1.5 to 2.5 seconds; timeout changed from 10 to 12 seconds to accommodate the sample window.

3) OVERVIEW STORAGE
- The Storage card now lists all detected fixed partitions, including C: and D:, using the existing partition row design.
- The separate C: capacity display in the Overview Performance strip is retained.

4) PERFORMANCE PRESENTATION
- Removed the AUTO UPDATE label and hid the recurring refresh/update and UI pulse status text.
- Refresh buttons and their click handlers remain in place.
- Overview telemetry DispatcherTimer and main refresh interval changed from 500 ms to 750 ms to reduce UI pulse frequency.

5) SYSTEM CENTER SIZING
- System Center right-side panel width changed from 165 to 190 pixels to match Toolkit.
- System Center subtab tiles now use the Toolkit dimensions (146 x 38) and matching panel padding.

STATIC VALIDATION PERFORMED
- Primary WPF Window XAML parsed successfully with Python XML parser.
- Static scan checked 1,971 PowerShell hashtable literals and found no duplicate top-level keys.
- Static delimiter scan found no unmatched (), [] or {} delimiters.
- Targeted source assertions passed for Network result retention, GPU sampling/fallback, C:/D: partition inclusion, System Center dimensions, hidden update/pulse labels, and preserved Refresh handlers.
- ZIP integrity checked after packaging.

LIMITATION
- Windows PowerShell 5.1 / WPF runtime testing was not possible in the build environment. This package has not been represented as runtime-tested on Windows. Please launch it on the target PC and compare GPU readings against Task Manager under the same workload.
