# WatchMagic — Task checklist

Legend: [x] done & verified on the Mac · [ ] open · [~] code done, needs on-device verification (needs the watch on a wrist / signing)

## 0. Setup
- [x] git repo on `main`, remote `origin` = github.com/vishwas-ronic/WatchMagic (added 2026-11-07; before that there was no remote and commits stayed local)
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
- [x] `ARFrameConversion` (ARKit → room frame, z up) + `RoomPlacement` (frame-consistency merge) + pitch bias in `ReferenceDirections` (mean taught−geometric pitch, ±20°) → `PlacementTests` (10)
- [x] Phone relay accepts only the exact services ActionMapper emits (`RelayRequest.isAllowed`, tested)
- [x] HAClient defaults to an ephemeral, cache-free URLSession so the bearer header never lands in `Cache.db` (iOS app used `.shared`)
- [ ] Replace synthetic gesture fixtures with real Ultra traces (Sensor Probe → Record) and retune thresholds

## 2. iOS app
- [x] ConfigStore (JSON in App Support), Keychain token, PhoneSyncService (context push, taught vectors, traces, HA relay)
- [x] Views: Home (current-room picker, sync status), Connect (Test/import), RoomDetail, DevicePicker, DeviceEditor, Settings (+ Traces)
- [x] Builds for generic/platform=iOS (unsigned); launches in iOS 27 simulator, Home renders
- [~] Test / Import / relay against the real HA from the phone
- [x] Apple-Home-style names: `NameCleaner` (Kit, 9 tests from the real HA names) strips device/room prefixes and slugs; HA device names fetched on import; area room names tidied; "Tidy names" button per room
- [x] Camera (LiDAR) placement (user request 2026-11-07): RoomDetail → "Place devices with camera" (`PlacementView` + `PlacementSession`): reticle raycast (mesh → planes → estimated), Set my seat = camera position, undo/re-place, markers; Save writes seat + coordinates in one `update`; per-room `ARWorldMap` (App Support/WorldMaps, not synced) for relocalization; fresh frame clears stale coordinates after a warning (`RoomPlacement`, Kit); alignment hint card; `NSCameraUsageDescription`
- [~] On the phone: AR placement accuracy, relocalization into a saved map, camera-permission prompt/denial, world-map save
- [x] HA whole-house 3D model (user request 2026-11-07): Kit `HouseModel` (tolerant subset of `/local/house3d/house.json` 1.x; chamfer-collapsed corner candidates; name-based space suggestion), `HouseAlignment` (room → house with the y-reflection, solved from 2 marked floor corners; fit error, warn > 0.25 m; inverse), `HouseCalibration` (house-wide yaw constant K → offset for aligned rooms without a taught device; house-wide pitch-bias fallback; `north_bearing_deg` = 90 − K + declination, default +1.0° E), `HouseLayout` (POST body for `sensor.watchmagic_layout`, client-side validation, deletes), `DeviceMount` from the hit normal, `CoordinatesSource`; `Room.houseSpaceID/houseAlignment` (tolerant); `RoomPlacement` carries alignment + mounts under the frame rule → `HouseTests` (20)
- [x] HAClient `houseModel()` (404 → "No house3d model on HA") + `postLayout(_:)`
- [x] iOS: `HouseService` (model cache, push, tracked pushed IDs → automatic deletes), RoomDetail "House model" section (space picker grouped by floor + suggestion, alignment status, Send), Settings "3D house view", PlacementView "Align to house" (outline with tappable corners, Mark A/B, fit warning, push after save), DeviceEditor mount picker
- [x] Watch: ControlEngine uses the house-wide fallback (`HouseCalibration`)
- [x] Real-HA round trip with `switch.watchmagic_selftest` / `seat-selftest`: add merged into `/local/house3d/devices.json`, delete removed both (curl from the Mac)
- [x] Watch diagnostics (coordinator request 2026-11-07): `DiagLog` (Kit; JSON lines, buffered, flushed every 2 s off the motion queue, rotation at 1 MB + `.1`, token-like keys dropped) → `Application Support/WatchMagic/diag.log`; logs lock/unlock, every gesture (acted / why not), strong-rotation bursts (`RotationBurstTracker`, |ω| > 1.5 rad/s, rate-limited), ActionMapper results, every HA call/state fetch (ms, error + URLError domain/code, via phone), config applies, Aim start (heading source/anchored, HA URL + getaddrinfo addresses), runtime-session / motion / scene-phase changes, trace transfers. Sensor Probe: "Send last 60 s" (`MotionRingBuffer`, always on) and "Send diag log" → phone Traces
- [x] Recording robustness: motion + extended runtime session kept alive on Aim, Teach, Sensor Probe (and on becoming active); recording ends with a partial file when samples stop for > 1 s (pipeline gap check + main-thread watchdog), never stuck in "Recording…"; traces written to a persistent Outbox (not tmp) until the transfer completes
- [x] Gesture training data (coordinator request 2026-11-07): `MotionSample.userAcceleration` + CSV `ax,ay,az` (optional on decode); phone-guided sessions (Settings → Train gestures: steps flickUp/flickDown/twist ×10 cues every 2.5 s, none 60 s; sound + haptic + animated forearm, Reduce Motion static; Redo/Skip/another round; summary) → `TrainingStart`/`TrainingCancel`/`TrainingStatus` messages (Kit) → watch records (`TrainingRecorder`, own cue haptics, actual cue timestamps) → `train-<label>-<time>.csv` with `# label/cues/wrist/rate` header → phone Documents/Training, Settings → Training data
- [~] On the Ultra: read diag.log after a real session (why no HA calls); training session end to end (watch reachable, cue sync phone↔watch ≈ message latency, files arrive)
- [ ] Train a Create ML activity classifier from the training CSVs and replace the rule-based detector (later)
- [~] On the phone: load house model, pick space, mark 2 corners (fit error), Send → devices appear in the 3D view at the right spot/side; mount classification; north bearing once a device in an aligned room is taught

