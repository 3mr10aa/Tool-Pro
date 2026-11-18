/**
 * AMR Tool-Pro diagnostics collector.
 *
 * Required Worker bindings:
 *   DB (Cloudflare D1 database)
 *   GITHUB_TOKEN (secret with Contents: Read and write for the target repo)
 *   GITHUB_OWNER (e.g. 3mr10aa)
 *   GITHUB_REPO (e.g. Tool-Pro)
 *   GITHUB_BRANCH (e.g. main)
 *
 * Public GitHub file contains aggregate statistics only. Private D1 stores a
 * minimized technical profile with no computer name or hardware serial numbers.
 * Deletion is authorized by a random per-installation secret whose SHA-256 hash
 * is stored server-side; the secret itself is never stored in D1 or GitHub.
 */
const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store"
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}

function clean(value, max = 180) {
  if (value === null || value === undefined) return null;
  return String(value).replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, max) || null;
}

function safeNumber(value, min = 0, max = 1000000) {
  // Preserve unavailable values as null; Number(null) and Number("") would
  // otherwise turn missing hardware data into a misleading zero.
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : null;
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

function safeObject(value, fields) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const result = {};
  for (const [key, max] of Object.entries(fields)) {
    const fieldValue = value[key];
    result[key] = typeof fieldValue === "number" && Number.isFinite(fieldValue)
      ? fieldValue
      : clean(fieldValue, max);
  }
  return result;
}

