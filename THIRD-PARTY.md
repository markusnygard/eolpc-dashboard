<!--
SPDX-FileCopyrightText: 2026 Contributors to the EBU Open Live Production Cloud project
SPDX-License-Identifier: CC-BY-4.0
-->

# Third-party components

Everything EOLPC Dashboard uses or starts that it did not write, with version, licence and source (CONTRIBUTING section 6). None of it is copied into this repository: the dashboard calls the Docker and git command-line tools, and the components below are separate repositories or container images.

The project's own code is Apache-2.0 (`LICENSE`), its documentation CC-BY-4.0 (`LICENSES/CC-BY-4.0.txt`). Attributions are in `NOTICE`.

Checked 2026-11-13 (licences compared with each upstream LICENSE file). Update this file when a component is added, removed or upgraded.

## 1. What the dashboard itself runs on

| Component | Version | Licence | Source | Use |
|---|---|---|---|---|
| Node.js | 23 or later | MIT, plus the licences of its bundled components | https://nodejs.org | Runs `dashboard/server.mjs`. No npm dependencies. |
| Docker Engine and Docker Compose (CLI) | host version | Apache-2.0 | https://www.docker.com | Starts, stops and inspects the containers |
| Git (CLI) | host version | **GPL-2.0** | https://git-scm.com | Reads version tags of the checked-out sources. Run as a separate program. **Copyleft: listed for the Founding Board.** |
| Python 3 | host version | PSF-2.0 | https://www.python.org | Runs `scripts/srt-health-check.py` and `scripts/srt-recorder.py` |

## 2. Components the dashboard starts (in `~/eolpc`, not part of this repository)

| Component | Version | Licence | Source | Use |
|---|---|---|---|---|
| Eyevinn open-live | v0.8.0 | MIT | https://github.com/Eyevinn/open-live | Production backend (image built locally from the release tag) |
| Eyevinn open-live-studio | v0.8.0 | MIT | https://github.com/Eyevinn/open-live-studio | Studio web UI (image built locally from the release tag) |
| Eyevinn Strom (`eyevinntechnology/strom-full`) | 0.8.1 | MIT OR Apache-2.0 (dual; Apache-2.0 chosen). The image also contains GStreamer (LGPL-2.1+, some plugins GPL) and Ubuntu packages. | https://github.com/Eyevinn/strom | Media engine. **GStreamer copyleft parts: needs Founding Board approval.** |
| Apache CouchDB (`couchdb`) | 3.5.2 | Apache-2.0 | https://couchdb.apache.org | Open Live's database |
| `node:lts-slim` image | LTS | Node.js: MIT; Debian packages: mixed, including GPL/LGPL (unmodified OS packages) | https://hub.docker.com/_/node | Runs the small STUN server of the local stack |
| EOLPC SRT Gateway | `main` | Apache-2.0 | https://github.com/markusnygard/eolpc-srt-gateway | SDI capture to SRT; its own components are listed in its THIRD-PARTY.md |
| EOLPC Modular Studio | `main` | **none yet** (no LICENSE file; add Apache-2.0 before it joins EOLPC) | https://github.com/markusnygard/eolpc-modular-studio | Optional studio UI on port 3200 |

## 3. Desktop integration (not shipped)

| Component | Licence | Use |
|---|---|---|
| Google Chrome / Chromium / Brave / Firefox (whichever is installed) | Chrome: **proprietary**; Chromium: BSD-3-Clause; Brave and Firefox: MPL-2.0 | `dashboard/start.sh` opens the dashboard in the first browser it finds. Not a dependency; nothing is bundled. |

## 4. Codecs and patents (CONTRIBUTING section 7)

The dashboard has no media code. The components it starts encode and decode H.264, HEVC and AAC (patent-licensed) and Opus and VP8 (royalty-free) through Strom and GStreamer. Raised for the Founding Board; whoever deploys the stack is responsible for codec licensing where it applies.
