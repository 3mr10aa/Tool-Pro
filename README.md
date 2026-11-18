# AMR Tool-Pro — GitHub Release

Latest supplied application build: **Driver Center Intelligence Update**. The PowerShell application is retained in full; this release changes only the software-icons archive source/cache policy and the publishing preservation rule described below.

## Run the application

- Windows 10/11
- Windows PowerShell 5.1 with WPF support
- Microsoft Edge WebView2 Runtime installed
- Keep `AMR_WebView2` beside `AMR_Windows_Utility_V1.ps1`

Double-click `Run_AMR_V1.bat`, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LAUNCHER.ps1
```

## Software icons source

The application has exactly one remote `Icons.zip` download URL:

`https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main/Icons.zip`

No legacy repository, GitHub API download URL, Media mirror, alternate Raw URL, or bundled ZIP is used as a fallback. If the download fails, the icon worker reports `DownloadFailed` and does not reuse a cache unless its `icons.cache.json` identifies `3mr10aa/Tool-Pro` / `main` / `Icons.zip`. A cache from another repository is discarded before icon loading.

**Repository branch note:** At preparation time, the public `Tool-Pro` repository exposed its `Icons.zip` on the `Master` branch, while the requested `main`-branch Raw URL returned 404. The publish script therefore preserves the existing repository-root `Icons.zip` while replacing the rest of the repository content, and pushes the release to `main`. This carries the existing archive into `main`; the Raw URL above becomes usable after that push completes. Do not delete or rename `Icons.zip` in the repository.

## Yarn commands

With Node.js and Yarn installed:

```powershell
yarn start
```

`yarn launch` is an equivalent command. Yarn is only a launcher; the application runs in Windows PowerShell 5.1 and does not require `yarn install`.

## Publish to GitHub

Extract this ZIP, open PowerShell in the extracted folder, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PUBLISH_TO_GITHUB.ps1
```

The script clones `https://github.com/3mr10aa/Tool-Pro`, prepares branch `main`, preserves the existing root `Icons.zip`, replaces the other repository contents with this release, commits, and pushes. Git for Windows and GitHub authentication must be configured. Review the repository before running. The script performs a full replacement except for the preserved `Icons.zip`.

## Validation limits

ZIP integrity and static file checks are performed on the delivered archive. Windows PowerShell 5.1 parsing and WPF runtime execution must still be tested on Windows; they are not claimed as completed here. See `README_DRIVER_CENTER_UPDATE.txt` for the supplied Driver Center update scope and safety notes.