## 3. Watch app
- [x] MotionService (heading-source fallback), RuntimeSession, WatchSyncService, ControlEngine
- [x] Views: Aim, Teach, SensorProbe (+ Record trace, latency)
- [x] Teach/Aim: "Teach one placed device to align this room" hint; Teach list marks placed devices (verified: a local teach → `WatchSyncService.recomputeEffective` → `ControlEngine.apply` → candidates recomputed)
- [x] StartWatchMagic App Intent + AppShortcutsProvider
- [x] Builds for generic/platform=watchOS (unsigned)

## 4. Done criteria (spec §2)
- [x] `xcodegen generate` clean
- [x] `swift test` passes
- [x] xcodebuild iOS (with embedded watch app) + watchOS: zero errors, zero warnings from our sources
- [x] Deployed to iPhone (signed build, installed + launched via devicectl)
- [x] Deployed to Ultra (watch registered to the team via `-allowProvisioningDeviceRegistration`; installed + launched via devicectl); iPhone app rebuilt so its embedded watch app carries the same profile
- [x] README written; [ ] Sensor Probe findings table still to be filled from the device
- [~] 2.2 iPhone on-device checks (Test success / 401, import, persistence, Keychain grep, room change → watch ≤ 5 s)
- [~] 2.3 watch on-device checks: reference frames/heading source, rotation convention, crown-axis assumption,
      teach all devices, aim accuracy 18/20, six actions, twist, latency ≤ 500 ms, 10-min no-false-trigger,
      repeated flicks, HA-down failure ≤ 3 s, relay path, extended session 10 min + resume state, Action button

## 5. Found along the way
- [ ] Error-within-3 s edge case: if HA *times out* (packets dropped) and the phone is reachable, direct 3 s + relay can take ~6 s. Fast failures (HA stopped, no network) stay < 3 s. Decide whether to shorten.
- [ ] WatchConnectivity stores the applicationContext (which carries the token, per spec 1.1.4) in the system's WC storage — check during the 2.2 Keychain `grep` test whether that lands inside the app container.
- [ ] North bearing assumes taught vectors are compass-referenced (xMagneticNorthZVertical or compass-anchored); vectors taught under the zero-gesture fallback would give a wrong bearing — confirm the Ultra's heading source (Sensor Probe).
- [ ] house.json polygons are inner wall faces ±0.1–0.2 m and corners are drawn chamfered (collapsed in `PlanPolygon.corners`), so a fit error of ~0.1–0.2 m is expected even with good marks.
- [ ] URLSession from this Mac's CLI processes can't reach LAN hosts (macOS Local Network privacy) while curl can — the opt-in live HA test in `swift test` can't run from the terminal.

