# WatchMagic — Task checklist

Legend: [x] done & verified · [ ] open · [~] code done, needs on-device verification (cannot be confirmed from the Mac)

## 0. Setup
- [x] git repo on `main` (no remote configured → "pull"/"push" = local main)
- [x] XcodeGen installed (2.46.0)
- [x] HA reachable with token: `GET /api/` → 200, bad token → 401, areas template works
- [x] Signing team found: G93232N59R; iPhone 16 Pro Max + Apple Watch Ultra paired & available
- [ ] `.gitignore`, `project.yml`, `README.md`

## 1. WatchMagicKit (shared package, pure logic)
- [ ] Model: AppConfig, Room, ControlledDevice, Settings (Codable, versioned)
- [ ] HomeAssistant: HAClient, HAModels, ActionMapper
- [ ] Pointing: Vector3, ReferenceDirections, TargetResolver
- [ ] Gestures: MotionSample, AimLockDetector, GestureDetector
- [ ] Sync: SyncPayload
- [ ] Tests: ActionMapper, TargetResolver, GestureDetector, HAClient → `swift test` green

## 2. iOS app
- [ ] ConfigStore (JSON in App Support), Keychain token, PhoneSyncService (context push, taught vectors, traces, HA relay)
- [ ] Views: Home (current-room picker, sync status), Connect (Test/import), RoomDetail, DevicePicker, DeviceEditor, Settings
- [ ] Builds for generic/platform=iOS

## 3. Watch app
- [ ] MotionService (heading-source fallback), RuntimeSession, WatchSyncService, ControlEngine
- [ ] Views: Aim, Teach, SensorProbe (+ Record trace)
- [ ] StartWatchMagic App Intent
- [ ] Builds for generic/platform=watchOS

## 4. Done criteria
- [ ] `xcodegen generate` clean
- [ ] `swift test` passes
- [ ] xcodebuild iOS + watchOS zero errors
- [ ] Deployed to iPhone + Ultra via devicectl
- [ ] README complete
- [~] On-device acceptance (2.2 / 2.3) — needs a human with the watch on the wrist
