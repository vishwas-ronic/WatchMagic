# WatchMagic — Spec

Point your Apple Watch Ultra at a device in your room and flick to control it through Home Assistant. An iPhone companion app connects to Home Assistant, sets which room you're in, and handles all the other configuration.

---

## 1. What should it do?

### 1.1 iPhone app ("WatchMagic"): pairing and configuration

1. **Connect to Home Assistant**
   - Enter the Home Assistant URL (default `http://homeassistant.local:8123`) and a long-lived access token. A **Test** button calls `GET /api/` and shows success or the error.
   - Store the token in the Keychain. Never put it in UserDefaults or plain files.
   - Import entities from `GET /api/states`, keeping only the `light.*`, `fan.*` and `switch.*` domains. Show each entity's friendly name, domain and current state.
   - Import Home Assistant areas and their entities with `POST /api/template` (`{{ areas() }}`, `{{ area_name(a) }}`, `{{ area_entities(a) }}`) and offer them as starting rooms. Manually created rooms must also work.

2. **Rooms and devices**
   - Create, rename and delete rooms. Add or remove controllable devices (Home Assistant entities) in each room.
   - For each room, you can optionally enter the **seat position** `(x, y, z)` in metres in a room frame of your choosing.
   - For each device, you can optionally enter its **coordinates** `(x, y, z)` in the same frame. Set the device type automatically from the domain (light / fan / switch) and allow overriding it. A light is "dimmable" if its `supported_color_modes` include anything other than `onoff`.
   - **Current room** picker, prominent on the home screen: "I'm in: Bedroom ▾". It's set manually until automatic room detection exists. The watch only targets devices in the current room.

3. **Tuning settings** (global, with sensible defaults)
   - Brightness step: default 20%.
   - Fan step: default is the entity's own `percentage_step`.
   - Aim tolerance: default 12°. Ambiguity margin: default 5°. Aim-hold time: default 300 ms. Gesture window after lock: default 1.5 s.
   - Gesture sensitivity: low / medium / high.
   - "Flick down at minimum turns off": default on.

4. **Sync to the watch**
   - Push the full config (Home Assistant URL, token, rooms, devices, calibration, settings, current room) to the watch with WatchConnectivity `updateApplicationContext`. Push it again on every change.
   - Show sync status: last synced time, and whether the watch app is installed or reachable.
   - Receive the calibration vectors recorded on the watch (see 1.2.4), save them, and show each device as "Taught ✓ / Coordinates only / Not placed".

### 1.2 Watch app (WatchMagic Watch App): aim and control

1. **Pointing estimate**
   - Use CoreMotion `CMDeviceMotion` at 50–100 Hz. Compute a forearm pointing unit vector from the attitude, taking `WKInterfaceDevice.wristLocation` and `crownOrientation` into account so either wrist works.
   - Choose the heading source in this order:
     1. A north-referenced CoreMotion frame (`xMagneticNorthZVertical`), if `availableAttitudeReferenceFrames()` lists it.
     2. Otherwise, `xArbitraryCorrectedZVertical`, with absolute yaw anchored by `CLLocationManager` heading. Re-anchor slowly when heading accuracy is good.
     3. Otherwise, `xArbitraryCorrectedZVertical` plus a **zero gesture**: point at the room's anchor device and hold for 1.5 s on the Aim screen.
   - Show which source is active on the Sensor Probe screen.

2. **Target resolution** (pure logic in the shared package)
   - Each device in the current room has a reference direction from the seat. Use the taught vector if it exists. Otherwise compute it from coordinates (`device − seat`) rotated by the room's compass offset. The offset is derived from any taught device that also has coordinates.
   - Pick the device with the smallest angle to the current pointing vector. Accept it only if that angle ≤ aim tolerance and it beats the runner-up by ≥ the ambiguity margin.
   - If two devices are within the margin, show both. Turning the Digital Crown switches between them while locked.

3. **Gestures and actions** (Ultra-compatible: motion only, no double-tap)
   - **Lock**: arm raised (pointing pitch between −30° and +60°) and steady (angular speed below a threshold) for the aim-hold time over a resolvable target. On lock, play a light haptic, show the device name, icon and current state, and open the gesture window.
   - **Flick up**: a sharp upward rotation of the wrist about the forearm's lateral axis.
   - **Flick down**: the same in the opposite direction.
   - **Twist**: a sharp roll about the forearm axis (pronation then return).
   - Use rule-based detection on gyroscope rotation-rate peaks, with thresholds scaled by the sensitivity setting. Flicks are ignored unless a target is locked, and each gesture is debounced.
   - Action mapping:

     | Gesture | Light (dimmable) | Light (on/off) / Switch | Fan |
     |---|---|---|---|
     | Flick up | Off → `light.turn_on`; On → `light.turn_on` `brightness_step_pct: +step` | `turn_on` | Off → `fan.turn_on`; On → `fan.increase_speed` |
     | Flick down | `light.turn_on` `brightness_step_pct: −step`; at the minimum → `light.turn_off` | `turn_off` | `fan.decrease_speed`; at the minimum → `fan.turn_off` |
     | Twist | `homeassistant.toggle` | `homeassistant.toggle` | `homeassistant.toggle` |

     The "at the minimum → off" behaviour is controlled by the setting in 1.1.3.
   - After each gesture, keep the lock and reopen the gesture window, so repeated flicks keep stepping. The lock ends when the arm drops or moves off the target.

