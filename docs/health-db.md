# health.db — how to read it, and what will bite you

`~/.synchealth/health.db`. Apple Health data aggregated per day into a
queryable shape. Small enough to hand to an LLM turn directly, which is why the
schema aggregates instead of storing raw samples.

Build it: `synchealth-import <export.xml>` (idempotent; re-running overwrites the
same day/metric rows).

Scale, from an 11-year reference export: ~1.1M raw records collapsed to ~24k
rows across ~3,600 days — about 4MB, 7 seconds.

## Tables

| Table | Grain | Notes |
|---|---|---|
| `daily` | (day, metric) | The main table. Holds sum/avg/min/max/last/n per metric; `stat` says which is canonical and `value` is that one |
| `sleep` | (night, state, kind) | Sleep intervals folded per night; `kind` separates naps from nights |
| `sleep_nights` | night | **View.** One comparable duration per night across both vocabularies — prefer this |
| `sleep_naps` | day | **View.** Naps as their own series |
| `rings` | day | Apple's own daily Move/Exercise/Stand totals |
| `workouts` | start | Workout records |
| `sources` | (metric, source) | Per-device record counts, for auditing |
| `samples` | (day, metric, at, value) | Written by the push path only; the deduped point set `daily` is recomputed from |
| `sleep_segments` | id | Push path only; deduped sleep segments by HK sample id |
| `private_events` | id | Types deliberately excluded from every summary (see below) |
| `imports` | — | One row per import: when, which file, how many records |

## The four traps

Each of these was found by measurement, not by reading docs. All four will give
you a confidently wrong answer if you skip them.

### 1. Aggregation is per-metric — do not SUM everything

`daily.value` is already the right reading: steps, distance and energy sum over
the day; heart rate, HRV and SpO2 average; weight and height take the last
sample. `SELECT value` is correct for every metric.

```sql
-- right: the canonical value
SELECT day, value FROM daily WHERE metric='StepCount' ORDER BY day DESC LIMIT 7;
-- wrong: summing heart rate gives thousands of bpm
SELECT sum FROM daily WHERE metric='HeartRate';
```

`stat` tells you which aggregate `value` came from. The other columns are there
when you want a different reading, not because you should pick one at random.

### 2. Historical energy: trust `rings`, not `daily`

Apple's export drops individual Records for older days but keeps its own daily
ring summaries. So `rings` is the *more* complete source going backwards in time.

Measured across 352 days with a ring above 50 kcal: only 107 agreed with the
aggregate within 5%, mean divergence 42.8%. Worst day: ring said 794 kcal,
detail records totalled 189 kcal across 325 samples that stopped dead at 14:00
with the rest of the day empty.

Use `rings` for historical daily energy / exercise / stand. Use `daily` for
recent days and for anything rings does not carry.

### 3. Sleep has two vocabularies and they do not mix

Third-party apps and pre-watchOS-9 records write only `InBed`. Newer Apple Watch
records write `AsleepCore` / `AsleepDeep` / `AsleepREM` / `Awake`. Summing only
`Asleep*` reports 0 hours for every year covered by the older vocabulary.

```sql
SELECT night, hours, basis, suspect FROM sleep_nights ORDER BY night DESC;
```

`sleep_nights` handles this with a precedence ladder — staged, then
unspecified, then in-bed — and `basis` reports which one produced the number.

Three things to know about it:

- `basis='inbed'` runs high. Time in bed includes lying awake.
- Adding `AsleepUnspecified` to the staged rows double-counts. It is the same
  sleep, less finely broken down — one measured night read as 9.33h instead of
  7.2h that way. The view picks one, never both.
- `suspect=1` marks physically impossible nights. Third-party apps have been
  observed writing single sleep records over 24 hours long.

Naps are excluded from `sleep_nights` entirely. A watch catches afternoon naps
far more reliably than actual nights, so mixing them reports a 2h nap as that
night's total — which reads as a severe deficit when the real fact is that the
night went unrecorded. Query `sleep` with `kind='nap'`, or use `sleep_naps`.

### 4. Percent values are stored as 0-1 fractions

Apple writes `unit='%'` metrics as decimals: blood oxygen 0.91 means 91%, body
fat 0.171 means 17.1%. Faithful to HealthKit, fatal to any reader that takes the
number at face value — "SpO2 0.98%" reads as a medical emergency.

The importer scales these by 100 at write time, so the db holds 93-98 for SpO2.
**If you rewrite the importer, keep that step.** The affected set is in
`PERCENT_METRICS`.

The push path has the mirror problem: HAE already reports real percent, so
scaling again would give 9800%. It only scales values below
`PERCENT_FRACTION_CEILING` (1.5), where a fraction is unambiguous.

## Device names are not normalised

One phone routinely appears under several `sourceName` values, because renaming
a device does not rewrite the samples it already wrote. Dedupe is by
(metric, start, end, value), so a sample synced under two names collapses to one
row — but `sources` keeps the original names for auditing.

Expect heart rate and HRV to come only from the watch, and steps to come from
everything.

## The newest day is always partial

An export captures the instant the button was pressed. The newest day therefore
holds a fraction of its steps. The `health` CLI drops it for cumulative metrics;
if you query sqlite directly, do the same or you will read a normal day as a
collapse.

## private_events

`PRIVATE_TYPES` in both `synchealth-import` and `synchealth-server` lists
HealthKit types that never enter `daily` and land in `private_events` instead.
Default is `SexualActivity`.

The reason is structural: `daily` is the shared read surface, and anything that
enumerates it — `/health/summary`, any digest you write later — will include
whatever it finds. Keeping these rows in a separate table means they stay
queryable when you ask for them by name and cannot leak into a summary you show
someone.

If you extend the set, edit both files. They keep separate copies on purpose:
each must run standalone.

## Useful queries

```sql
-- last 30 days of steps alongside resting heart rate
SELECT s.day, s.value steps, r.value rhr
FROM daily s LEFT JOIN daily r ON r.day=s.day AND r.metric='RestingHeartRate'
WHERE s.metric='StepCount' AND s.day >= date('now','-30 days') ORDER BY s.day DESC;

-- what is actually in here
SELECT metric, count(*) days, min(day), max(day) FROM daily
GROUP BY metric ORDER BY days DESC;

-- one month of sleep
SELECT night, hours, basis FROM sleep_nights WHERE night LIKE '2026-06%' ORDER BY night;

-- which devices contributed a metric
SELECT source, n FROM sources WHERE metric='StepCount' ORDER BY n DESC;
```
