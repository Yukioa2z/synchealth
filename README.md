# synchealth

Apple Health data into a queryable sqlite file, automatically, on your own
machine. No account, no cloud, no dependencies outside the Python standard
library.

```
health
```

```
Health  21 metrics · newest 2026-01-15
  0 outside configured range

  Blood oxygen (SpO2)      97.2 %     → +1%   normal         ref 95-100
  Daily steps             7,120 count  ↑ +8%
  Resting HR                 62 count  → +1%   normal         ref 40-100
  ...
```

The output above is illustrative only. This repository contains no personal
health records or live metrics.

## Why this exists

HealthKit holds years of your own measurements and gives you almost no way to
look at them. The Health app shows one metric at a time with no reference range
and no trend, and every third-party alternative wants the data on their servers.

The data itself is fine. The missing pieces are a schema that survives Apple's
export quirks, an aggregation contract that does not turn heart rate into
thousands, and a reader that says whether a number is normal. That is what this
is.

## Install

Requires Python 3.9+ (macOS ships it at `/usr/bin/python3`) and nothing else.

```bash
git clone https://github.com/Yukioa2z/synchealth
cd synchealth
./install.sh
```

Installs `synchealth-import`, `synchealth-watch`, `synchealth-server` and
`health` into `~/.local/bin`, and seeds `~/.synchealth/health-targets.json`.

## First setup: iPhone Full Sync

The included iOS app is the normal first import. It reads your HealthKit
history and uploads it to a receiver on **your own Mac**; the receiver creates
`~/.synchealth/health.db` on first start, so you do not need to export Health
data by hand.

```
iPhone HealthKit -> SyncHealth iOS app -> HTTPS POST /health
                                      -> ~/.synchealth/health.db
```

1. Install the command-line receiver with `./install.sh`.
2. Create `~/.synchealth/server.json` with a random token, bind address and
   port, then start `synchealth-server` (or install its LaunchAgent template).
3. If the phone must sync outside your home network, make only `/health`
   reachable through an HTTPS tunnel (recommended). A VPN is an alternative
   only when both the iPhone and Mac remain connected to it.
4. Follow [the iOS build instructions](ios/README.md), enter that HTTPS URL
   and token in the app, and run **Full Sync** once.

The app then sends rolling incremental updates. iOS background scheduling is
best effort; queued batches survive network failures and retry later.

### Optional: manual Health export for recovery

A manual export is not part of normal setup. Use it to repair a suspected gap
or independently compare the phone's complete history. The watcher imports an
export from `~/Downloads` or iCloud Drive:

```bash
sed "s|__HOME__|$HOME|g" launchd/com.synchealth.watch.plist \
  > ~/Library/LaunchAgents/com.synchealth.watch.plist
launchctl load ~/Library/LaunchAgents/com.synchealth.watch.plist
```

Or run `synchealth-watch` manually after exporting. Imports are idempotent and
the completed export takes authority for finished days.

### Receiver configuration