4. **Teach mode** (calibration done on the watch, from your usual seat)
   - Show the current room's devices as a list. Pick one, point at it, and hold steady for 1 s. Capture three samples; if they're within 4° of each other, average them and save the vector. Otherwise ask to retry.
   - Send the taught vectors to the phone (WatchConnectivity `transferUserInfo`) and keep a local copy.
   - Show "Re-teach" and "Clear" for each device.

5. **Calling Home Assistant**
   - The watch calls the Home Assistant REST API directly with `URLSession`: `POST /api/services/<domain>/<service>` with a bearer token. Use a 3 s timeout.
   - After success, read the entity state from the service response (or a follow-up `GET /api/states/<entity_id>`) and update the on-screen state.
   - If the direct call fails with a network error, retry once through the iPhone (`WCSession.sendMessage`, with the phone app making the call).
   - Feedback: success → `.success` haptic. Failure → `.failure` haptic and a short error such as "HA unreachable" or "401 token invalid".

6. **Staying active**
   - Run as a `WKExtendedRuntimeSession` while the Aim screen is open, so motion keeps streaming with the wrist lowered. Restart the session when it expires. Show a "Session ended — tap to resume" state.
   - Expose a "Start WatchMagic" App Intent. You can then assign it to the **Ultra Action button** through a Shortcut, so one press opens the app straight into aiming.

7. **Sensor Probe screen** (diagnostics; do this first)
   - Show the available attitude reference frames, whether a heading is available and its accuracy, and live yaw, pitch and roll.
   - Show the resolved target with its angle, the last detected gesture with its peak rotation rate, and the active heading source.
   - **Record**: save a 10 s motion trace (CSV) and send it to the phone, to be used as gesture test fixtures.

### 1.3 Out of scope (for now)
- Automatic room detection. The phone's manual "current room" is the stand-in, and the config model must not prevent adding it later.
- Pointing from more than one seat per room.
- Entity domains other than light, fan and switch.
- App Store distribution. This is a personal build installed from Xcode.

---

## 2. What does "done" look like?

### 2.1 Builds and tests (no device needed)
- [ ] `xcodegen generate` produces `WatchMagic.xcodeproj` with no errors.
- [ ] `cd Packages/WatchMagicKit && swift test` passes, including:
  - `ActionMapperTests`: every row and column of the table in 1.2.3, including off→on, minimum→off with the setting on and off, and the correct service names and payload keys.
  - `TargetResolverTests`: picks the right device; returns `.none` beyond tolerance; returns `.ambiguous` within the margin; a taught vector overrides coordinates; the compass offset is derived correctly from one taught device.
  - `GestureDetectorTests`: on synthetic traces, flick up / flick down / twist are classified correctly, with no gesture from slow arm movements.
  - `HAClientTests`: correct URL, `Authorization: Bearer` header and JSON body for each service call; 401, timeout and non-JSON responses map to clear errors.
- [ ] `xcodebuild` builds the iOS scheme for `generic/platform=iOS` and the watch scheme for `generic/platform=watchOS` with zero errors. A watchOS simulator runtime isn't required.

### 2.2 iPhone app (on the real phone, same LAN)
- [ ] With the Home Assistant URL and token entered, **Test** shows success. A deliberately wrong token shows "401 – token invalid".
- [ ] Import lists every `light.*`, `fan.*` and `switch.*` entity with its friendly name. Home Assistant areas appear as suggested rooms.
- [ ] A room can be created, have devices and seat/device coordinates added, and be set as current. All of this survives an app restart.
- [ ] The token is in the Keychain; `grep` of the app container finds no token in plain files.
- [ ] Changing the current room on the phone is reflected on the watch Aim screen within 5 s while both apps are running.

