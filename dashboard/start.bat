@echo off
REM SPDX-FileCopyrightText: 2026 Contributors to the EBU Open Live Production Cloud project
REM SPDX-License-Identifier: Apache-2.0

set PORT=3100
cd /d "%~dp0"
start "" http://localhost:%PORT%
node server.mjs
pause
