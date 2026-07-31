# synchealth

Apple Health data into a queryable sqlite file, automatically, on your own
machine. No account, no cloud, no dependencies outside the Python standard
library.

```
health
```

```
Health  21 metrics · newest 2026-07-30
  1 out of range · 3 off goal

  Blood oxygen (SpO2)      93.4 %     ↓ -4%   low            ref 95-100 · goal ≥95
  Daily steps             5,493 count  → +1%   below goal 8000  ref 0-100000 · goal ≥8000
  Resting HR                 58 count  ↓ -6%   at goal        ref 40-100 · goal ≤60
  ...
```

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
git clone https://github.com/<you>/synchealth
cd synchealth
./install.sh
```

Installs `synchealth-import`, `synchealth-watch`, `synchealth-server` and
`health` into `~/.local/bin`, and seeds `~/.synchealth/health-targets.json`.

## Getting data in

Two paths. **Start with the export** — it is the complete history and it works
today. Add the push receiver later if you want same-day numbers.

### Path 1: manual export, automatic everything after

```
you:  Health app -> profile picture -> Export All Health Data
      save export.zip to ~/Downloads or iCloud Drive/HealthExports
        ▼ within 15 minutes
synchealth-watch (launchd, every 900s)
      ├─ unzip export.xml
      ├─ synchealth-import  ->  health.db     (aggregated per day)
      ├─ archive/export-<ts>.xml.gz           (raw, ~25:1)
      └─ delete the zip
        ▼
health
```

Set it up:

```bash
sed "s|__HOME__|$HOME|g" launchd/com.synchealth.watch.plist \
  > ~/Library/LaunchAgents/com.synchealth.watch.plist
launchctl load ~/Library/LaunchAgents/com.synchealth.watch.plist
```

Or skip launchd and run `synchealth-watch` by hand after each export. Either
way, imports are idempotent: re-importing the same export, or an older one, is
safe.

**The export itself cannot be automated.** Apple exposes no API and no Shortcuts
action for it — "Export All Health Data" is four manual taps, by design. Every
project in this space that claims a fully automatic Apple Health pipeline is
either running a paid third-party app on the phone (path 2) or is quietly
manual here too. Plan on re-exporting every few weeks; nothing breaks if you
forget, you just stop gaining new days.

### Path 2: push receiver, for same-day data

`synchealth-server` accepts the JSON format that
[Health Auto Export](https://healthexportapp.com/) emits — the de-facto standard
in this space, which FreeReps and the common Shortcuts recipes also speak. HAE
is a paid app; it is the only shipping way to get HealthKit data off the phone on
a schedule.

```
phone -> POST https://<your-host>/health   (X-Health-Token)
           ▼   tunnel or VPN
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
synchealth-server            # needs health.db to exist: run path 1 first
```

Then in HAE: add a REST API automation, URL `https://<your-host>/health`,
header `X-Health-Token: <your token>`, format JSON. No code changes.

**The token is not optional.** The server refuses to start without one, because
the moment you expose this endpoint it accepts blood oxygen and heart rate from
anyone who finds it.

Reaching the machine from anywhere needs a tunnel — the phone leaves your
network and a LAN address stops resolving. [Cloudflare
Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
works well here: the machine dials outbound, so no inbound port is opened, and
it does not consume the phone's single VPN slot the way Tailscale or WireGuard
does. iOS also tears down packet tunnels in the background, which makes a
VPN-only setup unreliable for scheduled pushes.

Both paths write the same tables, dedupe against each other, and can run
together. The export is authoritative: when a push covered a day only partially,
re-import and it is repaired.

## Reading it

```bash
health              # every metric: value, ref, goal, trend; problems first
health goals        # only metrics with a personal goal
health StepCount    # one metric: 30/90/365d stats + recent days
health resting      # fuzzy match works (-> RestingHeartRate)
health coverage     # which body systems have data in which year
health brief        # plain text, for an LLM to read
```

`ref` and `goal` are separate fields in `health-targets.json` on purpose. `ref`
is a clinical range with a citation; `goal` is a value judgement no data can
derive. A value can sit inside `ref` and still miss `goal`. Edit goals freely —
changing a `ref` means you disagree with the source quoted in its `why`.

The defaults are seeded from published adult guidance and are not medical
advice. Read the `why` on anything you plan to act on; a few (body fat, VO2 max)
are sex-specific and default to the male band.

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

Everything is local. Nothing phones home, and there is no telemetry.

`private_events` is a separate table for HealthKit types you would not want
appearing in a digest you might show someone — `SexualActivity` by default.
Rows there are queryable if you ask for them by name and are excluded from
`daily`, from `/health/summary`, and from everything `health` prints. Add types
to `PRIVATE_TYPES` in both `synchealth-import` and `synchealth-server` to extend
it (reproductive health, mental-state logging, medication are the obvious
candidates).

`health.db` is your complete medical record in a 5MB file. Do not sync it
anywhere you would not sync a medical record — that includes a git repo, however
private.

## Layout

```
bin/synchealth-import    export.xml -> health.db  (history, repair; idempotent)
bin/synchealth-watch     watch dirs -> import -> archive  (launchd, 15 min)
bin/synchealth-server    HAE-format POST -> health.db     (same schema)
bin/health               the read surface
health-targets.json      ref ranges (cited) + goals (yours)
launchd/                 plist templates for both daemons
docs/health-db.md        schema and the four traps
docs/pipeline.md         operations, design rationale, rejected approaches
```

## License

MIT
