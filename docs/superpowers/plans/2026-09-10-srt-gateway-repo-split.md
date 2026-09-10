# SRT Gateway Repo Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the SRT Gateway into a standalone GitHub repo (container + control API + its own web UI), leaving the workspace dashboard with only start/stop and a link.

**Architecture:** The new repo's `control/` Node service owns config normalization, the Strom flow builder, apply/status, and a web UI (port 8090). It talks to a Strom capture container (`srt-gateway`, port 8081) on the compose network. The workspace dashboard drops all SRT logic and gains an SRT status card wired to `docker compose` in the sibling clone.

**Tech Stack:** Node.js 23 (ESM, built-in `node --test`), Docker Compose, GStreamer/Strom custom image. No runtime npm dependencies.

## Global Constraints

- New repo path: `/home/nygard/open-live-srt-gateway` (sibling of `/home/nygard/open-live`).
- New repo name: `markusnygard/open-live-srt-gateway` (public GitHub).
- Control service host port **8090** (container `3000`); Strom host port **8081** (container `8080`).
- Strom image is pinned: `STROM_IMAGE=open-live-strom-ndi:0.6.12` (custom fork). Never use upstream `strom:latest`.
- SRT addresses must never be committed. New repo `.gitignore` must contain `.env` and `data/`.
- Node ESM (`.mjs`), zero runtime dependencies. Tests use `node:test` + `node:assert/strict`.
- Preserve exact flow semantics: sender `decklink_input → videoenc → mpegtssrt_output|efpsrt_output`; receiver `mpegtssrt_input|efpsrt_input → decklink_output`; flow names prefixed `srt-gw-`; device number = SDI index.
- Workspace SRT paths being removed: `dashboard/server.mjs` lines 81-259, routes 466-492, JS 750-864, CSS 569-577; plus `open_live_srt/`.

## File Structure

**New repo `/home/nygard/open-live-srt-gateway/`:**

| File | Responsibility |
|------|----------------|
| `control/lib/config.mjs` | `defaultConfig()`, `normalizeConfig()` — pure config validation |
| `control/lib/flows.mjs` | `SRT_FLOW_PREFIX`, `ensureCaller()`, `buildSrtFlow()` — pure Strom flow construction |
| `control/lib/srtops.mjs` | `makeStromClient()`, `applyConfig()`, `getStatus()` — Strom API orchestration |
| `control/server.mjs` | HTTP server, config file IO, routes, static UI, `createControlServer()` |
| `control/public/index.html` | Standalone traffic-light UI + settings modal |
| `control/package.json` | ESM manifest, `test`/`start` scripts |
| `control/Dockerfile` | `node:23-slim` image |
| `control/test/config.test.mjs` | config normalization tests |
| `control/test/flows.test.mjs` | flow builder tests |
| `control/test/srtops.test.mjs` | Strom ops tests with fake client |
| `control/test/server.test.mjs` | HTTP route tests |
| `docker-compose.yml` | `srt-gateway` + `srt-control` |
| `.env.example` | Strom image + keys template |
| `config/srt-config.default.json` | Shipped default (all ports off) |
| `README.md`, `LICENSE`, `.gitignore` | Docs/license/hygiene |

**Workspace `/home/nygard/open-live/`:**

| File | Change |
|------|--------|
| `dashboard/server.mjs` | Remove SRT control logic; add `CONTAINERS.srt`, `SRT_GATEWAY_DIR`, `runSrtCompose`, `/api/srt/up|down`, new `renderSrt` |
| `.gitignore` | Remove `open_live_srt/*` entries |
| `README.md` | Option C points at the new repo |
| `open_live_srt/` | Deleted (migrated) |

---

### Task 1: Scaffold new repo + config module

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/lib/config.mjs`
- Create: `/home/nygard/open-live-srt-gateway/control/test/config.test.mjs`
- Create: `/home/nygard/open-live-srt-gateway/control/package.json`
- Create: `/home/nygard/open-live-srt-gateway/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `defaultConfig(): {stream, ports}`, `normalizeConfig(raw): {stream, ports}`, and exported constants `SRT_CODECS`, `SRT_BITRATES`, `SRT_CONTAINERS`, `SRT_ROLES`.

- [ ] **Step 1: Create the repo folder and package manifest**

Create `/home/nygard/open-live-srt-gateway/control/package.json`:

```json
{
  "name": "open-live-srt-gateway-control",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "Control API and web UI for the Open Live SRT Gateway",
  "scripts": {
    "start": "node server.mjs",
    "test": "node --test"
  },
  "engines": { "node": ">=23" },
  "license": "MIT"
}
```

Create `/home/nygard/open-live-srt-gateway/.gitignore`:

```
node_modules/
.env
data/
```

- [ ] **Step 2: Write the failing test**

Create `/home/nygard/open-live-srt-gateway/control/test/config.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { defaultConfig, normalizeConfig } from "../lib/config.mjs";

test("defaultConfig has 12 SDI ports, all off", () => {
  const cfg = defaultConfig();
  assert.equal(cfg.ports.length, 12);
  assert.equal(cfg.ports[0].id, "SDI1");
  assert.equal(cfg.ports[11].id, "SDI12");
  assert.ok(cfg.ports.every((p) => p.role === "off" && p.address === ""));
  assert.deepEqual(cfg.stream, { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" });
});

test("normalizeConfig returns defaults for invalid input", () => {
  assert.deepEqual(normalizeConfig(null), defaultConfig());
  assert.deepEqual(normalizeConfig({}), defaultConfig());
  assert.deepEqual(normalizeConfig({ ports: "nope" }), defaultConfig());
});

test("normalizeConfig clamps invalid stream values", () => {
  const cfg = normalizeConfig({ stream: { codec: "vp9", bitrate: 99, container: "rtmp" }, ports: [] });
  assert.equal(cfg.stream.codec, "h264");
  assert.equal(cfg.stream.bitrate, 6);
  assert.equal(cfg.stream.video_mode, "auto");
  assert.equal(cfg.stream.container, "mpegts");
});

test("normalizeConfig keeps valid stream values and fixes SDI ids", () => {
  const cfg = normalizeConfig({
    stream: { codec: "h265", bitrate: 12, video_mode: "1080p50", container: "efp" },
    ports: [{ id: "SDI 1", role: "sender", address: "srt://h:1" }],
  });
  assert.deepEqual(cfg.stream, { codec: "h265", bitrate: 12, video_mode: "1080p50", container: "efp" });
  assert.equal(cfg.ports[0].id, "SDI1");
});

test("normalizeConfig infers legacy container from port majority", () => {
  const cfg = normalizeConfig({
    ports: [
      { id: "SDI1", role: "sender", address: "srt://a", container: "efp" },
      { id: "SDI2", role: "sender", address: "srt://b", container: "efp" },
      { id: "SDI3", role: "sender", address: "srt://c", container: "mpegts" },
    ],
  });
  assert.equal(cfg.stream.container, "efp");
});

test("normalizeConfig resets unknown roles to off", () => {
  const cfg = normalizeConfig({ ports: [{ id: "SDI1", role: "banana", address: "x" }] });
  assert.equal(cfg.ports[0].role, "off");
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `node --test control/test/config.test.mjs` (from `/home/nygard/open-live-srt-gateway`)
Expected: FAIL — `Cannot find module '../lib/config.mjs'`.

- [ ] **Step 4: Write minimal implementation**

Create `/home/nygard/open-live-srt-gateway/control/lib/config.mjs`:

```js
export const SRT_CODECS = ["h264", "h265"];
export const SRT_BITRATES = [4, 6, 12, 24];
export const SRT_CONTAINERS = ["mpegts", "efp"];
export const SRT_ROLES = ["off", "sender", "receiver"];

