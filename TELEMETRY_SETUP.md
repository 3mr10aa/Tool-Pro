# AMR Tool-Pro telemetry — deployment guide

## Repository files

- `LAUNCHER.ps1` is the current public launcher. Keep the existing file unchanged; do not replace it with `Launcher.ps1` from an older package.
- `AMR-Telemetry-Worker.ps1` is downloaded and started by the launcher in a detached background PowerShell process. The launcher verifies the worker against its pinned SHA-256 hash.
- `telemetry-worker.js` is the Cloudflare Worker source.
- `telemetry-schema.sql` creates the D1 database schema.
- `TELEMETRY_SETUP.md` documents deployment.
- `telemetry-endpoint.txt` is not included in this update. Create it in the repository root only after the Cloudflare Worker has been deployed and its real URL is known. Its only non-comment line must be the HTTPS `/collect` URL.
- `User count.json` is the public aggregate file. The Worker creates or updates this repository-root file through the GitHub Contents API; it is not a device-level export.

Do not upload the older local `Launcher.ps1` file and do not overwrite the repository's `LAUNCHER.ps1`.

## Current launcher and diagnostics behavior

The current `LAUNCHER.ps1` silently writes diagnostics state with `deviceDiagnostics = true` and starts the telemetry worker in the background. There is no consent prompt or telemetry UI in this launcher flow. This guide describes that existing behavior; it does not change it.

The worker runs separately from the launcher UI thread. It reads the endpoint pointer from the repository-root `telemetry-endpoint.txt`, validates that it is an HTTPS URL whose path is `/collect`, and submits the report to the Cloudflare Worker.

## Data flow and privacy boundary

1. The launcher writes the current diagnostics state and schedules the detached worker.
2. The PowerShell worker builds a minimized technical compatibility profile and sends it over HTTPS to `/collect`.
3. The Cloudflare Worker validates the installation ID, diagnostics flag, and installation credential, then stores the device record in the private D1 database.
4. The Worker separately publishes aggregate statistics to the repository-root `User count.json` using the configured GitHub repository token.

The D1 schema stores an installation ID and its deletion-secret hash, first/last-seen timestamps, launch count, launcher version, and technical inventory fields defined in `telemetry-schema.sql`. The collector is designed not to submit computer/account names, BIOS or drive serial numbers, MAC addresses, Windows product keys, personal files, or installed-application lists. The raw installation deletion secret remains local and is sent to the private HTTPS endpoint only when needed for deletion; only its SHA-256 hash is stored in D1.

The public `User count.json` is an aggregate summary, not a per-device export. The Worker suppresses manufacturer, model, Windows/build, and architecture distribution groups when a group has fewer than five installations. Overall aggregate counters may still be shown. A failed GitHub summary update does not undo a report already accepted by D1; a later report can refresh the aggregate.

The hosting provider necessarily handles ordinary network transport metadata. The telemetry JSON payload and D1 schema do not add an IP-address field.

## Deploy the Cloudflare backend

1. Create a Cloudflare Worker, for example `amr-toolpro-telemetry`.
2. Create a Cloudflare D1 database, for example `amr-toolpro-diagnostics`.
3. For a new database, execute the complete `telemetry-schema.sql` file.
4. If upgrading a database from the previous prototype, inspect its schema first. If the `devices` table does not have `install_secret_hash`, add it once:

   ```sql
   ALTER TABLE devices ADD COLUMN install_secret_hash TEXT;
   ```

   The following cleanup statements apply only to the previous prototype schema if those legacy columns/properties exist. Do not run them against a new database created from the current schema:

   ```sql
   UPDATE devices
   SET computer_name = NULL, bios_serial = NULL, serial_consent = 0;

   UPDATE devices
   SET device_json = json_remove(device_json, '$.computerName', '$.biosSerialNumber');
   ```

   If the legacy JSON cleanup function is unavailable, inspect/export the legacy rows and remove those two JSON properties before enabling the new endpoint.
5. Deploy `telemetry-worker.js` to the Cloudflare Worker.
6. Add a D1 binding named `DB` pointing to the database.
7. Configure these Worker variables and secrets:
   - Secret `GITHUB_TOKEN`: a fine-grained token restricted to `3mr10aa/Tool-Pro`, with Contents read/write permission.
   - Variable `GITHUB_OWNER`: `3mr10aa`
   - Variable `GITHUB_REPO`: `Tool-Pro`
   - Variable `GITHUB_BRANCH`: `main`
8. Redeploy the Worker after configuring the binding and variables/secrets.
9. Verify that `https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev/health` returns JSON containing `"ok": true`.
10. Only after the health check succeeds, create or update the repository-root `telemetry-endpoint.txt`. Its only non-comment line must be the exact deployed Worker HTTPS URL ending in `/collect`. Commit and push this endpoint file as a separate change after confirming the real URL.

Never put the GitHub token or Cloudflare secrets in the launcher, public repository files, or end-user PCs.

## GitHub aggregate publication and endpoint protection

The Worker writes aggregate statistics to the repository-root path `User count.json` through the GitHub Contents API. The private device profile is stored in D1 and is not uploaded to GitHub.

The `/collect` endpoint is publicly reachable so desktop clients can submit reports. Configure Cloudflare rate-limiting/WAF protections and monitor usage. The Worker also applies a basic five-second per-installation throttle, but that is not a substitute for edge rate limiting. Do not treat telemetry statistics as tamper-proof licensing data.

## Local data and withdrawal

The local telemetry folder is:

`%LOCALAPPDATA%\AMR-ToolPro\Telemetry`

It can contain the local sanitized profile, queued upload, random installation ID, random deletion secret, consent state, and worker log. The raw installation secret is not written to the public aggregate file or stored in D1.

The PowerShell worker supports `-DisableTelemetry`. It records withdrawal locally and queues a deletion request. When the endpoint is available, it sends the installation ID and deletion secret to `/forget`; the Cloudflare Worker verifies the secret hash before deleting that installation's D1 record and attempting to refresh the public aggregate.

The main application must expose and invoke `-DisableTelemetry` from its privacy/settings UI for users to withdraw through the application. That UI integration is not part of this launcher/backend file publication. The current launcher's silent diagnostics behavior is intentionally unchanged by this guide.

## Publication checklist

Before publishing the telemetry source files, verify that only the intended new files are staged. Do not stage or modify `LAUNCHER.ps1`, `Launcher.ps1`, `telemetry-endpoint.txt`, or unrelated repository files as part of this source-file update. Add the real `telemetry-endpoint.txt` only after the Cloudflare Worker is deployed and its endpoint has been verified.
