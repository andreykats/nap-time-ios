# nap-time

iOS app for smart nap management using a Colmi smart ring via BLE. Detects sleep onset from native per-beat HRV intervals and triggers alarms. Built with SwiftUI, no external dependencies.

## Project Structure

- `nap-time/` — Main app target (SwiftUI)
  - `Views/` — ContentView (tab nav), MainNapView, ConnectionView, SettingsView, HRVChartView, CalibrationView (tap coordinate testing)
  - `Models/` — NapSession, SleepDetectionConfig, BLEConstants, HRV/PPG data types
  - `Services/` — ColmiRingManager (BLE), HRVCalculator, SleepOnsetDetector, NapAlarmController
  - `Resources/` — alarm_gentle.caf
- `NapAlarmWidget/` — WidgetKit extension with Live Activity support
- `scripts/` — Automation helpers
  - `tap_screen.py` — Screenshot + tap/swipe/type helper for iPhone Mirroring interaction
- Schemes: `nap-time`, `NapAlarmWidgetExtension`

## Data Pipeline

```
Colmi ring → 0x69 0x0A HRV packets (~2/s) → parse bytes 6-7 as UInt16 LE = IBI ms
  → ColmiRingManager.ibiContinuation (AsyncStream<InterBeatInterval>)
  → NapAlarmController Task 2 → HRVCalculator.addIBIs → HRVFeatures every 30s
  → SleepOnsetDetector → baseline (5 min calibration) → sleep-onset detection → alarm
```

Same IBIs also set `ColmiRingManager.latestHR = 60000/ibiMs` so the UI has a live BPM readout even between naps. See the "Colmi BLE Protocol" section for why we don't use raw PPG.

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

The app uses `Logger` (os_log) with subsystem `com.andreykats.nap-time` and categories: BLE, HRV, Sleep, Alarm.

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

Filter for the app's own Logger categories with: `grep -E "\[BLE\]|\[HRV\]|\[Sleep\]|\[Alarm\]"`

**Note:** `--console` blocks until the app terminates. Run it in the background (`&`) and `kill` the process when done, or redirect to a file.

## Colmi BLE Protocol (R02)

### Service / characteristics

| UUID | Role |
|---|---|
| `6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E` | Service (not advertised — name-based discovery only) |
| `6E400002-...` | RX (write commands here) |
| `6E400003-...` | TX (subscribe for notifications) |

All packets are exactly 16 bytes. Byte 15 is a checksum (sum of bytes 0..14 mod 256).

### Key commands

| Hex | Name | Notes |
|---|---|---|
| `69 01 01` | Start HR stream | Reports processed BPM at ~2/s |
| `69 0A 01` | **Start HRV stream** | Reports per-beat IBI (ms) at ~2/s — our primary data source |
| `69 0A 03` | **HRV CONTINUE (keep-alive)** | **Must be sent every ~10s** or the ring drops the stream after ~2 min |
| `6A ..` | Stop real-time | Used on disconnect |
| `A1 04` | Enable raw sensor stream | Low-rate diagnostic multiplex — NOT a 25 Hz PPG feed |
| `03` | Battery request |

### Critical findings from reverse-engineering

1. **Raw PPG is useless for real-time HRV.** The `A1 04` "raw data" command emits a multiplexed stream of SpO2 (`A1 01`), PPG waveform (`A1 02`), accelerometer (`A1 03`), and undocumented subtype (`A1 05`) at ~1 Hz **each**. This is a firmware-imposed cap, not a BLE limit — confirmed by [atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring) which ships a modded `R02_3.00.06_FasterRawValuesMOD.bin` specifically to lower that refresh timeout.

2. **The HRV command is the right data source.** `69 0A 01` gives ring-computed inter-beat intervals at the natural heartbeat rate (~2 Hz). Payload format (empirically reversed, not documented):
   ```
   byte  0    1    2    3-5    6-7           8-14  15
         69   0A   err  zeros  IBI (ms LE)   zeros checksum
   ```
   Warm-up packets have all zeros for ~30s after `start`; valid IBIs then flow steadily.

3. **HR (0x69 0x01) and HRV (0x69 0x0A) share one slot.** Sending `startHRV` after `startHR` kills the HR stream. We only use HRV; instantaneous BPM is derived per-beat from the IBI.

4. **Keep-alive is reading-type-specific.** The generic `1E 33` keep-alive works for the HR stream but NOT for HRV. HRV needs `69 0A 03` (CONTINUE) every 10s. Without it the ring silently stops emitting after ~2 min while still ACK'ing firmware pings (`9E EE`).

### Reference repos

- [tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client) — Python client, documents the 0x69 command enum
- [CitizenOneX/colmi_r06_fbp](https://github.com/CitizenOneX/colmi_r06_fbp) — Dart client, cleanest enum docs for subtypes
- [colmi.puxtril.com/commands](https://colmi.puxtril.com/commands/) — official-ish reverse-engineered command reference
- [atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring) — custom firmware + OTA flasher for the RF03 SoC

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