export function defaultConfig() {
  return {
    stream: { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" },
    ports: Array.from({ length: 12 }, (_, i) => ({ id: "SDI" + (i + 1), role: "off", address: "" })),
  };
}

export function normalizeConfig(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.ports)) return defaultConfig();

  let container = raw.stream && raw.stream.container;
  if (!SRT_CONTAINERS.includes(container)) {
    const counts = {};
    for (const p of raw.ports) {
      if (p.role === "off") continue;
      const c = p.container;
      if (SRT_CONTAINERS.includes(c)) counts[c] = (counts[c] || 0) + 1;
    }
    container = counts.efp > counts.mpegts ? "efp" : "mpegts";
  }

  const stream = {
    codec: SRT_CODECS.includes(raw.stream && raw.stream.codec) ? raw.stream.codec : "h264",
    bitrate: SRT_BITRATES.includes(Number(raw.stream && raw.stream.bitrate)) ? Number(raw.stream.bitrate) : 6,
    video_mode: (raw.stream && raw.stream.video_mode) || "auto",
    container,
  };

  const ports = raw.ports.map((p, i) => ({
    id: (p.id || "SDI" + (i + 1)).replace(/^SDI (\d+)$/, "SDI$1"),
    role: SRT_ROLES.includes(p.role) ? p.role : "off",
    address: p.address || "",
  }));

  return { stream, ports };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node --test control/test/config.test.mjs`
Expected: PASS — 6 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git init
git add control/package.json control/lib/config.mjs control/test/config.test.mjs .gitignore
git commit -m "feat: SRT gateway config normalization"
```

---

### Task 2: Flow builder

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/lib/flows.mjs`
- Create: `/home/nygard/open-live-srt-gateway/control/test/flows.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces: `SRT_FLOW_PREFIX = "srt-gw-"`, `ensureCaller(url): string`, `buildSrtFlow(port, index, stream): object | null`.

- [ ] **Step 1: Write the failing test**

Create `/home/nygard/open-live-srt-gateway/control/test/flows.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { ensureCaller, buildSrtFlow, SRT_FLOW_PREFIX } from "../lib/flows.mjs";

const stream = { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" };

test("ensureCaller forces mode=caller", () => {
  assert.equal(ensureCaller("srt://h:1?mode=listener"), "srt://h:1?mode=caller");
  assert.equal(ensureCaller("srt://h:1"), "srt://h:1?mode=caller");
  assert.equal(ensureCaller("srt://h:1?x=1"), "srt://h:1?x=1&mode=caller");
  assert.equal(ensureCaller(""), "");
});

test("buildSrtFlow sender mpegts", () => {
  const port = { id: "SDI2", role: "sender", address: "srt://h:23001" };
  const flow = buildSrtFlow(port, 1, stream);
  assert.equal(flow.name, SRT_FLOW_PREFIX + "SDI2");
  assert.deepEqual(flow.blocks.map((b) => b.block_definition_id), [
    "builtin.decklink_input", "builtin.videoenc", "builtin.mpegtssrt_output",
  ]);
  assert.equal(flow.blocks[0].properties.device_number, 1);
  assert.equal(flow.blocks[1].properties.bitrate, 6000);
  assert.equal(flow.blocks[2].properties.srt_uri, "srt://h:23001?mode=caller");
  assert.deepEqual(flow.links, [
    { from: "dl:video_out", to: "enc:video_in" },
    { from: "enc:encoded_out", to: "srt:video_in" },
    { from: "dl:audio_out", to: "srt:audio_in_0" },
  ]);
});

test("buildSrtFlow sender efp", () => {
  const flow = buildSrtFlow({ id: "SDI1", role: "sender", address: "srt://h:1" }, 0,
    { ...stream, container: "efp", codec: "h265", bitrate: 12 });
  assert.equal(flow.blocks[2].block_definition_id, "builtin.efpsrt_output");
  assert.equal(flow.blocks[1].properties.codec, "h265");
  assert.equal(flow.blocks[1].properties.bitrate, 12000);
});

test("buildSrtFlow receiver", () => {
  const flow = buildSrtFlow({ id: "SDI3", role: "receiver", address: "srt://h:2" }, 2, stream);
  assert.deepEqual(flow.blocks.map((b) => b.block_definition_id), [
    "builtin.mpegtssrt_input", "builtin.decklink_output",
  ]);
  assert.equal(flow.blocks[0].properties.decode, true);
  assert.equal(flow.blocks[1].properties.device_number, 2);
});

test("buildSrtFlow off returns null", () => {
  assert.equal(buildSrtFlow({ id: "SDI1", role: "off", address: "" }, 0, stream), null);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test control/test/flows.test.mjs`
Expected: FAIL — `Cannot find module '../lib/flows.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `/home/nygard/open-live-srt-gateway/control/lib/flows.mjs`:

```js
export const SRT_FLOW_PREFIX = "srt-gw-";

export function ensureCaller(url) {
  if (!url) return url;
  if (/mode=[a-z]+/.test(url)) return url.replace(/mode=[a-z]+/, "mode=caller");
  return url + (url.includes("?") ? "&" : "?") + "mode=caller";
}

