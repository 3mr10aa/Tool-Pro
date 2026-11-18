AMR Windows Utility - V1

CONTENTS
- AMR_Windows_Utility_V1.ps1 : full PowerShell application script
- AMR_WebView2\ : WebView2 SDK assemblies and x86/x64 native loader DLLs
- Run_AMR_V1.bat : launcher

HOW TO RUN
1. Extract the entire ZIP to a normal folder (do not run from inside the ZIP).
2. Keep the AMR_WebView2 folder beside the PS1 file. Do not move it.
3. Double-click Run_AMR_V1.bat.

REQUIREMENTS / NOTES
- Windows PowerShell 5.1 and .NET Framework/WPF support.
- Microsoft Edge WebView2 Runtime must be installed on Windows. The package includes the SDK assemblies and native loader, not the browser runtime itself.
- Internet access is required for Telegram Web content.
- Telegram actions remain user-controlled.


STARTUP MANAGER + NETWORK FALLBACK UPDATE (2026-11-18)
- Added a Startups tab after Performance in System Center.
- Combines Windows Win32_StartupCommand inventory with Run/RunOnce/Run32, policy Run keys, and Startup-folder entries; duplicate commands are filtered.
- Uses the existing universal installed-app inventory to enrich matching display names and resolve cached local icons; extracts executable icons when no cached icon exists.
- Adds animated per-entry ON/OFF switches backed by StartupApproved where Windows exposes a safe control; informational-only entries are visibly non-toggleable.
- Does not create new startup commands for ordinary installed applications.
- Added a Get-NetIPConfiguration / Get-NetAdapterStatistics fallback when the primary .NET network enumeration fails.
- Windows PowerShell 5.1/WPF runtime validation must still be performed on a Windows machine.

CLEANUP CENTER RESTORE
- Restored the original Cleanup Center tab-item sizing/alignment independently of the newer 146px System sub-tab style.
- Cleanup Center XAML content and tab structure remain from the original project layout.

SOFTWARE ICONS SOURCE
- The only remote archive URL is https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main/Icons.zip
- No old repository, API download URL, mirror, or alternate archive URL is used.
- Cache metadata must identify 3mr10aa/Tool-Pro, branch main, file Icons.zip. Old-source cache files are discarded.
- PUBLISH_TO_GITHUB.ps1 preserves the existing root Icons.zip while publishing the release to main.
- At preparation time, Icons.zip was visible on the repository's Master branch; the requested main Raw URL returned 404 until the publish operation carries the file to main.