### 2.3 Watch app on the Apple Watch Ultra
- [ ] Sensor Probe shows the available reference frames and the active heading source. This answers whether north-referenced attitude is available on the Ultra, and the answer is recorded in `README.md`.
- [ ] Teach mode saves a vector for every device in the test room, and the phone shows each one as "Taught ✓".
- [ ] **Aim accuracy** (from the usual seat, devices at least 20° apart): over 20 aims per device, at least 18 lock on the correct device and **none** lock on a wrong one.
- [ ] **All six actions work on real devices** and the Home Assistant state changes accordingly:
  1. Turn a light/switch on (flick up)
  2. Turn it off (flick down / twist)
  3. Increase fan speed (flick up while on)
  4. Decrease fan speed (flick down while on)
  5. Increase lamp brightness (flick up while on)
  6. Decrease lamp brightness (flick down while on)
- [ ] Twist toggles each device type. No double-tap is used anywhere.
- [ ] **Latency**: median time from the end of a flick to the Home Assistant service call returning is ≤ 500 ms on Wi-Fi, measured over 10 trials with on-watch timestamps shown in Sensor Probe.
- [ ] **No false triggers**: 10 minutes with the Aim screen open while typing, drinking, scrolling the phone and gesturing in conversation, with **0** service calls sent.
- [ ] Repeated flicks while staying locked keep stepping brightness or speed without re-aiming.
- [ ] With Home Assistant stopped or the network off, a gesture produces a failure haptic and an error message within 3 s, and the app does not hang. With the watch's direct route blocked but the phone reachable, the call succeeds through the phone relay.
- [ ] The extended runtime session keeps aiming working with the wrist lowered and raised again for at least 10 minutes. An expired session shows the resume state.
- [ ] The Action button, configured through a Shortcut that runs "Start WatchMagic", opens the app straight into the Aim screen.

### 2.4 Docs
- [ ] `README.md` covers: installing XcodeGen, generating the project, setting the signing team, creating a Home Assistant long-lived token, installing on the iPhone and the Ultra, assigning the Action button, the teach workflow, and the Sensor Probe findings.

---

## 3. Where is the work?

### 3.1 Environment (checked 2026-11-07)
- Home Assistant is reachable on the LAN at `http://homeassistant.local:8123`. `/api/` returns `401`, so it's up and needs a token.
- Xcode 27.0 is installed. An iOS 27 simulator runtime is installed. A watchOS simulator runtime is **not** installed.
- Target watch: **Apple Watch Ultra**. There's no double-tap gesture, so every action must work with motion gestures alone.
- `/Users/vishwas/WatchMagic/` is not yet a git repository and has no remote. Run `git init -b main` before the first commit. "Push to main" means committing to local `main` until a remote is added.
- "Deploy" for this project means building both apps and installing them on the paired iPhone and Apple Watch Ultra (`xcodebuild` + `xcrun devicectl`).

### 3.2 Layout

Everything lives in `/Users/vishwas/WatchMagic/`. The project is generated with **XcodeGen** (`brew install xcodegen`) from a committed `project.yml`. The generated `.xcodeproj` is not committed.

