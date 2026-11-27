# AMR Utility Config Center: scripts

Reviewed scripts used by the Config page of AMR Utility. Each action has its own undo script. Status of this folder: **draft 1, reviewed by reading, parse-checked on PowerShell 7 (Linux). Not yet run on Windows.**

## Files
| Action | Run | Undo | Needs internet | What undo cannot do |
|---|---|---|---|---|
| Reset Windows Update | `AMR-Config-WindowsUpdate-Reset.ps1` | `AMR-Config-WindowsUpdate-Undo.ps1` | no | Bring back deleted BITS jobs and the old update download cache (Windows rebuilds it) |
| NFS Client | `AMR-Config-NFS-Enable.ps1` | `AMR-Config-NFS-Disable.ps1` | no | The old nfsadmin file-access text is saved, not re-applied |
| OpenSSH Server | `AMR-Config-OpenSSH-Enable.ps1` | `AMR-Config-OpenSSH-Disable.ps1` | yes (Windows downloads the capability) | Keys inside administrators_authorized_keys are never deleted |
| CTT PowerShell profile | `AMR-Config-CttProfile-Install.ps1` | `AMR-Config-CttProfile-Remove.ps1` | yes | PowerShell 7 and any Nerd Font stay installed |

Other files: `manifest.json` (SHA-256 and details per file), `SHA256SUMS.txt`, `VERSION`, `THIRD-PARTY-NOTICES.md` (MIT notices for the upstream projects).

## Requirements
Windows 10 or 11, Windows PowerShell 5.1, an administrator account (the app asks for UAC), internet for the actions marked above. Nothing here is silent: the app shows a confirmation window before each action.

## What every script does
1. Checks administrator rights.
2. Saves a restore copy of what it is about to change in `C:\ProgramData\AMR-Utility\ConfigCenter\Snapshots\<Action>\<time>\` (Windows Update reset also exports policy keys, Group Policy folders, service start types, network settings and tries a restore point; if this copy fails, nothing is changed).
3. Runs the upstream steps, writing progress (percent, status) to the small JSON file named in `AMR_CONFIG_PROGRESS`, which the app shows as a percentage bar.
4. Writes a log in `C:\ProgramData\AMR-Utility\ConfigCenter\`.

The undo script reads the newest snapshot and restores only what the run changed.

## How the app checks these files
- The app has the commit SHA of this folder in its code (`pinned commit`) and a SHA-256 for every file. Before any script runs, the file is hashed. A mismatch means the script is **not run**.
- The app also keeps an offline copy of the same files inside itself, so it works without internet.
- Updates: the app can look at this repository for a newer `manifest.json`. It only shows an "update available" notice. Nothing is downloaded or run until you confirm. The previous version stays as a fallback.
- The manifest cannot hold its own commit SHA; the commit is pinned in the app.

## Updating a script (for the maintainer)
1. Edit the script, keep the header (license and upstream lines).
2. Recompute SHA-256 of every changed file and update `manifest.json`, `SHA256SUMS.txt` and `VERSION`.
3. Commit, then send the new commit SHA to AMR Utility so it can be pinned.

## Known limits
- Not yet run on Windows. Elevated behavior is untested.
- The OpenSSH script resolves the full capability name (the short name may fail; suspected, untested).
- HKCU keys saved by the Windows Update reset belong to the account that runs the script.
