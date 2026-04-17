# nap-time

iOS app for smart nap management using a Colmi smart ring via BLE. Detects sleep onset with PPG/HRV analysis and triggers alarms. Built with SwiftUI, no external dependencies.

## Project Structure

- `nap-time/` — Main app target (SwiftUI)
  - `Views/` — ContentView (tab nav), MainNapView, ConnectionView, SettingsView, HRVChartView, CalibrationView (tap coordinate testing)
  - `Models/` — NapSession, SleepDetectionConfig, BLEConstants, HRV/PPG data types
  - `Services/` — ColmiRingManager (BLE), HRVCalculator, PPGProcessor, SleepOnsetDetector, NapAlarmController
  - `Resources/` — alarm_gentle.caf
- `NapAlarmWidget/` — WidgetKit extension with Live Activity support
- `scripts/` — Automation helpers
  - `tap_screen.py` — Screenshot + tap/swipe/type helper for iPhone Mirroring interaction
- Schemes: `nap-time`, `NapAlarmWidgetExtension`

## Key Identifiers

| Item | Value |
|---|---|
| Bundle ID | `com.andreykats.nap-time` |
| Widget Bundle ID | `com.andreykats.nap-time.NapAlarmWidget` |
| Team ID | `S39JCV5G6C` |
| Deployment Target | iOS 26.4 |

## Device & Simulator IDs

| Target | ID |
|---|---|
| Physical device (xcodebuild) | `platform=iOS,id=00008110-00192C2A26C0401E` |
| Physical device (devicectl) | `E84BA5A4-CBB5-52DC-94C3-CACEF1602877` |
| iPhone 17 Pro sim (iOS 26.4) | `5072BFA8-FF9F-46FA-8170-369F3AD4D94E` |

## Building

```bash
# Simulator
xcodebuild build \
  -project /Users/Andrey/Desktop/nap-time/nap-time.xcodeproj \
  -scheme "nap-time" \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=5072BFA8-FF9F-46FA-8170-369F3AD4D94E' \
  -derivedDataPath /Users/Andrey/Desktop/nap-time/build

# Physical device
xcodebuild build \
  -project /Users/Andrey/Desktop/nap-time/nap-time.xcodeproj \
  -scheme "nap-time" \
  -configuration Debug \
  -destination 'platform=iOS,id=00008110-00192C2A26C0401E' \
  -allowProvisioningUpdates
```

### Build output paths

| Target | Path |
|---|---|
| Simulator (custom derivedData) | `build/Build/Products/Debug-iphonesimulator/nap-time.app` |
| Physical device (default derivedData) | `/Users/Andrey/Library/Developer/Xcode/DerivedData/nap-time-aooqcuyghpwmuudviqypgkvprakq/Build/Products/Debug-iphoneos/nap-time.app` |

## Running on Simulator

```bash
# Boot & open
xcrun simctl boot 5072BFA8-FF9F-46FA-8170-369F3AD4D94E
open -a Simulator

# Install & launch
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/nap-time.app
xcrun simctl launch --console-pty booted com.andreykats.nap-time

# Terminate
xcrun simctl terminate booted com.andreykats.nap-time
```

## Running on Physical Device

All commands work over WiFi — no USB required.

```bash
# Install
xcrun devicectl device install app \
  --device E84BA5A4-CBB5-52DC-94C3-CACEF1602877 \
  /Users/Andrey/Library/Developer/Xcode/DerivedData/nap-time-aooqcuyghpwmuudviqypgkvprakq/Build/Products/Debug-iphoneos/nap-time.app

# Launch (without logs)
xcrun devicectl device process launch \
  --device E84BA5A4-CBB5-52DC-94C3-CACEF1602877 \
  com.andreykats.nap-time

# Terminate (requires PID — find it first)
xcrun devicectl device info processes \
  --device E84BA5A4-CBB5-52DC-94C3-CACEF1602877 2>&1 | grep "nap-time.app/nap-time"
xcrun devicectl device process terminate \
  --device E84BA5A4-CBB5-52DC-94C3-CACEF1602877 --pid <PID>
```

## Console Logs

The app uses `Logger` (os_log) with subsystem `com.andreykats.nap-time` and categories: BLE, HRV, PPG, Sleep, Alarm.

### Simulator

```bash
# Stream os_log filtered by app
xcrun simctl spawn booted log stream --level debug \
  --predicate 'process == "nap-time" OR subsystem == "com.andreykats.nap-time"'

# Or capture stdout/stderr directly
xcrun simctl launch --console-pty booted com.andreykats.nap-time
```

### Physical device

The `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=YES` env var makes Logger/os_log output flow to stderr, which `--console` captures. This terminates the existing instance and relaunches with log streaming. Works over WiFi.

```bash
DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=YES \
xcrun devicectl device process launch --console --terminate-existing \
  --device E84BA5A4-CBB5-52DC-94C3-CACEF1602877 \
  com.andreykats.nap-time
```

Filter for the app's own Logger categories with: `grep -E "\[BLE\]|\[HRV\]|\[PPG\]|\[Sleep\]|\[Alarm\]"`

**Note:** `--console` blocks until the app terminates. Run it in the background (`&`) and `kill` the process when done, or redirect to a file.

## Screenshots & Screen Interaction

### Simulator

```bash
# Screenshot
xcrun simctl io booted screenshot /tmp/sim_screen.png

# Screen recording (stop with Ctrl+C)
xcrun simctl io booted recordVideo /tmp/recording.mov
```

### Simulator UI Interaction via idb

`idb ui` commands are **simulator-only**. They do not work on physical devices.

The agent workflow is: **screenshot → describe-all → tap/type → repeat**.

```bash
# Accessibility tree (find elements and their coordinates)
idb ui describe-all                     # Human-readable
idb ui describe-all --json              # Machine-parseable JSON
idb ui describe-all --nested            # Nested hierarchy
idb ui describe-point <x> <y> --json   # What's at this coordinate?

# Touch
idb ui tap <x> <y>                     # Tap
idb ui tap <x> <y> --duration 2.0      # Long press
idb ui swipe <x1> <y1> <x2> <y2>      # Swipe

# Text input
idb ui text "hello world"              # Type into focused field
idb ui key <keycode>                   # Press key

# Hardware buttons
idb ui button HOME
idb ui button LOCK
idb ui button SIDE_BUTTON
```

## Environment Control

```bash
xcrun simctl openurl booted "myapp://deeplink"
echo "text" | xcrun simctl pbcopy booted
xcrun simctl privacy booted grant all com.andreykats.nap-time
xcrun simctl location booted set 37.7749,-122.4194
xcrun simctl ui booted appearance dark
xcrun simctl push booted com.andreykats.nap-time payload.json
```
