# SyncHealth for iOS

This Xcode app reads HealthKit and pushes HAE-compatible JSON batches to a
SyncHealth receiver. It is based on
[FreeReps](https://github.com/meltforce/FreeReps) at
`bb929f1a079f0c11de21a604596ebc14185f34bd`, with the durable queue,
application-level token, rolling-window sync, and background-retry work from
the SyncHealth fork.

The app never contains a server token in source or build settings. You enter
the token at runtime; it is stored in the iOS Keychain with
`AfterFirstUnlockThisDeviceOnly` protection. Every encoded batch is written to
protected Application Support storage before its first network request and is
deleted only after a decodable HTTP 200 acknowledgement.

## Build on a physical iPhone

You need Xcode, iOS 17.6 or newer, and an Apple account. HealthKit does not work
meaningfully in the simulator, though the transport and queue tests do.

1. Open `FreeReps.xcodeproj`.
2. Select the `FreeReps` target and choose your Team under Signing & Capabilities.
3. Replace every `com.example.synchealth` occurrence with a bundle identifier
   unique to your Apple account. Keep the `.sync` task identifier and `.tests`
   test identifier consistent.
4. Select your iPhone and press Run.
5. In the app, set the complete HTTPS endpoint, such as
   `https://health.example.net/health`, and enter the same `X-Health-Token`
   configured on `synchealth-server`.
6. Grant the Health permissions you want, then run Full Sync once to establish
   the baseline.

The checked-in default is the reserved, non-deliverable
`https://your-host.example/health`, so a fresh build cannot accidentally send
health data anywhere.

A free Personal Team provisioning profile normally expires after seven days.
This repository includes an optional daily renewal job so a paired, reachable
iPhone is rebuilt and reinstalled before that limit. After the first successful
physical-device build, get the CoreDevice identifier with
`xcrun devicectl list devices`; use the matching Xcode destination identifier
shown in Xcode's device selector, then install it:

```sh
ios/scripts/install-renewal-job.sh \
  --xcode-device <xcode-device-id> \
  --core-device <core-device-id> \
  --bundle-id <your-unique-bundle-id>
```

It runs daily at 09:00 and only reinstalls when the last successful renewal is
older than five days. The Mac must be awake and the iPhone must be connected by
cable or reachable on the same network. If that is not true, the app can still
expire; reconnect it and run the copied renewal script with `--force`.

## Test

From the repository root:

```sh
xcodebuild test \
  -project ios/FreeReps.xcodeproj \
  -scheme FreeReps \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

The focused tests use a stubbed `URLProtocol`; they make no network requests.
Real HealthKit access, locked-device recovery, and background scheduling still
require a physical phone.

## Delivery contract

```text
HealthKit -> HAE-compatible JSON -> protected oldest-first queue
          -> POST /health with X-Health-Token
          <- HTTP 200 {"points": <integer>, ...}
```

- Only an absolute HTTPS endpoint is accepted.
- Incremental sync re-reads a seven-day rolling overlap by default.
- `HKObserverQuery`, HealthKit background delivery, and a
  `BGProcessingTaskRequest` provide best-effort wakeups.
- Network errors, non-200 responses, and malformed acknowledgements retain the
  batch for retry.
- HealthKit may be unreadable while the phone is locked or before first unlock
  after reboot; queued work is retried after unlock or on the next opportunity.
- HealthKit deletions and exactly-once delivery are not implemented. The
  receiver deduplicates overlapping samples.

The receiver folds daily metrics, sleep, stand hours, workouts, and rings into
typed tables. ECG, audiogram, medication, vision, state-of-mind, other category
samples, workout routes, and other rich fields are retained in the private
`generic_events` table as JSON. None of those generic rows enter automatic
summaries.

## Privacy

Do not commit a real endpoint if its hostname is private, a signing team ID, an
export, queue files, provisioning profiles, or tokens. A queue file contains
health data but not the token. The token remains in Keychain and is never shown
again after saving.

## Attribution

The iOS client retains FreeReps' MIT licence and its HealthBeat ancestry. See
[`LICENSE`](LICENSE), [`HEALTHBEAT-LICENSE.md`](HEALTHBEAT-LICENSE.md), and
[`UPSTREAM.md`](UPSTREAM.md).