```
WatchMagic/
├── SPEC.md                         ← this file
├── how_to_spec.md                  ← spec-writing guide this spec follows
├── TASKS.md                        ← working checklist, ticked as items are done
├── README.md                       ← setup: xcodegen, signing team, HA token, installing on the Ultra
├── project.yml                     ← XcodeGen: iOS app + watchOS app targets, both depend on WatchMagicKit
├── .gitignore                      ← *.xcodeproj, DerivedData, xcuserdata
│
├── Packages/WatchMagicKit/         ← shared Swift package: all pure logic, unit-tested with `swift test` on macOS
│   ├── Package.swift               ← platforms: iOS 17+, watchOS 10+, macOS 14+ (macOS only for tests)
│   ├── Sources/WatchMagicKit/
│   │   ├── Model/
│   │   │   ├── AppConfig.swift         ← top-level Codable config (HA URL, rooms, currentRoomID, settings, version)
│   │   │   ├── Room.swift              ← id, name, seat position, compass offset, device IDs
│   │   │   ├── ControlledDevice.swift  ← entityID, name, kind (dimmableLight/onOffLight/switch/fan), coords, taughtVector
│   │   │   └── Settings.swift          ← steps, tolerances, timings, sensitivity
│   │   ├── HomeAssistant/
│   │   │   ├── HAClient.swift          ← async REST client: ping, states, template, callService, entityState
│   │   │   ├── HAModels.swift          ← EntityState, ServiceCall, error types
│   │   │   └── ActionMapper.swift      ← (Gesture, DeviceKind, current state, Settings) → ServiceCall  [table in 1.2.3]
│   │   ├── Pointing/
│   │   │   ├── Vector3.swift           ← math helpers, angle between vectors, yaw/pitch ↔ vector
│   │   │   ├── ReferenceDirections.swift ← taught vector or coords + compass offset → direction
│   │   │   └── TargetResolver.swift    ← tolerance + ambiguity margin → .none / .locked(id) / .ambiguous([id])
│   │   ├── Gestures/
│   │   │   ├── MotionSample.swift      ← timestamp, rotation rate, gravity, attitude quaternion
│   │   │   ├── AimLockDetector.swift   ← steady-and-raised for N ms → lock events
│   │   │   └── GestureDetector.swift   ← flickUp / flickDown / twist from rotation-rate peaks, debounced
│   │   └── Sync/
│   │       └── SyncPayload.swift       ← encode/decode config + taught vectors for WatchConnectivity
│   └── Tests/WatchMagicKitTests/
│       ├── ActionMapperTests.swift
│       ├── TargetResolverTests.swift
│       ├── GestureDetectorTests.swift  ← runs on recorded CSV traces in Fixtures/
│       ├── HAClientTests.swift         ← URLProtocol stub; request paths, headers, bodies
│       └── Fixtures/                   ← motion traces recorded from the Ultra (Sensor Probe → Record)
│
├── iOSApp/                         ← target "WatchMagic" (iOS 17+)
│   ├── WatchMagicApp.swift
│   ├── Info.plist                  ← NSLocalNetworkUsageDescription, ATS NSAllowsLocalNetworking
│   ├── Services/
│   │   ├── ConfigStore.swift       ← persists AppConfig (JSON in Application Support), publishes changes
│   │   ├── Keychain.swift          ← token storage
│   │   └── PhoneSyncService.swift  ← WCSession: push context, receive taught vectors/traces, relay HA calls
│   └── Views/
│       ├── HomeView.swift          ← current-room picker, sync status, room list
│       ├── ConnectView.swift       ← URL + token + Test + import
│       ├── RoomDetailView.swift    ← seat coords, devices, calibration status
│       ├── DevicePickerView.swift  ← choose HA entities to add
│       ├── DeviceEditorView.swift  ← kind override, coordinates
│       └── SettingsView.swift      ← tuning values
│
└── WatchApp/                       ← target "WatchMagic Watch App" (watchOS 10+), embedded in the iOS app
    ├── WatchMagicWatchApp.swift
    ├── Info.plist                  ← NSMotionUsageDescription, NSLocationWhenInUseUsageDescription (heading),
    │                                  ATS NSAllowsLocalNetworking, WKBackgroundModes for the extended runtime session
    ├── Services/
    │   ├── MotionService.swift     ← CoreMotion + CLLocationManager heading → MotionSample stream, heading-source fallback
    │   ├── RuntimeSession.swift    ← WKExtendedRuntimeSession lifecycle
    │   ├── WatchSyncService.swift  ← WCSession: receive config, send taught vectors/traces, phone relay
    │   └── ControlEngine.swift     ← wires motion → AimLock → TargetResolver → GestureDetector → ActionMapper → HAClient
    ├── Intents/
    │   └── StartWatchMagicIntent.swift ← App Intent for the Action button via Shortcuts
    └── Views/
        ├── AimView.swift           ← main screen: target name/state, lock indicator, crown disambiguation
        ├── TeachView.swift         ← per-device calibration
        └── SensorProbeView.swift   ← diagnostics + trace recording
```

### 3.3 Rules
- Pure logic (math, gesture detection, action mapping, Home Assistant request building, config models) goes **only** in `WatchMagicKit`, so it can be tested without a device.
- Platform code (CoreMotion, CoreLocation, WatchConnectivity, Keychain, UI) stays in the two app targets.
- No third-party dependencies apart from XcodeGen as a build tool.

---

None of the subagnets or you should ask me for yes no for anything, command etc. handle it before anything starts
make sure to git pull latest before you start

Give each part to its own subagent. When a subagent reports back, check its evidence before you accept it.
Keep a checklist in TASKS.md. Tick each item when it's done, and add anything new you find.
Stop and ask me only if when you are going out of scope. or changing the soul of the platform, or fixing instance vs process, or if you are creating a complex solution that can be done better if you just take a step back and analyse..
Before you report it finished, review your own diff and fix anything you'd block a merge for.
Mark anything you couldn't confirm, and say where you looked.

Testing should be done to make sure all changes are fine but testing shouldnt be so over done that time is wasted. ensure that testing is done, but not 1000 times. each change shouldnt require entire chain tested. maybe at larger instances like merging major works require testing! 

push all to main/master. 


End with three headings: Changed, Found, pending questions or blockers on me, if any, with your suggestions.  

deploy if nothing is pending on me. 


