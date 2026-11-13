<!--
SPDX-FileCopyrightText: 2026 Contributors to the EBU Open Live Production Cloud project
SPDX-License-Identifier: CC-BY-4.0
-->

# SRT Gateway Repo Split — Design

**Date:** 2026-09-10
**Status:** Approved (design), pending spec review

## Goal

Extract the SRT Gateway into its own self-contained GitHub repository so it can be
developed, deployed, and versioned independently. The workspace dashboard should
only start/stop the gateway and link to its own UI.

## Background

Today the SRT Gateway is split across the workspace repo:

- `open_live_srt/docker-compose.yml` — a privileged Strom container (port 8081)
  with DeckLink + NVIDIA mounts, capturing SDI and sending MPEG-TS/EFP over SRT.
- `dashboard/server.mjs` (lines ~81-259 + `/api/srt/*` routes + inline UI) — the
  control plane: config persistence, Strom flow builder, apply/status, and the
  SRT GATEWAY web section.
- `open_live_srt/srt-config.json` — runtime config (gitignored), plus legacy
  `srt-channels.conf` / `srt-stream.conf` (unused).

The control logic is ~200 lines embedded in the dashboard, coupled to the Strom
API and the dashboard's HTML string.

## Decisions

1. **New repo scope:** container + control REST API + its own web UI.
2. **Dashboard integration:** a single status card with Start/Stop/Restart and an
   "Open SRT Gateway" link; no SRT config in the workspace dashboard.
3. **Distribution:** separate GitHub repo `markusnygard/open-live-srt-gateway`,
   cloned as a sibling folder `../open-live-srt-gateway`.
4. **Control service runtime:** containerized Node service, host port **8090**.
5. **Strom image:** pin the existing fork image `open-live-strom-ndi:0.6.12` via
   `STROM_IMAGE`; document that it must be prebuilt from `markusnygard/strom`.
   Upstream `strom:latest` is NOT usable (DeckLink plugin mismatch + missing
   `efp` feature).

## New repo layout

```
open-live-srt-gateway/
├── docker-compose.yml          # srt-gateway (Strom) + srt-control
├── .env.example                # STROM_IMAGE, STROM_API_KEY, TZ, ICE, SRT_STROM_KEY
├── README.md                   # prereqs, DeckLink setup, run, image dependency
├── LICENSE                     # MIT
├── control/
│   ├── server.mjs              # SRT API + serves the web UI
│   ├── ui/                     # standalone SRT GATEWAY page (former renderSrt)
│   ├── package.json
│   └── Dockerfile              # node:23-slim
└── config/
    └── srt-config.default.json # template; runtime config in named volume
```

## Control service (port 8090)

Owns everything the dashboard's SRT code does today:

- Config: normalization/validation of `stream` (codec, bitrate, video_mode,
  container) and `ports` (12 SDI entries: id, role, address).
- Flow builder: `buildSrtFlow(port, index, stream)` producing sender
  (`decklink_input → videoenc → mpegtssrt_output|efpsrt_output`) and receiver
  (`mpegtssrt_input|efpsrt_input → decklink_output`) flows named `srt-gw-SDI*`.
- Apply: delete existing `srt-gw-*` flows, rebuild from config, start each.
- Status: list `srt-gw-*` flows, compute per-channel running/color.
- UI: the former `renderSrt` traffic-light + settings section as a standalone
  page.

REST endpoints:

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/api/config` | current normalized config |
| POST | `/api/config` | save config |
| GET  | `/api/status` | flows + per-channel state + stream settings |
| POST | `/api/start`  | apply config (rebuild + start flows) |
| POST | `/api/stop`   | delete/stop all `srt-gw-*` flows |

- Talks to Strom at `http://srt-gateway:8080` by default; overridable with
  `SRT_STROM_URL` / `SRT_STROM_KEY`.
- Config persisted at `/data/srt-config.json` in named volume `srt-config`,
  seeded from `srt-config.default.json` on first run.

## Compose

- `srt-gateway`: moved as-is from `open_live_srt/docker-compose.yml` — image
  `${STROM_IMAGE:-open-live-strom-ndi:0.6.12}`, `privileged`, NVIDIA reservation,
  DeckLink + lib mounts, port `8081:8080`, healthcheck, logging limits.
- `srt-control`: `node:23-slim` build, port `8090:3000`, `depends_on`
  `srt-gateway`, volume `srt-config:/data`, env for Strom URL/key.
- Both on the default compose network so `srt-control` reaches Strom by service
  name. SRT is outbound (caller), so no host networking is required.

## Workspace dashboard changes

Remove:

- SRT constants (`SRT_DIR`, `SRT_CONFIG_FILE`, `SRT_FLOW_PREFIX`, `SRT_STROM_URL`,
  `SRT_STROM_KEY`, `SRT_CODECS`, `SRT_BITRATES`).
- `defaultSrtConfig`, `loadSrtConfig`, `saveSrtConfig`, `ensureCaller`,
  `stromReq`, `listSrtFlows`, `deleteSrtFlows`, `buildSrtFlow`, `srtApply`,
  `srtStatus`.
- `/api/srt/config` (GET/POST), `/api/srt/start`, `/api/srt/stop` routes.
- `renderSrt` + SRT CSS/JS and the `mode === 'srt'` branch.

Add:

- `CONTAINERS.srt` group: `open-live-srt-gateway`, `open-live-srt-control`.
- SRT Gateway card: container status, Start/Stop/Restart buttons running
  `docker compose` in `SRT_GATEWAY_DIR` (env, default `../open-live-srt-gateway`),
  and an "Open SRT Gateway" link to `http://<dashboard-host>:8090`.

## Migration / cleanup

- Delete `open_live_srt/` from the workspace; its compose and config move to the
  new repo. Current `srt-config.json` becomes `srt-config.default.json`.
- Drop the `open_live_srt/*` entries from `.gitignore`.
- Update `README.md`: Option C now clones the new repo and uses the dashboard
  link; folder tree and Files section updated.
- Workspace retains no SRT flow/Strom logic.

## Verification

- New repo: `docker compose config` validates; a small Node test covers config
  normalization and `buildSrtFlow` for sender/receiver/efp/mpegts (no hardware).
- Workspace: `node --check server.mjs`; dashboard starts; `/api/srt/status`
  reports container states; Start/Stop correctly invoke compose.
- End-to-end SDI → SRT (caller → Haivision relay) requires DeckLink hardware and
  is a manual check.

## Non-goals / risks

- No change to the SRT flow semantics or relay behavior.
- Do not use upstream `strom:latest`.
- Port 8090 must be free on hosts where the gateway runs.
- DeckLink cards remain exclusively owned by the gateway container.