export function buildSrtFlow(port, index, stream) {
  const addr = ensureCaller(port.address);
  const blocks = [];
  const links = [];

  if (port.role === "sender") {
    const outBlock = stream.container === "efp" ? "builtin.efpsrt_output" : "builtin.mpegtssrt_output";
    blocks.push(
      { id: "dl", block_definition_id: "builtin.decklink_input", name: port.id + " In",
        properties: { device_number: index, stream_mode: "audio_video", mode: stream.video_mode || "auto" },
        position: { x: 0, y: 0 } },
      { id: "enc", block_definition_id: "builtin.videoenc", name: port.id + " Enc",
        properties: { codec: stream.codec, bitrate: stream.bitrate * 1000, tune: "zerolatency", keyframe_interval: 50 },
        position: { x: 160, y: 0 } },
      { id: "srt", block_definition_id: outBlock, name: port.id + " SRT",
        properties: { srt_uri: addr, num_video_tracks: 1, num_audio_tracks: 1, latency: 120, wait_for_connection: false },
        position: { x: 320, y: 0 } },
    );
    links.push(
      { from: "dl:video_out", to: "enc:video_in" },
      { from: "enc:encoded_out", to: "srt:video_in" },
      { from: "dl:audio_out", to: "srt:audio_in_0" },
    );
  } else if (port.role === "receiver") {
    const inBlock = stream.container === "efp" ? "builtin.efpsrt_input" : "builtin.mpegtssrt_input";
    blocks.push(
      { id: "inp", block_definition_id: inBlock, name: port.id + " In",
        properties: { srt_uri: addr, decode: true, num_video_tracks: 1, latency: 120 }, position: { x: 0, y: 0 } },
      { id: "dlo", block_definition_id: "builtin.decklink_output", name: port.id + " Out",
        properties: { device_number: index, stream_mode: "audio_video" }, position: { x: 200, y: 0 } },
    );
    links.push(
      { from: "inp:video_out", to: "dlo:video_in" },
      { from: "inp:audio_out_0", to: "dlo:audio_in" },
    );
  } else {
    return null;
  }

  return { id: "00000000-0000-0000-0000-000000000000", name: SRT_FLOW_PREFIX + port.id, blocks, links, properties: {} };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test control/test/flows.test.mjs`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git add control/lib/flows.mjs control/test/flows.test.mjs
git commit -m "feat: SRT Strom flow builder"
```

---

### Task 3: Strom client + apply/status operations

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/lib/srtops.mjs`
- Create: `/home/nygard/open-live-srt-gateway/control/test/srtops.test.mjs`

**Interfaces:**
- Consumes: `SRT_FLOW_PREFIX`, `buildSrtFlow` from `flows.mjs`.
- Produces: `makeStromClient(baseUrl, apiKey, fetchImpl?)` returning `{ req, listFlows, deleteFlows }`; `applyConfig(strom, cfg): Promise<{removed, created, failed}>`; `getStatus(strom, cfg): Promise<{flows, stream, channels}>`.

- [ ] **Step 1: Write the failing test**

Create `/home/nygard/open-live-srt-gateway/control/test/srtops.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { makeStromClient, applyConfig, getStatus } from "../lib/srtops.mjs";
import { SRT_FLOW_PREFIX } from "../lib/flows.mjs";

function fakeFetch(handler) {
  return async (url, opts = {}) => {
    const body = opts.body ? JSON.parse(opts.body) : undefined;
    const result = handler(opts.method || "GET", new URL(url).pathname, body) || { status: 200, json: {} };
    return {
      ok: result.status >= 200 && result.status < 300,
      status: result.status,
      async text() { return JSON.stringify(result.json); },
    };
  };
}

test("makeStromClient sends bearer auth and parses json", async () => {
  const seen = [];
  const client = makeStromClient("http://strom:8080", "k", fakeFetch((m, p) => {
    seen.push({ m, p });
    return { status: 200, json: { flows: [] } };
  }));
  const r = await client.req("GET", "/api/flows");
  assert.equal(r.ok, true);
  assert.deepEqual(r.data, { flows: [] });
  assert.deepEqual(seen, [{ m: "GET", p: "/api/flows" }]);
});

test("listFlows filters srt-gw- prefix", async () => {
  const client = makeStromClient("http://s:8080", "k", fakeFetch(() => ({
    status: 200, json: { flows: [{ id: "a", name: SRT_FLOW_PREFIX + "SDI1" }, { id: "b", name: "other" }] },
  })));
  const flows = await client.listFlows();
  assert.equal(flows.length, 1);
  assert.equal(flows[0].name, "srt-gw-SDI1");
});

test("deleteFlows stops and deletes each flow", async () => {
  const calls = [];
  let flows = [{ id: "a", name: "srt-gw-SDI1" }];
  const client = makeStromClient("http://s:8080", "k", fakeFetch((m, p) => {
    calls.push(m + " " + p);
    if (p === "/api/flows") return { status: 200, json: { flows } };
    return { status: 200, json: {} };
  }));
  const removed = await client.deleteFlows();
  assert.equal(removed, 1);
  assert.deepEqual(calls, ["GET /api/flows", "POST /api/flows/a/stop", "DELETE /api/flows/a"]);
});

test("applyConfig creates and starts active ports only", async () => {
  const calls = [];
  const client = makeStromClient("http://s:8080", "k", fakeFetch((m, p, body) => {
    calls.push({ m, p });
    if (p === "/api/flows" && m === "GET") return { status: 200, json: { flows: [] } };
    if (p === "/api/flows" && m === "POST") return { status: 200, json: { flow: { id: "new" } } };
    return { status: 200, json: {} };
  }));
  const cfg = {
    stream: { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" },
    ports: [
      { id: "SDI1", role: "sender", address: "srt://a" },
      { id: "SDI2", role: "off", address: "" },
    ],
  };
  const r = await applyConfig(client, cfg);
  assert.deepEqual(r, { removed: 0, created: 1, failed: 0 });
  assert.ok(calls.some((c) => c.m === "POST" && c.p === "/api/flows/new/start"));
});

test("applyConfig counts failures", async () => {
  const client = makeStromClient("http://s:8080", "k", fakeFetch((m, p) => {
    if (p === "/api/flows" && m === "GET") return { status: 200, json: { flows: [] } };
    if (p === "/api/flows" && m === "POST") return { status: 500, json: {} };
    return { status: 200, json: {} };
  }));
  const cfg = {
    stream: { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" },
    ports: [{ id: "SDI1", role: "sender", address: "srt://a" }],
  };
  const r = await applyConfig(client, cfg);
  assert.deepEqual(r, { removed: 0, created: 0, failed: 1 });
});

test("getStatus maps channels to colors", async () => {
  const client = makeStromClient("http://s:8080", "k", fakeFetch(() => ({
    status: 200, json: { flows: [{ id: "a", name: "srt-gw-SDI1", running: true }] },
  })));
  const cfg = {
    stream: { codec: "h264", bitrate: 6, video_mode: "auto", container: "mpegts" },
    ports: [
      { id: "SDI1", role: "sender", address: "srt://a" },
      { id: "SDI2", role: "sender", address: "srt://b" },
      { id: "SDI3", role: "off", address: "" },
    ],
  };
  const status = await getStatus(client, cfg);
  assert.equal(status.flows, 1);
  assert.equal(status.channels[0].color, "green");
  assert.equal(status.channels[1].color, "red");
  assert.equal(status.channels[2].color, "off");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test control/test/srtops.test.mjs`
Expected: FAIL — `Cannot find module '../lib/srtops.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `/home/nygard/open-live-srt-gateway/control/lib/srtops.mjs`:

```js
import { buildSrtFlow, SRT_FLOW_PREFIX } from "./flows.mjs";

export function makeStromClient(baseUrl, apiKey, fetchImpl = globalThis.fetch) {
  async function req(method, path, body) {
    try {
      const opts = { method, headers: { Authorization: "Bearer " + apiKey } };
      if (body !== undefined) {
        opts.headers["Content-Type"] = "application/json";
        opts.body = JSON.stringify(body);
      }
      const res = await fetchImpl(baseUrl + path, opts);
      const text = await res.text();
      let data = null;
      try { data = JSON.parse(text); } catch {}
      return { ok: res.ok, status: res.status, data };
    } catch (e) {
      return { ok: false, status: 0, data: null, error: e.message };
    }
  }

  async function listFlows() {
    const r = await req("GET", "/api/flows");
    if (!r.ok) return [];
    return ((r.data && r.data.flows) || []).filter((f) => (f.name || "").startsWith(SRT_FLOW_PREFIX));
  }

  async function deleteFlows() {
    const flows = await listFlows();
    for (const f of flows) {
      await req("POST", "/api/flows/" + f.id + "/stop");
      await req("DELETE", "/api/flows/" + f.id);
    }
    return flows.length;
  }

  return { req, listFlows, deleteFlows };
}

export async function applyConfig(strom, cfg) {
  const removed = await strom.deleteFlows();
  let created = 0, failed = 0;
  for (let i = 0; i < cfg.ports.length; i++) {
    const p = cfg.ports[i];
    if (p.role === "off" || !p.address) continue;
    const flow = buildSrtFlow(p, i, cfg.stream);
    if (!flow) continue;
    const r = await strom.req("POST", "/api/flows", flow);
    if (r.ok && r.data && r.data.flow && r.data.flow.id) {
      await strom.req("POST", "/api/flows/" + r.data.flow.id + "/start");
      created++;
    } else {
      failed++;
    }
  }
  return { removed, created, failed };
}

export async function getStatus(strom, cfg) {
  const flows = await strom.listFlows();
  const map = {};
  for (const f of flows) map[f.name.replace(SRT_FLOW_PREFIX, "")] = f;
  const channels = cfg.ports.map((p) => {
    const f = map[p.id];
    return {
      sdi: p.id,
      role: p.role,
      address: p.address || "",
      container: cfg.stream.container,
      running: !!(f && f.running),
      color: p.role === "off" ? "off" : (f && f.running) ? "green" : "red",
    };
  });
  return { flows: flows.length, stream: cfg.stream, channels };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test control/test/srtops.test.mjs`
Expected: PASS — 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git add control/lib/srtops.mjs control/test/srtops.test.mjs
git commit -m "feat: Strom client and apply/status operations"
```

---

### Task 4: HTTP control server

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/server.mjs`
- Create: `/home/nygard/open-live-srt-gateway/control/test/server.test.mjs`

**Interfaces:**
- Consumes: `defaultConfig`, `normalizeConfig` (config.mjs); `makeStromClient`, `applyConfig`, `getStatus` (srtops.mjs).
- Produces: `createControlServer({ configFile, strom, uiFile? })` returning an `http.Server`. Routes: `GET /api/config`, `POST /api/config`, `GET /api/status`, `POST /api/start`, `POST /api/stop`, `GET /health`, `GET /` (UI).

- [ ] **Step 1: Write the failing test**

Create `/home/nygard/open-live-srt-gateway/control/test/server.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createControlServer } from "../server.mjs";

function makeFakeStrom() {
  let flows = [];
  const calls = [];
  return {
    calls,
    setFlows(f) { flows = f; },
    async listFlows() { return flows; },
    async deleteFlows() { const n = flows.length; flows = []; return n; },
    async req(method, path, body) {
      calls.push({ method, path, body });
      if (method === "POST" && path === "/api/flows") {
        const flow = { ...body, id: "id-" + calls.length, running: false };
        flows.push(flow);
        return { ok: true, status: 200, data: { flow } };
      }
      return { ok: true, status: 200, data: {} };
    },
  };
}

async function withServer(strom, fn) {
  const dir = mkdtempSync(join(tmpdir(), "srtctl-"));
  const configFile = join(dir, "srt-config.json");
  const server = createControlServer({ configFile, strom, uiFile: null });
  await new Promise((r) => server.listen(0, r));
  const base = "http://127.0.0.1:" + server.address().port;
  try {
    await fn(base, configFile);
  } finally {
    await new Promise((r) => server.close(r));
  }
}

test("GET /api/config seeds and returns default", async () => {
  await withServer(makeFakeStrom(), async (base) => {
    const res = await fetch(base + "/api/config");
    assert.equal(res.status, 200);
    const cfg = await res.json();
    assert.equal(cfg.ports.length, 12);
    assert.equal(cfg.stream.container, "mpegts");
  });
});

test("POST /api/config normalizes and persists", async () => {
  await withServer(makeFakeStrom(), async (base) => {
    const post = await fetch(base + "/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ stream: { codec: "h265", bitrate: 24, container: "efp" }, ports: [{ id: "SDI1", role: "sender", address: "srt://a" }] }),
    });
    assert.equal(post.status, 200);
    const cfg = await (await fetch(base + "/api/config")).json();
    assert.equal(cfg.stream.codec, "h265");
    assert.equal(cfg.stream.bitrate, 24);
    assert.equal(cfg.ports[0].role, "sender");
  });
});

test("POST /api/start applies config and returns counts", async () => {
  const strom = makeFakeStrom();
  await withServer(strom, async (base) => {
    await fetch(base + "/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ stream: { container: "mpegts" }, ports: [{ id: "SDI1", role: "sender", address: "srt://a" }] }),
    });
    const res = await fetch(base + "/api/start", { method: "POST" });
    assert.equal(res.status, 200);
    const r = await res.json();
    assert.equal(r.created, 1);
    assert.equal(r.failed, 0);
  });
});

test("POST /api/stop removes flows", async () => {
  const strom = makeFakeStrom();
  strom.setFlows([{ id: "a", name: "srt-gw-SDI1" }]);
  await withServer(strom, async (base) => {
    const res = await fetch(base + "/api/stop", { method: "POST" });
    const r = await res.json();
    assert.equal(r.ok, true);
    assert.equal(r.removed, 1);
  });
});

test("GET /api/status returns channels", async () => {
  const strom = makeFakeStrom();
  strom.setFlows([{ id: "a", name: "srt-gw-SDI1", running: true }]);
  await withServer(strom, async (base) => {
    await fetch(base + "/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ports: [{ id: "SDI1", role: "sender", address: "srt://a" }] }),
    });
    const status = await (await fetch(base + "/api/status")).json();
    assert.equal(status.channels[0].color, "green");
  });
});

test("GET /health returns ok", async () => {
  await withServer(makeFakeStrom(), async (base) => {
    const res = await fetch(base + "/health");
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test control/test/server.test.mjs`
Expected: FAIL — `Cannot find module '../server.mjs'`.

- [ ] **Step 3: Write minimal implementation**

Create `/home/nygard/open-live-srt-gateway/control/server.mjs`:

```js
import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultConfig, normalizeConfig } from "./lib/config.mjs";
import { makeStromClient, applyConfig, getStatus } from "./lib/srtops.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_UI = join(__dirname, "public", "index.html");

function sendJson(res, code, data) {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function readBody(req) {
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try { resolve(JSON.parse(body)); } catch { resolve(undefined); }
    });
  });
}

export function createControlServer({ configFile, strom, uiFile = DEFAULT_UI }) {
  function readConfig() {
    try {
      return normalizeConfig(JSON.parse(readFileSync(configFile, "utf8")));
    } catch {
      const cfg = defaultConfig();
      writeConfig(cfg);
      return cfg;
    }
  }

  function writeConfig(cfg) {
    mkdirSync(dirname(configFile), { recursive: true });
    writeFileSync(configFile, JSON.stringify(normalizeConfig(cfg), null, 2));
  }

  return createServer(async (req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

    const path = new URL(req.url, "http://localhost").pathname;

    if (path === "/health" && req.method === "GET") return sendJson(res, 200, { ok: true });

    if (path === "/api/config" && req.method === "GET") return sendJson(res, 200, readConfig());

    if (path === "/api/config" && req.method === "POST") {
      const body = await readBody(req);
      if (!body) return sendJson(res, 400, { ok: false, error: "Invalid JSON" });
      writeConfig(body);
      return sendJson(res, 200, { ok: true });
    }

    if (path === "/api/status" && req.method === "GET") {
      const cfg = readConfig();
      return sendJson(res, 200, await getStatus(strom, cfg));
    }

    if (path === "/api/start" && req.method === "POST") {
      const cfg = readConfig();
      const r = await applyConfig(strom, cfg);
      return sendJson(res, 200, r);
    }

    if (path === "/api/stop" && req.method === "POST") {
      const removed = await strom.deleteFlows();
      return sendJson(res, 200, { ok: true, removed });
    }

    if ((path === "/" || path === "/index.html") && req.method === "GET") {
      if (uiFile && existsSync(uiFile)) {
        res.writeHead(200, { "Content-Type": "text/html" });
        res.end(readFileSync(uiFile, "utf8"));
        return;
      }
      res.writeHead(404); res.end("UI not found");
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: false, error: "Not found" }));
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const PORT = parseInt(process.env.PORT || "3000");
  const CONFIG_FILE = process.env.SRT_CONFIG_FILE || "/data/srt-config.json";
  const STROM_URL = process.env.SRT_STROM_URL || "http://srt-gateway:8080";
  const STROM_KEY = process.env.SRT_STROM_KEY || "dev-key-local";
  const strom = makeStromClient(STROM_URL, STROM_KEY);
  createControlServer({ configFile: CONFIG_FILE, strom }).listen(PORT, () => {
    console.log("SRT Gateway control: http://localhost:" + PORT);
  });
}
```

Note: imports are `createServer` from `node:http` only — no unused imports.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test control/test/server.test.mjs`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Run the whole suite**

Run: `node --test`
Expected: PASS — all test files (24 tests) pass.

- [ ] **Step 6: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git add control/server.mjs control/test/server.test.mjs
git commit -m "feat: SRT gateway control HTTP API"
```

---

### Task 5: Web UI page

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/public/index.html`

**Interfaces:**
- Consumes: HTTP routes from Task 4 (`/api/config`, `/api/status`, `/api/start`, `/api/stop`).
- Produces: standalone browser UI at `/`.

- [ ] **Step 1: Write the UI page**

Create `/home/nygard/open-live-srt-gateway/control/public/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SRT Gateway</title>
<style>
:root{--bg:#0b0f14;--card:#141a21;--border:#222a33;--green:#00e676;--red:#ff5252;--amber:#ffc107;--text:#c9d1d9;--muted:#6e7681;--accent:#58a6ff}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
header{display:flex;align-items:center;justify-content:space-between;padding:16px 24px;border-bottom:1px solid var(--border)}
header h1{font-size:20px;font-weight:600}
header .meta{font-size:12px;color:var(--muted)}
main{max-width:900px;margin:24px auto;padding:0 24px}
.srt-lights{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.srt-light{display:inline-flex;align-items:center;gap:5px;background:var(--card);border:1px solid var(--border);border-radius:12px;padding:2px 10px;font-size:12px;font-weight:600;color:var(--text);cursor:default}
.srt-light:before{content:'';width:9px;height:9px;border-radius:50%;background:var(--muted)}
.srt-light.green:before{background:var(--green);box-shadow:0 0 4px var(--green)}
.srt-light.red:before{background:var(--red);box-shadow:0 0 4px var(--red)}
.srt-light.off{color:var(--muted)}
.srt-light.off:before{background:var(--muted);opacity:.35}
.srt-meta{display:flex;align-items:center;gap:8px;margin-top:14px;flex-wrap:wrap;font-size:12px;color:var(--muted)}
.srt-ctr{margin-right:auto}
.btn{padding:9px 18px;border-radius:6px;border:1px solid var(--border);background:var(--card);color:var(--text);font-size:13px;font-weight:600;cursor:pointer;transition:.15s;letter-spacing:.3px}
.btn:hover{background:#1c2530;border-color:var(--accent)}
.btn.show{border-color:var(--accent);color:var(--accent)}
.btn.stop{border-color:var(--red);color:var(--red)}
.btn.stop:hover{background:#2a1515}
.btn.start{border-color:var(--green);color:var(--green)}
.btn.start:hover{background:#152a1a}
.overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:50;align-items:center;justify-content:center}
.overlay.open{display:flex}
.modal{background:var(--card);border:1px solid var(--border);border-radius:10px;width:820px;max-width:94vw;max-height:80vh;overflow-y:auto;padding:0}
.modal-header{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:1px solid var(--border)}
.modal-header h3{font-size:15px;font-weight:600;text-transform:uppercase}
.modal .close-btn{background:none;border:none;color:var(--muted);font-size:20px;cursor:pointer;padding:0 6px;line-height:1}
.modal .close-btn:hover{color:var(--red)}
.ps-table{width:100%;border-collapse:collapse;font-size:12px}
.ps-table th{text-align:left;padding:8px 20px;color:var(--muted);font-weight:600;text-transform:uppercase;font-size:10px;letter-spacing:.5px;border-bottom:1px solid var(--border)}
.ps-table td{padding:10px 20px;border-bottom:1px solid #1a1f27;font-size:12px}
.ps-table input,.ps-table select{background:var(--card);color:var(--text);border:1px solid var(--border);padding:4px}
.modal-footer{padding:14px 20px;border-top:1px solid var(--border);display:flex;justify-content:flex-end;gap:8px}
.toast{position:fixed;bottom:20px;right:20px;background:var(--card);border:1px solid var(--border);border-radius:8px;padding:12px 18px;font-size:13px;z-index:100}
.toast.ok{border-color:var(--green)}.toast.err{border-color:var(--red)}
</style>
</head>
<body>
<header><h1>SRT Gateway</h1><div class="meta" id="meta">--</div></header>
<main id="app"><p style="color:var(--muted);text-align:center;padding:40px;">Loading...</p></main>
<div class="overlay" id="overlay" onclick="if(event.target===this)closeModal()"><div class="modal" id="modal"></div></div>
<script>
var API='/api';
var polling=false;var srtCfg=null;
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function toast(msg,ok){var el=document.createElement('div');el.className='toast '+(ok?'ok':'err');el.textContent=msg;document.body.appendChild(el);setTimeout(function(){el.remove()},4000)}
function render(srt){
 var active=0,running=0;
 for(var i=0;i<srt.channels.length;i++){if(srt.channels[i].role!=='off')active++;if(srt.channels[i].running)running++;}
 var h='<div class="srt-lights">';
 for(var i=0;i<srt.channels.length;i++){var ch=srt.channels[i];
  var audio=ch.container==='efp'?'Opus 64k':'AAC 128k';
  var tip=ch.sdi+(ch.role!=='off'?' - '+ch.role+' - '+(ch.container||'mpegts')+' - '+audio+' - '+(ch.address||'no addr'):' - off');
  h+='<span class="srt-light '+ch.color+'" title="'+esc(tip)+'">'+esc(ch.sdi)+'</span>';
 }
 h+='</div>';
 var st=srt.stream||{};var container=st.container==='efp'?'EFP':'MPEG-TS';
 var audio=st.container==='efp'?'Opus 64k':'AAC 128k';
 h+='<div class="srt-meta">';
 h+='<span class="srt-ctr">'+container+' &middot; '+esc((st.codec||'h264').toUpperCase())+' &middot; '+(st.bitrate||6)+' Mbps'+(st.video_mode&&st.video_mode!=='auto'?' &middot; '+esc(st.video_mode):'')+' &middot; '+audio+' &mdash; '+(active>0?(running+'/'+active+' running'):'no streams configured')+'</span>';
 h+='<button class="btn show" onclick="openSettings()">&#9881; Settings</button>';
 if(running>0){h+='<button class="btn start" onclick="srtStart()">Restart</button><button class="btn stop" onclick="srtStop()">Stop</button>';}
 else{h+='<button class="btn start" onclick="srtStart()">Start</button>';}
 h+='</div>';
 document.getElementById('app').innerHTML=h;
 document.getElementById('meta').textContent=new Date().toLocaleTimeString();
}
async function poll(){
 try{var r=await fetch(API+'/status');render(await r.json())}
 catch(e){document.getElementById('app').innerHTML='<p style="color:var(--red);text-align:center;padding:40px;">Connection lost - retrying...</p>'}
 setTimeout(poll,5000);
}
async function openSettings(){
 try{srtCfg=await (await fetch(API+'/config')).json()}catch(e){toast('Failed to load config: '+e.message,false);return}
 if(!srtCfg.ports){toast('Invalid config',false);return}
 if(!srtCfg.stream)srtCfg.stream={codec:'h264',bitrate:6,video_mode:'auto',container:'mpegts'};
 var h='<div class="modal-header"><h3>SRT Gateway Settings</h3><button class="close-btn" onclick="closeModal()">x</button></div>';
 h+='<div style="padding:16px 20px">';
 h+='<h3 style="margin:0 0 6px">Stream Settings (all channels)</h3>';
 h+='<table class="ps-table"><thead><tr><th>Container</th><th>Codec</th><th>Bitrate (Mbps)</th><th>Video Mode</th></tr></thead><tbody><tr>';
 h+='<td><select id="st_container"><option value="mpegts"'+(srtCfg.stream.container!=='efp'?' selected':'')+'>mpegts</option><option value="efp"'+(srtCfg.stream.container==='efp'?' selected':'')+'>efp</option></select></td>';
 h+='<td><select id="st_codec"><option value="h264"'+(srtCfg.stream.codec==='h264'?' selected':'')+'>h264</option><option value="h265"'+(srtCfg.stream.codec==='h265'?' selected':'')+'>h265</option></select></td>';
 h+='<td><select id="st_bitrate">';var brs=[4,6,12,24];
 for(var b=0;b<brs.length;b++){h+='<option value="'+brs[b]+'"'+(Number(srtCfg.stream.bitrate)===brs[b]?' selected':'')+'>'+brs[b]+'</option>'}
 h+='</select></td>';
 h+='<td><input id="st_mode" value="'+esc(srtCfg.stream.video_mode||'auto')+'" placeholder="auto or e.g. 1080p50" style="width:110px"></td>';
 h+='</tr></tbody></table>';
 h+='<p style="color:var(--muted);font-size:11px;margin:6px 0 0">Audio: mpegts = AAC ~128 kbps, EFP = Opus 64 kbps (fixed by the container).</p>';
 h+='<h3 style="margin:16px 0 6px">SDI Ports</h3>';
 h+='<p style="color:var(--muted);font-size:11px;margin:4px 0 6px">Device number is automatic: SDI1=0, SDI2=1, ... SDI12=11.</p>';
 h+='<table class="ps-table"><thead><tr><th>SDI Port</th><th>Role</th><th>SRT Address</th></tr></thead><tbody>';
 for(var i=0;i<srtCfg.ports.length;i++){var p=srtCfg.ports[i];
  h+='<tr><td><input id="sdi_'+i+'" value="'+esc(p.id)+'" style="width:80px"></td>';
  h+='<td><select id="role_'+i+'">';var ro=['off','sender','receiver'];
  for(var j=0;j<ro.length;j++){h+='<option value="'+ro[j]+'"'+(p.role===ro[j]?' selected':'')+'>'+ro[j]+'</option>'}
  h+='</select></td>';
  h+='<td><input id="addr_'+i+'" value="'+esc(p.address)+'" placeholder="srt://host:port?streamid=..." style="width:100%"></td></tr>';
 }
 h+='</tbody></table>';
 h+='<p style="color:var(--muted);font-size:11px;margin-top:10px">SRT blocks are always callers. Saving restarts the streams.</p>';
 h+='</div>';
 h+='<div class="modal-footer"><button class="btn" onclick="closeModal()">Cancel</button><button class="btn start" onclick="saveSettings()">Save</button></div>';
 document.getElementById('modal').innerHTML=h;
 document.getElementById('overlay').classList.add('open');
}
async function saveSettings(){
 srtCfg.stream.codec=document.getElementById('st_codec').value;
 srtCfg.stream.bitrate=Number(document.getElementById('st_bitrate').value);
 srtCfg.stream.video_mode=document.getElementById('st_mode').value;
 srtCfg.stream.container=document.getElementById('st_container').value;
 for(var i=0;i<srtCfg.ports.length;i++){srtCfg.ports[i].id=document.getElementById('sdi_'+i).value;srtCfg.ports[i].role=document.getElementById('role_'+i).value;srtCfg.ports[i].address=document.getElementById('addr_'+i).value;}
 try{var r=await fetch(API+'/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(srtCfg)});var d=await r.json();
  if(d.ok){toast('Settings saved',true);closeModal();srtStart()}
  else{toast('Error: '+(d.error||'unknown'),false)}
 }catch(e){toast('Request failed: '+e.message,false)}
}
async function srtStart(){
 toast('Starting SRT streams...',true);
 try{var r=await fetch(API+'/start',{method:'POST'});var d=await r.json();
  if(d.created>0){toast('Started '+d.created+' streams',true);setTimeout(poll,2000)}
  else{toast('Error: '+(d.failed>0?d.failed+' failed':'no streams started'),false)}
 }catch(e){toast('Request failed: '+e.message,false)}
}
async function srtStop(){
 toast('Stopping SRT streams...',true);
 try{var r=await fetch(API+'/stop',{method:'POST'});var d=await r.json();
  if(d.ok){toast('Stopped '+d.removed+' streams',true);setTimeout(poll,2000)}
  else{toast('Error: '+(d.error||'unknown'),false)}
 }catch(e){toast('Request failed: '+e.message,false)}
}
function closeModal(){document.getElementById('overlay').classList.remove('open')}
poll();
</script>
</body>
</html>
```

- [ ] **Step 2: Verify the page is served**

Run (from `/home/nygard/open-live-srt-gateway/control`):
```bash
SRT_CONFIG_FILE=/tmp/srt-ui-test.json PORT=3999 node server.mjs &
sleep 1
curl -s http://127.0.0.1:3999/ | grep -c "SRT Gateway"
curl -s http://127.0.0.1:3999/health
kill %1
```
Expected: `2` (title + header), then `{"ok":true}`.

- [ ] **Step 3: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git add control/public/index.html
git commit -m "feat: SRT gateway web UI"
```

---

### Task 6: Dockerfile, compose, docs, default config

**Files:**
- Create: `/home/nygard/open-live-srt-gateway/control/Dockerfile`
- Create: `/home/nygard/open-live-srt-gateway/docker-compose.yml`
- Create: `/home/nygard/open-live-srt-gateway/.env.example`
- Create: `/home/nygard/open-live-srt-gateway/config/srt-config.default.json`
- Create: `/home/nygard/open-live-srt-gateway/README.md`
- Create: `/home/nygard/open-live-srt-gateway/LICENSE`

**Interfaces:**
- Consumes: control service (Tasks 4-5), flow semantics (Task 2).
- Produces: runnable `docker compose up -d` stack (`open-live-srt-gateway`, `open-live-srt-control`).

- [ ] **Step 1: Write the control Dockerfile**

Create `/home/nygard/open-live-srt-gateway/control/Dockerfile`:

```dockerfile
FROM node:23-slim
WORKDIR /app
COPY package.json ./
COPY lib ./lib
COPY public ./public
COPY server.mjs ./
ENV PORT=3000
ENV SRT_CONFIG_FILE=/data/srt-config.json
EXPOSE 3000
CMD ["node", "server.mjs"]
```

- [ ] **Step 2: Write the default config**

Create `/home/nygard/open-live-srt-gateway/config/srt-config.default.json`:

```json
{
  "stream": {
    "codec": "h264",
    "bitrate": 6,
    "video_mode": "auto",
    "container": "mpegts"
  },
  "ports": [
    { "id": "SDI1", "role": "off", "address": "" },
    { "id": "SDI2", "role": "off", "address": "" },
    { "id": "SDI3", "role": "off", "address": "" },
    { "id": "SDI4", "role": "off", "address": "" },
    { "id": "SDI5", "role": "off", "address": "" },
    { "id": "SDI6", "role": "off", "address": "" },
    { "id": "SDI7", "role": "off", "address": "" },
    { "id": "SDI8", "role": "off", "address": "" },
    { "id": "SDI9", "role": "off", "address": "" },
    { "id": "SDI10", "role": "off", "address": "" },
    { "id": "SDI11", "role": "off", "address": "" },
    { "id": "SDI12", "role": "off", "address": "" }
  ]
}
```

- [ ] **Step 3: Write the compose file**

Create `/home/nygard/open-live-srt-gateway/docker-compose.yml`:

```yaml
services:
  srt-gateway:
    image: ${STROM_IMAGE:-open-live-strom-ndi:0.6.12}
    container_name: open-live-srt-gateway
    privileged: true
    restart: unless-stopped
    environment:
      - TZ=${TZ:-Europe/Stockholm}
      - STROM_API_KEY=${STROM_API_KEY:-dev-key-local}
      - STROM_ADMIN_USER=${STROM_ADMIN_USER:-admin}
      - STROM_ADMIN_PASSWORD_HASH=${STROM_ADMIN_PASSWORD_HASH}
      - STROM_SERVER_ICE_SERVERS=${STROM_ICE_SERVERS:-stun:stun.l.google.com:19302}
      - NVIDIA_DRIVER_CAPABILITIES=all
      - GST_PLUGIN_FEATURE_RANK=nvcudadec:0,nvcuviddec:0,nvh264dec:0,nvvp8dec:0,nvvp9dec:0
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    cap_add:
      - SYS_NICE
    volumes:
      - srt-gateway-data:/data
      - /dev/blackmagic:/dev/blackmagic
      - /usr/lib/libDeckLinkAPI.so:/lib/libDeckLinkAPI.so:ro
      - /usr/lib/libDeckLinkPreviewAPI.so:/lib/libDeckLinkPreviewAPI.so:ro
      - /usr/lib/blackmagic:/lib/blackmagic:ro
    ports:
      - "0.0.0.0:8081:8080"
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"]
      interval: 5s
      timeout: 3s
      retries: 20
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

  srt-control:
    build: ./control
    container_name: open-live-srt-control
    restart: unless-stopped
    depends_on:
      - srt-gateway
    environment:
      - TZ=${TZ:-Europe/Stockholm}
      - PORT=3000
      - SRT_CONFIG_FILE=/data/srt-config.json
      - SRT_STROM_URL=http://srt-gateway:8080
      - SRT_STROM_KEY=${STROM_API_KEY:-dev-key-local}
    volumes:
      - ./data:/data
      - ./config/srt-config.default.json:/app/config/srt-config.default.json:ro
    ports:
      - "0.0.0.0:8090:3000"
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://localhost:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 10s
      timeout: 3s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  srt-gateway-data:
```

Note: the config bind-mounts `./data` (gitignored) instead of a named volume so an existing local `srt-config.json` can be seeded by copy. This slightly supersedes the spec's named volume to preserve the local/gitignored config workflow.

- [ ] **Step 4: Write `.env.example`**

Create `/home/nygard/open-live-srt-gateway/.env.example`:

```
# Custom Strom fork image (must be prebuilt — see README). Never use upstream strom:latest.
STROM_IMAGE=open-live-strom-ndi:0.6.12
STROM_API_KEY=dev-key-local
STROM_ADMIN_USER=admin
STROM_ADMIN_PASSWORD_HASH=
TZ=Europe/Stockholm
STROM_ICE_SERVERS=stun:stun.l.google.com:19302
```

- [ ] **Step 5: Write the README**

Create `/home/nygard/open-live-srt-gateway/README.md`:

```markdown
# Open Live SRT Gateway

Standalone SRT gateway for the [Open Live](https://github.com/Eyevinn/open-live) broadcast
platform. Captures Blackmagic DeckLink SDI and sends **MPEG-TS or EFP** over SRT (as an SRT
caller) to a relay, and can receive SRT back to SDI output.

Includes its own control API and web UI on port **8090**.

## Requirements

- Linux host (no macOS/Windows support)
- Docker + Docker Compose
- NVIDIA GPU + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- Blackmagic DeckLink card configured via **Blackmagic Desktop Video** (card profile + connector mapping)
- The custom Strom fork image (see below) — the cards require it

## Strom image

This gateway uses a **custom Strom fork**, default `open-live-strom-ndi:0.6.12`, built from
[markusnygard/strom](https://github.com/markusnygard/strom). Upstream `strom:latest` will
**not** work: it bundles a DeckLink GStreamer plugin that is incompatible with Desktop Video
15.3, and it lacks the `efp` feature the SRT blocks need.

Build it before starting (source clone at `../strom`):

```bash
docker build -t open-live-strom-ndi:0.6.12 -f ../open-live/docker/strom-ndi-fixed/Dockerfile ../strom
```

Override the tag in `.env` if you build a different one.

## Run

```bash
cp .env.example .env
# edit .env: set STROM_ADMIN_PASSWORD_HASH, STROM_ICE_SERVERS, etc.
mkdir -p data
docker compose up -d
```

- Control UI/API: <http://localhost:8090>
- Strom capture container: port 8081

## Configure

Open the control UI. For each SDI port choose `sender`, `receiver`, or `off`, and set an SRT
address such as:

```
srt://RELAY_HOST:23001?streamid=publish:srt_01
```

`mode=caller` is added automatically. Available conventions (Haivision relay):

- publish ports `23001–23005` (`streamid=publish:srt_01…05`)
- read ports `23101+` (`streamid=read:srt_01…`)

Audio is fixed by container: MPEG-TS = AAC, EFP = Opus. Device number = SDI index
(SDI1=0 … SDI12=11).

## Config storage

Runtime config lives in `./data/srt-config.json` (gitignored) and is seeded from
`config/srt-config.default.json` on first run. **Never commit SRT addresses.**

## API

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/api/config` | current config |
| POST | `/api/config` | save config |
| GET  | `/api/status` | flows + channel state |
| POST | `/api/start`  | rebuild + start flows |
| POST | `/api/stop`   | stop + delete flows |
| GET  | `/health`     | health probe |

## License

MIT
```

- [ ] **Step 6: Write the LICENSE**

Create `/home/nygard/open-live-srt-gateway/LICENSE`:

```
MIT License

Copyright (c) 2026 Markus Nygård

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 7: Validate compose and the image build**

Run (from `/home/nygard/open-live-srt-gateway`):
```bash
docker compose config >/dev/null && echo "compose ok"
docker build -t open-live-srt-control:test ./control && echo "build ok"
```
Expected: `compose ok`, `build ok`.

- [ ] **Step 8: Commit**

```bash
cd /home/nygard/open-live-srt-gateway
git add control/Dockerfile docker-compose.yml .env.example config/srt-config.default.json README.md LICENSE
git commit -m "feat: gateway container, compose, default config, docs"
```

---

### Task 7: Publish the new repo to GitHub

**Files:** none (git/remote operation).

- [ ] **Step 1: Ensure the full test suite passes**

Run: `node --test` (from `/home/nygard/open-live-srt-gateway/control`)
Expected: PASS — all tests.

- [ ] **Step 2: Create the GitHub repo and push**

```bash
cd /home/nygard/open-live-srt-gateway
git branch -M main
gh repo create markusnygard/open-live-srt-gateway --public --source=. --remote=origin --description "Standalone SRT gateway for Open Live (DeckLink SDI to MPEG-TS/EFP over SRT)" --push
```

Expected: repo created and `main` pushed. Verify:
```bash
git remote -v
gh repo view markusnygard/open-live-srt-gateway --json name,visibility,url
```

- [ ] **Step 3: Report the URL**

Output the repo URL (`https://github.com/markusnygard/open-live-srt-gateway`).

---

### Task 8: Workspace dashboard — drop SRT control, add status card

**Files:**
- Modify: `/home/nygard/open-live/dashboard/server.mjs`

**Interfaces:**
- Consumes: `SRT_GATEWAY_DIR` (sibling clone), container names `open-live-srt-gateway` / `open-live-srt-control`.
- Produces: `CONTAINERS.srt`, `runSrtCompose(action)`, `GET /api/srt/status`, `POST /api/srt/up`, `POST /api/srt/down`, JS `renderSrt`, `srtUp`, `srtDown`.

- [ ] **Step 1: Remove the SRT control block**

In `/home/nygard/open-live/dashboard/server.mjs`, delete lines 81-259 — the block beginning with the comment `// ── SRT Gateway (drives Strom EFP-SRT flows; ...` and ending with the closing `}` of `srtStatus()` immediately before the blank line and `async function probeVersion`.

- [ ] **Step 2: Remove the `readFileSync`/`writeFileSync` import**

Confirm no remaining usage:
```bash
cd /home/nygard/open-live
grep -n "readFileSync\|writeFileSync" dashboard/server.mjs
```
Expected: only the import on line 4. Delete that import line so the imports are:

```js
import { createServer, get as httpGet } from "node:http";
import { execSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
```

- [ ] **Step 3: Add the SRT container group and gateway dir**

In `CONTAINERS`, after the `hybrid` block, add:

```js
  srt: {
    gateway: "open-live-srt-gateway",
    control: "open-live-srt-control",
  },
```

After `const ROOT = join(__dirname, "..");`, add:

```js
const SRT_GATEWAY_DIR = process.env.SRT_GATEWAY_DIR || join(ROOT, "..", "open-live-srt-gateway");
```

- [ ] **Step 4: Remove the explicit `result.srt` assignment**

In `allStatus()`, delete the line:

```js
  result.srt = await srtStatus();
```

(The `CONTAINERS` loop now populates `result.srt`.)

- [ ] **Step 5: Add `runSrtCompose` after `runCompose`**

Insert immediately after the closing `}` of `runCompose`:

```js
function runSrtCompose(action) {
  const file = join(SRT_GATEWAY_DIR, "docker-compose.yml");
  const args = action === "down" ? "down" : "up -d";
  const cmd = "docker compose -f \"" + file + "\" " + args;
  try {
    const out = sh(cmd, { timeout: 120000, cwd: SRT_GATEWAY_DIR });
    return { ok: true, command: action, output: out };
  } catch (e) {
    return { ok: false, command: action, error: e.stderr || e.message };
  }
}
```

- [ ] **Step 6: Replace the `/api/srt/*` routes**

Delete the four routes (`/api/srt/config` GET + POST, `/api/srt/start`, `/api/srt/stop`) and add in their place:

```js
  if (path === "/api/srt/up" && req.method === "POST") {
    const result = runSrtCompose("up");
    sendJson(res, result.ok ? 200 : 500, result);
    return;
  }
  if (path === "/api/srt/down" && req.method === "POST") {
    const result = runSrtCompose("down");
    sendJson(res, result.ok ? 200 : 500, result);
    return;
  }
```

- [ ] **Step 7: Remove the SRT CSS**

Delete the CSS lines `.srt-lights` through `.srt-ctr` (the block at former lines 569-577). Leave `.btn` and everything else intact.

- [ ] **Step 8: Replace the SRT browser JS**

Delete the JS block from `var srtCfg=null;` through the closing `}` of `srtStop` (former lines 750-864). Insert the following in its place:

```js
function renderSrt(ctr){
 var gw=ctr.gateway||{};var ctl=ctr.control||{};
 var running=(gw.status==='running'&&ctl.status==='running');
 var h='<div class="mode-section">';
 h+='<div class="mode-header"><h2>SRT GATEWAY</h2>';
 h+='<span class="mode-badge '+(running?'active':'inactive')+'">'+(running?'running':'stopped')+'</span></div>';
 h+='<div class="cards">';
 var names=['gateway','control'];
 for(var i=0;i<names.length;i++){
  var n=names[i];var c=ctr[n]||{};var st=c.status||'not created';
  var img=c.image||'-';var up=c.uptimeMs?fmtUptime(c.uptimeMs):'';
  h+='<div class="card"><div class="name">'+n+'</div>';
  h+='<div class="info"><span>img: '+img+'</span><span>health: '+(c.health||'N/A')+'</span>'+(up?'<span>up: '+up+'</span>':'')+'</div>';
  h+='<div class="row"><span class="status '+cls(st)+'">'+dot(st)+' '+st.toUpperCase()+'</span></div></div>';
 }
 h+='</div>';
 h+='<div class="actions">';
 h+='<button class="btn start" onclick="srtUp()">Start</button>';
 if(running)h+='<button class="btn stop" onclick="srtDown()">Stop</button>';
 if(ctl.status==='running')h+='<button class="btn studio-btn" onclick="window.open(\'http://\'+window.location.hostname+\':8090\',\'_blank\')">Open SRT Gateway</button>';
 h+='</div></div>';
 return h;
}
async function srtUp(){
 toast('Starting SRT Gateway...',true);
 try{
  var r=await fetch(API+'/srt/up',{method:'POST'});
  var d=await r.json();
  if(d.ok){toast('SRT Gateway starting...',true);setTimeout(poll,3000)}
  else{toast('Error: '+(d.error||'unknown'),false)}
 }catch(e){toast('Request failed: '+e.message,false)}
}
async function srtDown(){
 if(!confirm('Stop the SRT Gateway (removes its containers)?'))return;
 toast('Stopping SRT Gateway...',true);
 try{
  var r=await fetch(API+'/srt/down',{method:'POST'});
  var d=await r.json();
  if(d.ok){toast('SRT Gateway stopped.',true);setTimeout(poll,2000)}
  else{toast('Error: '+(d.error||'unknown'),false)}
 }catch(e){toast('Request failed: '+e.message,false)}
}
```

- [ ] **Step 9: Syntax-check**

Run: `node --check dashboard/server.mjs`
Expected: no output (exit 0).

- [ ] **Step 10: Smoke-test the dashboard**

Run:
```bash
cd /home/nygard/open-live
node dashboard/server.mjs &
sleep 1
curl -s http://127.0.0.1:3100/api/status | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(d.keys())); print(sorted(d.get('srt',{}).keys()))"
curl -s -X POST http://127.0.0.1:3100/api/srt/up -o /dev/null -w "%{http_code}\n"
kill %1
```
Expected: `['hybrid','local','srt']` and `['control','gateway']`, then `200` (or `500` if the image build fails; the route itself must respond JSON).

- [ ] **Step 11: Commit**

```bash
cd /home/nygard/open-live
git add dashboard/server.mjs
git commit -m "refactor(dashboard): delegate SRT gateway to standalone repo"
```

---

### Task 9: Workspace cleanup and docs

**Files:**
- Delete: `/home/nygard/open-live/open_live_srt/`
- Modify: `/home/nygard/open-live/.gitignore`
- Modify: `/home/nygard/open-live/README.md`

- [ ] **Step 1: Preserve the local SRT config before deleting**

```bash
mkdir -p /home/nygard/open-live-srt-gateway/data
cp /home/nygard/open-live/open_live_srt/srt-config.json /home/nygard/open-live-srt-gateway/data/srt-config.json
cp /home/nygard/open-live/open_live_srt/.env /home/nygard/open-live-srt-gateway/.env
```
(Confirm `/home/nygard/open-live-srt-gateway/data/` and `.env` are gitignored — they are, from Task 1.)

- [ ] **Step 2: Delete the workspace SRT folder**

```bash
cd /home/nygard/open-live
git rm -r open_live_srt
```
Expected: removes the tracked `docker-compose.yml`; untracked `srt-config.json`/`.env` were copied already.

- [ ] **Step 3: Remove the SRT `.gitignore` entries**

Delete lines 6-12 of `/home/nygard/open-live/.gitignore` (the `# SRT gateway local config` comment and the six `open_live_srt/...` lines). Resulting file:

```
node_modules/
.env
db-data/
.pnpm-store/

# Sub-repos (managed separately)
backend/
frontend/
strom/
open-live-studio/
studio/
```

- [ ] **Step 4: Update README Option C**

In `/home/nygard/open-live/README.md`, replace the entire "Option C" block (from `#### Option C — SRT Gateway (Linux + DeckLink only)` through the paragraph ending `read ports \`23101+\`.`) with:

```markdown
#### Option C — SRT Gateway (Linux + DeckLink only)

The gateway lives in its own repo. Clone it as a sibling of this workspace:

```bash
cd ..
git clone https://github.com/markusnygard/open-live-srt-gateway.git
cd open-live-srt-gateway
cp .env.example .env
mkdir -p data
docker compose up -d
```

Then start it from the dashboard's **SRT GATEWAY** card (Start button), or use the commands
above directly. The gateway's own UI and settings live at **http://localhost:8090**; the
dashboard only starts/stops it and links to it. See
`open-live-srt-gateway/README.md` for the DeckLink and custom-image requirements.
```

- [ ] **Step 5: Update the README folder tree and Files section**

In the "Your folder structure should be" block, replace:

```
    ├── open_live_hybrid/
    ├── open_live_srt/
    └── MEMORY.md
```

with:

```
    ├── open_live_hybrid/
    └── MEMORY.md
```

In the `open_live_srt/` Files block, replace:

```
open_live_srt/
├── docker-compose.yml      # SRT gateway Strom (DeckLink capture → SRT relay)
└── ...                     # srt-config.json / *.conf are local, gitignored
```

with:

```
# SRT Gateway now lives in its own repo:
# https://github.com/markusnygard/open-live-srt-gateway
```

- [ ] **Step 6: Verify README has no stale local-path references**

Run:
```bash
cd /home/nygard/open-live
grep -n "open_live_srt" README.md || echo "clean"
```
Expected: `clean`.

- [ ] **Step 7: Commit**

```bash
cd /home/nygard/open-live
git add .gitignore README.md
git commit -m "chore: move SRT gateway out of workspace"
```

---

## Self-Review

**Spec coverage:**
- New repo (container + API + own UI) → Tasks 1-6. ✅
- Dashboard status card + Start/Stop + Open link → Task 8. ✅
- Separate GitHub repo, sibling clone → Tasks 1, 7, 9. ✅
- Control service container on :8090 → Tasks 4, 6. ✅
- Pin existing fork image + document → Task 6 (`.env.example`, README), Global Constraints. ✅
- Remove `open_live_srt/`, gitignore, README → Task 9. ✅
- Verification (compose config, tests, dashboard smoke, manual E2E) → Tasks 4, 6, 8; manual E2E noted. ✅

**Placeholder scan:** No TBD/TODO; every code step contains full content. ✅

**Type consistency:** `normalizeConfig`/`defaultConfig` (Task 1) used in Task 4; `SRT_FLOW_PREFIX`/`buildSrtFlow` (Task 2) used in Task 3; `makeStromClient`/`applyConfig`/`getStatus` (Task 3) used in Task 4; `createControlServer({configFile, strom, uiFile})` matches Task 4 tests; dashboard container names match compose (`open-live-srt-gateway`, `open-live-srt-control`). ✅

**Deviation from spec:** config uses a bind-mount `./data` instead of a named volume, to preserve the local/gitignored config workflow. Called out in Task 6 Step 3.