`synchealth-server` accepts the JSON format that
[Health Auto Export](https://healthexportapp.com/) emits. The repository also
includes a buildable iOS client under `ios/`, adapted from the MIT-licensed
[FreeReps](https://github.com/meltforce/FreeReps) project. It adds a runtime
`X-Health-Token`, durable on-device upload queue, rolling-window sync and
background retry, while keeping the token in Keychain.

```
phone -> POST https://<your-host>/health   (X-Health-Token)
           ▼   HTTPS tunnel (recommended) or persistent VPN
         synchealth-server on 127.0.0.1:8738
           ├─ raw/<ts>.json      verbatim payload, written before folding
           └─ health.db          same schema as the importer
```

```bash
mkdir -p ~/.synchealth
cat > ~/.synchealth/server.json <<'EOF'
{"token": "REPLACE-WITH-32-RANDOM-CHARS", "bind": "127.0.0.1", "port": 8738}
EOF
chmod 600 ~/.synchealth/server.json
synchealth-server
```

Build the app in Xcode, choose a unique Bundle ID and signing team, then enter
the endpoint and token in its Settings screen. See [ios/README.md](ios/README.md)
for the exact steps. If you already use HAE, it remains compatible: add a REST
API automation with the same URL and header.

**The token is not optional.** The server refuses to start without one, because
the moment you expose this endpoint it accepts blood oxygen and heart rate from
anyone who finds it.

Reaching the machine from anywhere needs a reachable route — the phone leaves
your network and a LAN address stops resolving. An HTTPS tunnel is the
recommended route. [Cloudflare
Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
works well here: the machine dials outbound, so no inbound port is opened, and
it does not consume the phone's single VPN slot the way Tailscale or WireGuard
does. A VPN is a generic alternative for people who already operate one, not a
requirement of this project; iOS can tear down packet tunnels in the background,
which makes a VPN-only setup unreliable for scheduled pushes.

Both paths write the same tables and can run together. A later complete export
is authoritative for finished days, so it repairs a partial phone upload.

## Where your data lives

All health data stays under `~/.synchealth/` on the Mac that runs the receiver:

| Path | Contents |
|---|---|
| `health.db` | Queryable, daily health database and private tables |
| `raw/` | Original encrypted-upload payloads, retained before aggregation |
| `archive/` | Compressed manual exports, only when you use recovery import |
| `server.json` | Receiver token and bind/port settings; mode 600 |
| `*.log` | Receiver and recovery-import diagnostics |

These are medical records, not repository files. The project `.gitignore`
blocks them, but do not put this directory in ordinary cloud sync either.

## Reading it

```bash
health              # every metric: value, ref, goal, trend; problems first
health goals        # only metrics with a personal goal
health StepCount    # one metric: 30/90/365d stats + recent days
health resting      # fuzzy match works (-> RestingHeartRate)
health coverage     # which body systems have data in which year
health brief        # plain text, for an LLM to read
```

`ref` and `goal` are separate fields in `health-targets.json` on purpose. A
`ref` is included only where the linked source supports a broadly applicable
adult resting range. A `goal` is a personal choice no data can derive.

The public template ships with **no goals** and no sex-specific defaults. Add
`goal_min` or `goal_max` only after considering age, sex, pregnancy, disability,
altitude, medication, diagnosis, device accuracy and your own priorities. This
context is not diagnosis or medical advice.

## Going deeper

It is plain sqlite. Read-only queries are safe while the server is running:

```bash
sqlite3 ~/.synchealth/health.db \
  "SELECT day, value FROM daily WHERE metric='RestingHeartRate'
     AND day >= date('now','-90 days') ORDER BY day"
```

Read [docs/health-db.md](docs/health-db.md) first. Apple's export has four
traps that will silently give you wrong answers — percent values stored as 0-1
fractions, two incompatible sleep vocabularies, ring totals disagreeing with
detail records by 40%, and per-metric aggregation (summing heart rate gives
thousands). Each one is measured, not hypothetical.

[docs/pipeline.md](docs/pipeline.md) covers operations: what to check when data
looks stale, why the design is shaped this way, and what was tried and rejected.

## Privacy

There is no SyncHealth cloud service, account or telemetry. The iOS app sends
health data only to the endpoint you configure. If that endpoint uses a
third-party tunnel, encrypted traffic necessarily passes through that
provider's infrastructure; choose and configure the transport accordingly.

`private_events` is a separate table for sensitive category types you would not
want appearing in a digest: sexual activity, reproductive health, pregnancy
and state-of-mind records are included in the default private set. These rows
are queryable explicitly and excluded from `daily`, `/health/summary`, and
everything `health` prints.

Rich objects that do not have a lossless relational mapping — ECGs, audiograms,
medications, vision prescriptions, workout details and unmodelled category
samples — land as JSON in `generic_events`. They are retained and queryable,
but never enter automatic summaries.

`health.db` is your complete medical record in one easy-to-copy file. Do not
sync it anywhere you would not sync a medical record — that includes a git repo,
however private. See [SECURITY.md](SECURITY.md) before exposing the receiver.

## Layout

```
bin/synchealth-import    export.xml -> health.db  (history, repair; idempotent)
bin/synchealth-watch     watch dirs -> import -> archive  (launchd, 15 min)
bin/synchealth-server    HAE-format POST -> health.db     (same schema)
bin/health               the read surface
health-targets.json      sourced context + goals (unset until you add them)
ios/                     Xcode project for the on-device HealthKit sync app
launchd/                 plist templates for both daemons
docs/health-db.md        schema and the four traps
docs/pipeline.md         operations, design rationale, rejected approaches
```

## License and upstream

The server, importer and CLI are MIT licensed. The iOS app is an adaptation of
FreeReps and retains its upstream MIT notice in `ios/LICENSE`; see
`ios/UPSTREAM.md` and `THIRD_PARTY_NOTICES.md` for provenance.
