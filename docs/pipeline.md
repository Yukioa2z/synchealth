# Pipeline: operations and design

Two ways in, one schema, one reader. This documents how to run it, why it is
shaped this way, and which alternatives were tried and dropped — the last part
matters most, because most of them look better than they are.

```
Apple Health  ──┬── export.xml ── synchealth-watch ── synchealth-import ──┐
                │       (manual export, automatic rest)                   │
                │                                                    health.db ── health
                └── HAE json ─── POST /health ─── synchealth-server ──────┘
                        (paid app, same-day, optional)
```

## Daily operation

Nothing, most days. Every few weeks:

1. iPhone: **Health app → profile picture → Export All Health Data** (takes a
   few minutes for a large record)
2. Save to iCloud Drive `HealthExports/`, or AirDrop to the Mac's `~/Downloads`
3. Wait — `synchealth-watch` picks it up within 15 minutes
4. `health`

Imports are idempotent. Re-importing the same file, or an older export, is safe.
If an import fails the zip stays put and the next run retries it.

The manual export is the only step that can stop this pipeline silently. Watch
for it: `health` prints how old the newest day is, and warns past 3 days.

```bash
# is the watcher seeing anything?
tail ~/.synchealth/watch.log

# import by hand (idempotent, safe any time)
synchealth-import ~/Downloads/apple_health_export/export.xml

# push side, if configured
curl -s http://127.0.0.1:8738/health/alive
tail ~/.synchealth/server.log
```

## Why the export is manual

Apple provides no API and no automation hook for HealthKit export. This is not
an oversight you can work around — it is the same decision that keeps HealthKit
data out of iCloud backups by default.

Consequence: a fully automatic Apple Health pipeline does not exist without an
on-device app holding a HealthKit entitlement. Anything claiming otherwise is
either running such an app or is manual and not saying so.

So this does not try. It automates everything downstream of the four taps, and
tells you when the taps are overdue.

## Why the push path exists anyway

`synchealth-server` accepts the format Health Auto Export emits, which has become
the de-facto standard: FreeReps and the common Shortcuts recipes speak it too.
HAE is a paid app with `HKObserverQuery`-driven automations, 85+ types, and a
REST target you fill in. Point it at this endpoint and it works with no code
change, because the schema was written against its payload shape.

Whether you need it depends on the question you ask your own data. Self-tracking
is mostly retrospective — how did I sleep last week, is my resting heart rate
drifting — and none of that needs today's data today. Quarterly exports answer
those questions completely. Same-day numbers matter only if you plan to act on
them the same day.

The receiver is worth keeping either way: it is a standing target for any future
data source, and the format is not going to change.

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

Corollary: the push owns days it has samples for; a re-import of `export.xml`
is the repair path when a push covered a day only partially. Do not try to pick
a winner by comparing row counts — the two sources cut a day into different
numbers of buckets, so "more rows" says nothing about completeness.

## Four arrays, not one

HAE payloads carry health data in four places, and it is easy to consume only
the first:

- `data.metrics` — the numeric series
- `data.workouts` — workout records
- `data.category_samples` — **where sleep actually arrives**, plus stand hours
- `data.activity_summaries` — the Move/Exercise/Stand rings

Consuming only `metrics` and `workouts` looks fine and is not. `SleepAnalysis`
only appears under `metrics` when the user enables HAE's aggregated "Sleep"
metric; the per-stage segments always ride in `category_samples`. Miss that array
and `sleep` silently stops advancing while every push carries the segments —
5,179 payloads went by that way in the original deployment before anyone noticed,
because nothing errored. `activity_summaries` fails the same silent way: `rings`
just freezes at the last export.

If you write your own monitoring, check per-table freshness rather than a single
max-of-everything timestamp. One live table hides an entire dead array.

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

## Rejected: FreeReps

[FreeReps](https://github.com/martinamps/freereps) is the obvious open-source
candidate for the phone side, and as of mid-2026 it does not fit a tunnel. Its
client sets only `Content-Type` on the POST and sends no token — identity comes
entirely from a Tailscale WhoIs lookup on the server. That is an architectural
assumption, not a config option: outside the tailnet there is no identity to look
up. Check the current source before taking this as still true.

So FreeReps + tunnel does not compose without forking the app to add a header.
FreeReps + Tailscale composes but inherits the iOS background-teardown problem
above.

## Rejected: assembling it from Shortcuts

`Find All Health Samples` handles one type per action. HealthKit has dozens of
types, so this means hand-placing dozens of actions and hand-assembling the JSON.
Worse, the set of types Shortcuts can read is smaller than HealthKit's — sleep
staging in particular comes back incomplete.

The four manual taps are less work and produce more data.

## Storing the raw payload first

Every accepted push is written verbatim to `raw/<ts>-<n>.json` *before* folding,
and every processed export is archived as `export-<ts>.xml.gz` (about 25:1).

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
