# Upstream record

- Upstream: `https://github.com/meltforce/FreeReps.git`
- FreeReps baseline: `bb929f1a079f0c11de21a604596ebc14185f34bd`
- FreeReps iOS ancestry: `https://github.com/kempu/HealthBeat`
- SyncHealth adaptation snapshot: `316caf7b13fbca9a596fb2edfe68571006c3069d`
- Snapshot imported: 2026-07-31

The imported app preserves FreeReps' HealthKit registry, HAE-compatible payload
types, paged historical reads, observer queries, and background scheduling.
SyncHealth adds an editable HTTPS endpoint, an `X-Health-Token` stored in
Keychain, a protected durable upload queue, rolling-window delivery, resumable
baseline sync, locked-device retry, and tests for the transport and queue.

The Verifiable Health Records entitlement present in some HealthKit projects is
not included because it is unavailable to free Personal Teams. Ordinary
HealthKit read access and background delivery remain enabled.

This is not an anchored deletion protocol: delivery uses date-predicate reads,
not `HKAnchoredObjectQuery` plus `HKDeletedObject`. Overlapping reads are
deduplicated by the receiver; HealthKit deletions are not propagated.

The FreeReps and HealthBeat MIT notices are retained in `LICENSE` and
`HEALTHBEAT-LICENSE.md` respectively.
