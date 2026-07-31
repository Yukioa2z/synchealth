# Pipeline: operations and design

The iOS Full Sync is the normal first import and daily path. A manual export is
an optional recovery path. Both write one schema and one reader.

```
iOS HealthKit ── SyncHealth Full Sync ── POST /health ── synchealth-server ── health.db
                                                                    │
optional export.xml ── synchealth-watch ── synchealth-import ──────┘
```

## Daily operation

Nothing, most days. The installed iOS app sends incremental updates whenever
iOS grants it background time. It retains failed batches for retry and reads a
rolling overlap to heal short gaps.

## Optional export recovery

If you suspect a gap or want an independent completeness check:

1. iPhone: **Health app → profile picture → Export All Health Data** (takes a
   few minutes for a large record)
2. Save to iCloud Drive `HealthExports/`, or AirDrop to the Mac's `~/Downloads`
3. Wait — `synchealth-watch` picks it up within 15 minutes
4. `health`

Imports are idempotent. Re-importing the same file, or an older export, is safe.
If an import fails the zip stays put and the next run retries it.

An export repairs finished days because it is treated as the complete source for
those dates. It is not required for ordinary operation.

```bash
# is the watcher seeing anything?
tail ~/.synchealth/watch.log

# import by hand (idempotent, safe any time)
synchealth-import ~/Downloads/apple_health_export/export.xml

# push side, if configured
curl -s http://127.0.0.1:8738/health/alive
tail ~/.synchealth/server.log
```

## Why the optional export is manual

Apple provides no API and no automation hook for HealthKit export. This is not
an oversight you can work around — it is the same decision that keeps HealthKit
data out of iCloud backups by default.

Consequence: a fully automatic Apple Health pipeline does not exist without an
on-device app holding a HealthKit entitlement. Anything claiming otherwise is
either running such an app or is manual and not saying so.

The iOS app is the on-device HealthKit client that makes automatic upload
possible. Exports remain useful only as a recovery and comparison tool.

## Why the push path is primary

`synchealth-server` accepts the format Health Auto Export and FreeReps-family
clients emit. This repository includes an Xcode project under `ios/`, adapted
from FreeReps, with a configurable endpoint, Keychain-backed token, durable
queue, rolling-window sync and background retry. HAE remains a compatible paid
alternative.

The receiver initializes an empty database on first start, so the first Full
Sync establishes the complete local history without a manual export.

## Why re-sends had to be designed for

Every emitter in this space re-sends. HAE automations post rolling windows,
FreeReps re-syncs whenever an observer query wakes it, and the point of a rolling
window is that a missed day heals itself.

So accumulating into a stored aggregate is wrong: posting the same body twice
doubles the day. Measured, before the fix: a step count went from 2,654 to 4,654
after one re-push.

The fix is to store each `(day, metric, timestamp, value)` in `samples` and
recompute the day's aggregate from the deduped set. Re-posting is then a no-op,
while a later push covering new hours still extends the day. Sleep segments do
the same thing keyed on the HealthKit sample id. Cost is a few hundred rows per
day.

Corollary: a complete export owns every finished `(day, metric)` it contains.
The importer deletes stale push samples for those rows and records the decision
in `export_authority`; the server then ignores future rolling-window points for
locked rows. The export's newest day remains unlocked because it was captured
mid-day. Ring summaries use the reserved `__rings__` metric in the same table.
Sleep applies the same contract per finished night in
`export_sleep_authority`.

Do not try to pick a winner by comparing row counts — the two sources cut a day
into different numbers of buckets, so "more rows" says nothing about
completeness.

## The payload is more than one array

The compatible payload carries reportable and rich HealthKit data in several
places, and it is easy to consume only the first:

- `data.metrics` — the numeric series
- `data.workouts` — workout records
- `data.category_samples` — **where sleep actually arrives**, plus stand hours
- `data.activity_summaries` — the Move/Exercise/Stand rings
- `data.ecg_recordings`, `audiograms`, `medications`, `vision_prescriptions`
  and `state_of_mind` — rich objects with no one-number daily representation

Consuming only `metrics` and `workouts` looks fine and is not. `SleepAnalysis`
only appears under `metrics` when the user enables HAE's aggregated "Sleep"
metric; the per-stage segments always ride in `category_samples`. Miss that array
and `sleep` silently stops advancing while every push carries the segments —
5,179 payloads went by that way in the original deployment before anyone noticed,
because nothing errored. `activity_summaries` fails the same silent way: `rings`
just freezes at the last export.

If you write your own monitoring, check per-table freshness rather than a single
max-of-everything timestamp. One live table hides an entire dead array.

Numeric metrics, sleep, workouts and rings have relational tables. Rich objects,
full workout details, full activity summaries and otherwise-unmodelled category
samples are deduped into `generic_events` as JSON so an accepted phone upload is
not acknowledged and then silently discarded.

## Exposing the endpoint

The receiver binds `127.0.0.1` by default and requires a token of at least 16
characters or it will not start. The endpoint accepts blood oxygen and heart
rate; anyone who can reach it can write to your medical record.

To reach it from the phone you need something that works away from home, which
rules out a LAN address.

**Cloudflare Tunnel** is the recommended shape: the machine dials outbound, so no
inbound port is opened and no router configuration is needed. The cost is that
the endpoint is on the public internet, which is exactly why the token is
mandatory rather than optional.

**A VPN (Tailscale, WireGuard) is worse here**, for two reasons that are specific
to iOS rather than to any product: it consumes the phone's single packet-tunnel
slot, so it is mutually exclusive with any other VPN, and iOS tears down packet
tunnels in the background. Scheduled pushes are exactly the case that background
teardown breaks.

## Why the included app is a FreeReps fork

[FreeReps](https://github.com/meltforce/FreeReps) supplied the open-source
HealthKit reader and payload model. Upstream identifies clients through
Tailscale, while this deployment shape uses a public HTTPS tunnel. The included
fork therefore adds a runtime `X-Health-Token`, stores it in Keychain, and never
persists it in upload queue files. It also keeps failed payloads in an
on-device queue for retry.

Those are deployment differences, not a claim that upstream is insecure.
`ios/UPSTREAM.md` pins the imported baseline and `ios/LICENSE` preserves its MIT
notice. Use a unique Bundle ID when you build; changing the ID of an already
installed fork changes its Keychain/app identity.

## Rejected: assembling it from Shortcuts

`Find All Health Samples` handles one type per action. HealthKit has dozens of
types, so this means hand-placing dozens of actions and hand-assembling the JSON.
Worse, the set of types Shortcuts can read is smaller than HealthKit's — sleep
staging in particular comes back incomplete.

The four manual taps are less work and produce more data.

## Storing the raw payload first

Every accepted push is written verbatim to a nanosecond-and-UUID filename under
`raw/` *before* folding, and every processed export is archived with the same
collision-resistant naming strategy (about 25:1 compression).

Same reason in both cases: aggregation logic can be wrong, and a re-fold from
raw data costs nothing. An unrecorded push is gone, and Apple will not reissue an
old export. Disk is the cheapest part of this system.

If folding throws, the server returns 500 with the raw filename and keeps the
file. The log line says which payload failed.

## Secrets and what not to sync

| What | Where | Note |
|---|---|---|
| push token | `~/.synchealth/server.json`, mode 600 | never in a repo |
| tunnel credentials | wherever your tunnel daemon keeps them, mode 600 | never in a repo |

`health.db` is a complete medical record in a few MB — heart rate, blood oxygen,
and whatever else HealthKit holds. Keep it out of any sync set, backup repo or
mirror you would not use for medical records. Including a private git repo.