## 5b. Real-wrist tuning (2026-11-07, from the phone-guided training session + watch diag.log)
- [x] Training data: flicks peaked 2–5 rad/s (5/20 barely registered), everyday movement > 3 rad/s 17 % of the time, twists 15–19 rad/s every time. A Create ML activity classifier trained on it missed all held-out flicks and fired on 4/15 everyday clips, so it was not shipped (pipeline kept in the session scratchpad).
- [x] User decision: **twist only** (toggle). Flicks ignored unless `Settings.flicksEnabled` (default off, no UI yet). Twist peak 5 → 12 rad/s (×0.75 high = 9), return ≥ 30 % (was 40 %; one real twist returned at 37 %). Replay: 11/11 real twists, 0 doubles, 1 twist-like motion in 60 s of everyday movement.
- [x] Lock: tolerance 12° → 15° (v1 configs still on 12° migrated, config version 2), lock kept until tolerance + 8° (diag: Curtain Bulb locked at 11.3° and dropped at 13.6° while still), max pitch 60° → 75° (Meghna ceiling fan is at 62.6°, it could never lock).
- [x] Device control stays on on every screen (was Aim screen only), except while teaching or training.
- [x] Live test 1 (diag.log 10:27–10:29): twists worked (4 toggles, HA 270–580 ms) but only 4 of 13 strong roll bursts (12–16 rad/s, nearly pure roll) counted: 9 missed the return-within-0.5 s rule, 2 were rejected as "window closed". Fix: twist fires when the first lobe ends (`twistRequiresReturn` default off, return swallowed by debounce), twist ignores the gesture window (acts whenever locked), immediate `.directionUp` haptic on recognition. Replay unchanged: 11/11 real twists, no doubles, 1 twist-like motion in 60 s everyday.
- [ ] Curtain Bulb locks 8.6–14.3° off its taught direction every time → its reference is ~10° off (taught in a different posture). Re-teach, or learn from confirmed toggles.
- [x] Live test 2 (10:32–10:39): Tubelight 1 locks at 5–11°; Curtain Bulb 11–14°, Bed Lamp 13°, Tubelight 2 13–15°; Fancy Light / Fans never locked. Only Curtain Bulb was ever taught on the watch (the "taught all devices" earlier was camera placement), so the rest come from LiDAR coordinates + seat + one offset.
- [x] User decisions: (1) re-teach on the watch AND auto-learn; (2) rotate-and-hold for brightness / speed.
- [x] `RollKnob` (Kit): roll angle from gravity about the forearm axis (sign checked against the integrated gyro on real twists), engage ≥ 30° held 0.4 s at < 2 rad/s, a step every 0.6 s, release < 18°, palm up = up on either wrist. Steps go through ActionMapper's up/down mapping (bypassing `flicksEnabled`). Twists are ignored while the knob is active and for 0.8 s after. The knob baseline is re-taken after each twist.
- [x] `AimLearning` (Kit): on the first twist that acts in an unambiguous lock, blend 35 % of the mean steady pointing during the lock into the device's reference (reject > 25°), save as its taught vector via the existing teach sync.
- [ ] On-wrist check of rotate-and-hold: does palm up feel like "up"? Do steps land at the right pace with HA's 0.3–0.6 s latency (queued "latest wins")?
- [x] Meghna Room → house3d F-2 (Meghna Bedroom) pushed to HA without the on-phone corner alignment (2026-11-07). Fit from the Mac: rotation from the watch compass offset (−102.2°) + a −18.7° correction, translation (6.98, 19.70), solved from the user's facts: Tubelight 1 / 2 on opposite walls (0.18 / 0.10 m from the S / N walls) and Curtain Bulb in a corner (0.09 m). The mirror solution (+160°) was rejected by the compass. Independent check: the ceiling fan lands 0.1 m from the room centre. z = room z + 4.10, estimated from the fan hanging ~0.4 m below the 3.05 m ceiling (tubelights 2.3 m above the floor). Mounts: tubelights wall; fans and Fancy Light ceiling (hanging, 0.8 m from any wall); Bed Lamp and Curtain Bulb floor (standing, ~1.3 m). Verified in /local/house3d/devices.json: 7 devices + seat-e4ddd6eb. The phone app doesn't know this alignment (the room has no houseAlignment), so it neither re-sends nor deletes these; a later "Align to house" on the phone would overwrite them by entity_id.
- [ ] The fit's −18.7° compass correction suggests either the plan's "+y = north" or the watch's taught offset is ~19° off. North bearing not sent.
- [ ] Meghna Room has two "Fan" entries (fan.meghna_fan_meghna_room_fan + switch.meghna_room_fan) 1.2° apart → always ambiguous; remove one.
- [ ] Only Curtain Bulb has a taught vector; the room's compass offset rests on that one device. Teaching one more device would average the offset.

## 6. House 3D model integration (agreed with the house3d agent, 2026-11-07)
- Read: `GET /local/house3d/house.json` (schema 1.1, metres; frame x = plan right, y = plan down, z up → **left-handed**, needs a reflection from our room frame). Rooms map by `space_id` (`ha_area_id` is null for now). Align on `spaces[].poly`, never `poly_render`.
- Write: `POST /api/states/sensor.watchmagic_layout` {state: ISO time, attributes: {schema "watchmagic-layout/1", devices[], seats[], north_bearing_deg}} → HA automation merges into `/config/www/house3d/devices.json` (by entity_id / seat id; `delete: true` removes; one invalid item rejects the post).
- North: `north_bearing_deg` = bearing of house +y, clockwise from TRUE north (expected ≈ 350–358).
- [ ] Kit: HouseModel, HouseAlignment (2-corner fit + reflection), north bearing, layout payload builder, house-wide compass offset — in progress
- [ ] iPhone: space picker, "Align to house" in PlacementView, push layout on save — in progress
- [ ] Real-HA round trip with a self-test device (add → devices.json → delete) — in progress