function constantTimeEqual(left, right) {
  const a = String(left || "");
  const b = String(right || "");
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

function safeArray(value, fields, limit) {
  if (!Array.isArray(value)) return [];
  return value.slice(0, limit).map(item => safeObject(item, fields)).filter(Boolean);
}

function utf8Base64(value) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

async function updateGitHubSummary(env, summary) {
  if (!env.GITHUB_TOKEN || !env.GITHUB_OWNER || !env.GITHUB_REPO) {
    throw new Error("GitHub Worker secrets/variables are not configured.");
  }

  const owner = env.GITHUB_OWNER;
  const repo = env.GITHUB_REPO;
  const branch = env.GITHUB_BRANCH || "main";
  const path = "User count.json";
  const api = `https://api.github.com/repos/${owner}/${repo}/contents/${encodeURIComponent(path)}`;
  const headers = {
    "authorization": `Bearer ${env.GITHUB_TOKEN}`,
    "accept": "application/vnd.github+json",
    "content-type": "application/json",
    "user-agent": "AMR-ToolPro-Telemetry-Worker",
    "x-github-api-version": "2022-11-28"
  };

  const content = JSON.stringify(summary, null, 2) + "\n";
  for (let attempt = 0; attempt < 4; attempt++) {
    let sha = null;
    const getResponse = await fetch(`${api}?ref=${encodeURIComponent(branch)}`, { headers });
    if (getResponse.ok) {
      const current = await getResponse.json();
      sha = current.sha || null;
    } else if (getResponse.status !== 404) {
      throw new Error(`GitHub read failed: HTTP ${getResponse.status}`);
    }

    const body = {
      message: "Update AMR Tool-Pro aggregate user statistics",
      content: utf8Base64(content),
      branch
    };
    if (sha) body.sha = sha;

    const putResponse = await fetch(api, {
      method: "PUT",
      headers,
      body: JSON.stringify(body)
    });
    if (putResponse.ok) return;
    if (putResponse.status !== 409 && putResponse.status !== 422) {
      const detail = (await putResponse.text()).slice(0, 300);
      throw new Error(`GitHub write failed: HTTP ${putResponse.status}: ${detail}`);
    }
  }
  throw new Error("GitHub summary update conflicted repeatedly; D1 record is safely stored.");
}

async function buildSummary(db) {
  const totals = await db.prepare(
    "SELECT COUNT(*) AS uniqueUsers, COALESCE(SUM(launch_count), 0) AS totalLaunches FROM devices"
  ).first();

  const manufacturers = await db.prepare(
    "SELECT COALESCE(manufacturer, 'Unknown') AS name, COUNT(*) AS devices FROM devices GROUP BY manufacturer HAVING COUNT(*) >= 5 ORDER BY devices DESC LIMIT 30"
  ).all();

  const models = await db.prepare(
    "SELECT COALESCE(manufacturer, 'Unknown') AS manufacturer, COALESCE(model, 'Unknown') AS model, COUNT(*) AS devices FROM devices GROUP BY manufacturer, model HAVING COUNT(*) >= 5 ORDER BY devices DESC LIMIT 60"
  ).all();

  const operatingSystems = await db.prepare(
    "SELECT COALESCE(os_caption, 'Unknown') AS name, COALESCE(os_build, '') AS build, COUNT(*) AS devices FROM devices GROUP BY os_caption, os_build HAVING COUNT(*) >= 5 ORDER BY devices DESC LIMIT 30"
  ).all();

  const architectures = await db.prepare(
    "SELECT COALESCE(os_architecture, 'Unknown') AS name, COUNT(*) AS devices FROM devices GROUP BY os_architecture HAVING COUNT(*) >= 5 ORDER BY devices DESC"
  ).all();

  return {
    schemaVersion: 1,
    updatedAtUtc: new Date().toISOString(),
    privacy: "Aggregated statistics only. Individual device records are stored in private diagnostics storage.",
    totals: {
      uniqueUsers: Number(totals?.uniqueUsers || 0),
      totalLaunches: Number(totals?.totalLaunches || 0)
    },
    manufacturers: manufacturers.results || [],
    models: models.results || [],
    operatingSystems: operatingSystems.results || [],
    architectures: architectures.results || []
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "AMR Tool-Pro telemetry", version: 1 });
    }
    if (request.method === "POST" && url.pathname === "/forget") {
      let requestBody;
      try {
        requestBody = await request.json();
      } catch {
        return json({ ok: false, error: "Invalid JSON" }, 400);
      }
      const forgetId = clean(requestBody?.installId, 64);
      const installSecret = clean(requestBody?.installSecret, 64);
      if (!forgetId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(forgetId) ||
          !installSecret || !/^[0-9a-f]{64}$/i.test(installSecret)) {
        return json({ ok: false, error: "Invalid deletion credentials" }, 400);
      }
      try {
        const existing = await env.DB.prepare(
          "SELECT install_secret_hash FROM devices WHERE install_id = ?"
        ).bind(forgetId).first();
        if (!existing || !existing.install_secret_hash) {
          return json({ ok: false, error: "Deletion credentials are not registered for this installation" }, 403);
        }
        const suppliedHash = await sha256Hex(installSecret.toLowerCase());
        if (!constantTimeEqual(suppliedHash, String(existing.install_secret_hash).toLowerCase())) {
          return json({ ok: false, error: "Deletion credentials are invalid" }, 403);
        }
        await env.DB.prepare("DELETE FROM devices WHERE install_id = ?").bind(forgetId).run();
        const summary = await buildSummary(env.DB);
        let githubUpdated = false;
        try {
          await updateGitHubSummary(env, summary);
          githubUpdated = true;
        } catch (error) {
          console.error("GitHub summary refresh after deletion failed:", error?.message || error);
        }
        return json({ ok: true, deleted: true, githubUpdated });
      } catch (error) {
        console.error("Telemetry deletion failed:", error?.message || error);
        return json({ ok: false, error: "Record deletion failed" }, 500);
      }
    }

    if (request.method !== "POST" || url.pathname !== "/collect") {
      return json({ ok: false, error: "Not found" }, 404);
    }

    const declaredLength = Number(request.headers.get("content-length") || 0);
    if (declaredLength > 65536) return json({ ok: false, error: "Payload too large" }, 413);

    let payload;
    try {
      const raw = await request.text();
      if (new TextEncoder().encode(raw).length > 65536) {
        return json({ ok: false, error: "Payload too large" }, 413);
      }
      payload = JSON.parse(raw);
    } catch {
      return json({ ok: false, error: "Invalid JSON" }, 400);
    }

    const installId = clean(payload?.installId, 64);
    if (!installId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(installId)) {
      return json({ ok: false, error: "Invalid installation ID" }, 400);
    }
    if (payload?.consent?.deviceDiagnostics !== true || payload?.device?.installId !== installId) {
      return json({ ok: false, error: "Missing device diagnostics consent" }, 400);
    }
    const installSecret = clean(payload?.installSecret, 64);
    if (!installSecret || !/^[0-9a-f]{64}$/i.test(installSecret)) {
      return json({ ok: false, error: "Invalid installation credential" }, 400);
    }
    const installSecretHash = await sha256Hex(installSecret.toLowerCase());

    const device = payload.device || {};
    const os = device.os || {};
    const cpu = Array.isArray(device.cpu) ? device.cpu : [];
    const firstCpu = cpu[0] || {};
    const launchCount = Math.floor(safeNumber(payload.launchCount, 1, 10000000) || 1);
    const firstSeen = clean(payload.firstSeenUtc, 40) || new Date().toISOString();
    const lastSeen = clean(payload.lastSeenUtc, 40) || new Date().toISOString();
    const nowMs = Date.now();

    try {
      const existing = await env.DB.prepare(
        "SELECT last_received_ms, install_secret_hash FROM devices WHERE install_id = ?"
      ).bind(installId).first();

      // Bind an installation ID to its first deletion credential. Without this
      // check, anyone who learned an ID could replace its stored deletion secret.
      if (existing?.install_secret_hash &&
          !constantTimeEqual(installSecretHash, String(existing.install_secret_hash).toLowerCase())) {
        return json({ ok: false, error: "Installation credential does not match this installation" }, 403);
      }

      // Basic per-installation throttling. launchCount is cumulative on the client,
      // so a later successful sync catches up after an offline/throttled attempt.
      if (existing && nowMs - Number(existing.last_received_ms || 0) < 5000) {
        return json({ ok: true, throttled: true, message: "Already received recently" }, 202);
      }

      const deviceJson = JSON.stringify({
        manufacturer: clean(device.manufacturer, 120),
        model: clean(device.model, 180),
        systemType: clean(device.systemType, 80),
        os: {
          caption: clean(os.caption, 120),
          version: clean(os.version, 40),
          build: clean(os.build, 40),
          architecture: clean(os.architecture, 40)
        },
        cpu: safeArray(cpu, { name: 180, manufacturer: 80, cores: 12, logicalProcessors: 12, maxClockMHz: 12 }, 2),
        ramGB: safeNumber(device.ramGB, 0, 4096),
        gpus: safeArray(device.gpus, { name: 180, driverVersion: 80, adapterRamGB: 20, videoProcessor: 120 }, 8),
        storage: safeArray(device.storage, { model: 180, interface: 40, mediaType: 80, sizeGB: 20 }, 16),
        motherboard: safeObject(device.motherboard, { manufacturer: 120, product: 180 }),
        bios: safeObject(device.bios, { manufacturer: 120, version: 120, releaseDate: 20 }),
        drivers: safeArray(device.drivers, { name: 180, class: 40, provider: 120, version: 80, date: 40, inf: 80 }, 100)
      });

      await env.DB.prepare(`
        INSERT INTO devices (
          install_id, install_secret_hash, first_seen, last_seen, launch_count,
          manufacturer, model, system_type,
          os_caption, os_version, os_build, os_architecture,
          cpu_name, cpu_cores, cpu_threads, ram_gb,
          device_json, launcher_version, last_received_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(install_id) DO UPDATE SET
          install_secret_hash = COALESCE(devices.install_secret_hash, excluded.install_secret_hash),
          first_seen = MIN(devices.first_seen, excluded.first_seen),
          last_seen = MAX(devices.last_seen, excluded.last_seen),
          launch_count = MAX(devices.launch_count, excluded.launch_count),
          manufacturer = excluded.manufacturer,
          model = excluded.model,
          system_type = excluded.system_type,
          os_caption = excluded.os_caption,
          os_version = excluded.os_version,
          os_build = excluded.os_build,
          os_architecture = excluded.os_architecture,
          cpu_name = excluded.cpu_name,
          cpu_cores = excluded.cpu_cores,
          cpu_threads = excluded.cpu_threads,
          ram_gb = excluded.ram_gb,
          device_json = excluded.device_json,
          launcher_version = excluded.launcher_version,
          last_received_ms = excluded.last_received_ms
      `).bind(
        installId,
        installSecretHash,
        firstSeen,
        lastSeen,
        launchCount,
        clean(device.manufacturer, 120),
        clean(device.model, 180),
        clean(device.systemType, 80),
        clean(os.caption, 120),
        clean(os.version, 40),
        clean(os.build, 40),
        clean(os.architecture, 40),
        clean(firstCpu.name, 180),
        safeNumber(firstCpu.cores, 0, 256),
        safeNumber(firstCpu.logicalProcessors, 0, 512),
        safeNumber(device.ramGB, 0, 4096),
        deviceJson,
        clean(payload.launcherVersion, 40),
        nowMs
      ).run();

      const summary = await buildSummary(env.DB);
      let githubUpdated = false;
      try {
        await updateGitHubSummary(env, summary);
        githubUpdated = true;
      } catch (error) {
        // The detailed private D1 record remains saved. A later device launch
        // retries the aggregate GitHub publication.
        console.error("GitHub summary update failed:", error?.message || error);
      }

      return json({
        ok: true,
        githubUpdated,
        uniqueUsers: summary.totals.uniqueUsers,
        totalLaunches: summary.totals.totalLaunches
      });
    } catch (error) {
      console.error("Telemetry processing failed:", error?.message || error);
      return json({ ok: false, error: "Telemetry could not be stored" }, 500);
    }
  }
};
