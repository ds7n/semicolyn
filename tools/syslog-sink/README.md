<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# semicolyn diagnostics syslog sink

One-command TLS/TCP/UDP syslog receiver for the app's remote diagnostics stream
(Settings → Diagnostics → **Stream logs to a server**). Lands the verbose
gesture/selection/key/scroll/tmux trace in a logfile you can `tail -f`.

## Setup

1. Generate a self-signed cert (the app skips verification, so any cert works):

   ```sh
   mkdir -p cert logs
   openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
     -keyout cert/key.pem -out cert/cert.pem -subj "/CN=semicolyn-diag"
   ```

2. Start it:

   ```sh
   docker compose up
   ```

3. In the app: **Diagnostics → Stream logs to a server**, then set:
   - **Host** = this machine's IP (reachable from the device)
   - **Transport** = TLS, **Port** = 6514

4. Watch the trace:

   ```sh
   tail -f logs/semicolyn.log
   ```

## Transports

- **TLS 6514** (recommended): encrypted, self-signed cert above.
- **TCP 514**: reliable plaintext, no cert needed (`Transport = TCP`).
- **UDP 514**: plaintext, lossy — fine for a quick check (`Transport = UDP`).

For a bare listener without this stack you can also just run
`ncat --ssl -l 6514` (TLS) or `nc -l 514` (plain TCP) to eyeball lines live.

`cert/` and `logs/` are gitignored — they hold your local cert + captured logs.
