# WatchMagic

Point your Apple Watch Ultra at a light, fan or switch and flick to control it through Home Assistant.
The iPhone app ("WatchMagic") connects to Home Assistant and holds all configuration; the watch app
("WatchMagic Watch App") does the aiming, gesture detection and service calls. See `SPEC.md` for the
full behaviour and `TASKS.md` for the current checklist.

```
Packages/WatchMagicKit   shared pure logic (models, HA client, action mapping, pointing, gestures, sync payloads)
iOSApp/                  iPhone companion app (iOS 17+)
WatchApp/                watch app (watchOS 10+), embedded in the iPhone app
project.yml              XcodeGen spec — the .xcodeproj is generated, never committed
```

## 1. Prerequisites

- Xcode 27 (or any Xcode with iOS 17 / watchOS 10 SDKs).
- XcodeGen: `brew install xcodegen`
- An Apple ID signed in to Xcode (**Xcode → Settings → Accounts**) that belongs to the signing team.
  Automatic signing needs it to create the development profiles for the two bundle IDs.

## 2. Generate the project

```sh
cd /Users/vishwas/WatchMagic
xcodegen generate          # writes WatchMagic.xcodeproj
open WatchMagic.xcodeproj
```

Re-run `xcodegen generate` whenever files are added or `project.yml` changes.

## 3. Signing team

`project.yml` sets `DEVELOPMENT_TEAM: G93232N59R` with automatic signing and these bundle IDs:

| Target | Bundle ID |
|---|---|
| WatchMagic (iOS) | `ai.ronic.watchmagic` |
| WatchMagic Watch App | `ai.ronic.watchmagic.watchkitapp` |

To use another team, change `DEVELOPMENT_TEAM` (and, if needed, `bundleIdPrefix` / the two bundle IDs plus
`WKCompanionAppBundleIdentifier`) in `project.yml`, then regenerate.

## 4. Home Assistant long-lived access token

1. Open Home Assistant → click your user (bottom-left) → **Security** tab.
2. Under **Long-lived access tokens** click **Create token**, name it "WatchMagic", copy it.
3. In the iPhone app: **Connect** → URL `http://homeassistant.local:8123` → paste the token → **Test**.
   "Connected" means the token works; "401 – token invalid" means it doesn't.

The token is stored only in the Keychain (iPhone and watch). It is never written to UserDefaults or files,
and it must never be committed to this repo.

## 5. Build and install

Tests (no device needed):

```sh
cd Packages/WatchMagicKit && swift test
```

Build check (no signing needed):

```sh
xcodebuild -project WatchMagic.xcodeproj -scheme WatchMagic -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WatchMagic.xcodeproj -scheme "WatchMagic Watch App" -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
```

Install on the iPhone and the Ultra (both paired, unlocked, Developer Mode on):

```sh
xcrun devicectl list devices                       # note the iPhone and watch identifiers
xcodebuild -project WatchMagic.xcodeproj -scheme WatchMagic -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcodebuild -project WatchMagic.xcodeproj -scheme "WatchMagic Watch App" -destination 'generic/platform=watchOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone-id> "build/Build/Products/Debug-iphoneos/WatchMagic.app"
xcrun devicectl device install app --device <watch-id> "build/Build/Products/Debug-watchos/WatchMagic Watch App.app"
```

(Or simply Run the `WatchMagic` scheme on the iPhone from Xcode; the watch app is embedded and installs with it.)
The first launch of the watch app asks for Motion and Location (compass heading) permission — allow both.

## 6. Set up rooms (iPhone)

1. **Connect** → Test → **Import**. Light / fan / switch entities are listed; Home Assistant areas appear as
   suggested rooms — tap one to add it, or create rooms by hand.
2. In a room: optionally enter the seat position and device coordinates `(x, y, z)` in metres (any room frame,
   e.g. x along one wall, z up). Override a device's kind if needed (e.g. a `switch.*_fan` relay shown as a fan).
3. Pick the room with **I'm in: … ▾** on the home screen. The watch only targets devices in the current room.

## 7. Teach workflow (watch, from your usual seat)

1. Open WatchMagic on the watch → **Teach**.
2. Pick a device, point your forearm at it and hold steady ~1 s; this is captured three times. If the three
   samples agree within 4°, the averaged direction is saved and sent to the phone (shown as "Taught ✓").
   Otherwise you're asked to retry.
3. Teach every device, or teach one device that also has coordinates — the room's compass offset is derived
   from it and coordinate-only devices become aimable too.
4. **Re-teach** / **Clear** per device.

## 8. Using it

- Raise your arm, point at a device and hold still ~0.3 s → light haptic, the device name and state appear (locked).
- **Flick up**: on / brighter / faster. **Flick down**: dimmer / slower / off at the minimum. **Twist** (roll the
  forearm and back): toggle. Keep pointing and flick again to keep stepping.
- If two devices are close together, both are shown — turn the Digital Crown to choose.
- Drop the arm or move off target to unlock.

## 9. Action button (Ultra)

1. On the iPhone open **Shortcuts** → new shortcut → add the **Start WatchMagic** action (from the WatchMagic
   watch app) → name it "WatchMagic" and make sure it is shown on Apple Watch.
2. On the watch: **Settings → Action Button → Action: Shortcut → WatchMagic**.
3. One press now opens WatchMagic straight into the Aim screen and starts the extended runtime session.

## 10. Sensor Probe findings

The Sensor Probe screen (watch) shows the available attitude reference frames, heading availability/accuracy,
the active heading source, the detected rotation-matrix convention, live yaw/pitch/roll, the resolved target,
the last gesture with its peak rate, and service-call latency. **Record** saves a 10 s CSV motion trace and sends
it to the phone (iPhone app → Settings → Traces) for use as gesture test fixtures
(`Packages/WatchMagicKit/Tests/WatchMagicKitTests/Fixtures/`).

| Question | Answer on the Apple Watch Ultra |
|---|---|
| Is `xMagneticNorthZVertical` listed in `availableAttitudeReferenceFrames()`? | _not yet measured — fill in from Sensor Probe_ |
| Heading available (`CLLocationManager.headingAvailable()`) / typical accuracy | _not yet measured_ |
| Active heading source | _not yet measured_ |
| Rotation-matrix convention detected (expected `referenceToDevice`) | _not yet measured_ |
| Median flick → HA-return latency (10 trials, Wi-Fi) | _not yet measured (target ≤ 500 ms)_ |

## 11. Troubleshooting

- **"HA unreachable"** on the watch: the watch talks to Home Assistant directly over Wi-Fi; if that fails with a
  network error it retries once through the iPhone. Make sure the iPhone app has been opened once and Local
  Network access was allowed (iOS Settings → Privacy → Local Network → WatchMagic).
- **"401 – token invalid"**: create a new long-lived token and enter it in Connect; it syncs to the watch.
- **Gestures too eager / too hard**: iPhone app → Settings → Gesture sensitivity. Record traces in Sensor Probe
  and add them as fixtures to tune thresholds in `GestureDetector.swift`.
