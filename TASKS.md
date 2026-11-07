# WatchMagic — Task checklist

Legend: [x] done & verified on the Mac · [ ] open · [~] code done, needs on-device verification (needs the watch on a wrist / signing)

## 0. Setup
- [x] git repo on `main` — no remote configured, so "pull" was a no-op and "push" = commits on local `main`
- [x] XcodeGen installed (2.46.0)
- [x] HA reachable with token: `GET /api/` → 200, bad token → 401, areas template works (curl from the Mac)
- [x] Signing team found in Xcode prefs/profiles: G93232N59R; iPhone 16 Pro Max + Apple Watch Ultra paired & `available`
- [x] Apple ID signed in to Xcode (2026-11-07); automatic signing created profiles for `ai.ronic.watchmagic` + `.watchkitapp`
- [x] `.gitignore`, `project.yml`, `README.md`

## 1. WatchMagicKit (shared package, pure logic)
- [x] Model: AppConfig, Room, ControlledDevice, Settings (Codable, versioned, tolerant decoding)
- [x] HomeAssistant: HAClient, HAModels, ActionMapper (+ domain-safety for kind overrides)
- [x] Pointing: Vector3, ForearmGeometry, ReferenceDirections, TargetResolver
- [x] Gestures: MotionSample/CSV, AimLockDetector, GestureDetector
- [x] Sync: SyncPayload
- [x] Tests: ActionMapper, TargetResolver, GestureDetector (synthetic CSV fixtures), HAClient, AimLock, model/sync, teach/zero/heading → `swift test` 104 tests, 0 failures (2 opt-in skips)
- [x] Move teach averaging, zero-gesture rule, compass-anchor math, trace recorder from the watch app into the Kit + tests (spec 3.3)
- [x] Relay entity-state fetch through the phone (`relayStateRequest`)
- [x] Phone relay accepts only the exact services ActionMapper emits (`RelayRequest.isAllowed`, tested)
- [x] HAClient defaults to an ephemeral, cache-free URLSession so the bearer header never lands in `Cache.db` (iOS app used `.shared`)
- [ ] Replace synthetic gesture fixtures with real Ultra traces (Sensor Probe → Record) and retune thresholds

## 2. iOS app
- [x] ConfigStore (JSON in App Support), Keychain token, PhoneSyncService (context push, taught vectors, traces, HA relay)
- [x] Views: Home (current-room picker, sync status), Connect (Test/import), RoomDetail, DevicePicker, DeviceEditor, Settings (+ Traces)
- [x] Builds for generic/platform=iOS (unsigned); launches in iOS 27 simulator, Home renders
- [~] Test / Import / relay against the real HA from the phone

## 3. Watch app
- [x] MotionService (heading-source fallback), RuntimeSession, WatchSyncService, ControlEngine
- [x] Views: Aim, Teach, SensorProbe (+ Record trace, latency)
- [x] StartWatchMagic App Intent + AppShortcutsProvider
- [x] Builds for generic/platform=watchOS (unsigned)

## 4. Done criteria (spec §2)
- [x] `xcodegen generate` clean
- [x] `swift test` passes
- [x] xcodebuild iOS (with embedded watch app) + watchOS: zero errors, zero warnings from our sources
- [x] Deployed to iPhone (signed build, installed + launched via devicectl)
- [ ] Deployed to Ultra — **BLOCKED (on user):** Developer Mode is off on the watch (`kAMDMobileImageMounterDiskImageRestricted`)
- [x] README written; [ ] Sensor Probe findings table still to be filled from the device
- [~] 2.2 iPhone on-device checks (Test success / 401, import, persistence, Keychain grep, room change → watch ≤ 5 s)
- [~] 2.3 watch on-device checks: reference frames/heading source, rotation convention, crown-axis assumption,
      teach all devices, aim accuracy 18/20, six actions, twist, latency ≤ 500 ms, 10-min no-false-trigger,
      repeated flicks, HA-down failure ≤ 3 s, relay path, extended session 10 min + resume state, Action button

## 5. Found along the way
- [ ] Error-within-3 s edge case: if HA *times out* (packets dropped) and the phone is reachable, direct 3 s + relay can take ~6 s. Fast failures (HA stopped, no network) stay < 3 s. Decide whether to shorten.
- [ ] WatchConnectivity stores the applicationContext (which carries the token, per spec 1.1.4) in the system's WC storage — check during the 2.2 Keychain `grep` test whether that lands inside the app container.
- [ ] URLSession from this Mac's CLI processes can't reach LAN hosts (macOS Local Network privacy) while curl can — the opt-in live HA test in `swift test` can't run from the terminal.
