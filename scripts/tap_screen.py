#!/usr/bin/env python3
"""
Helper for iPhone Mirroring interaction.
Converts iPhone phone-point coordinates to macOS screen coordinates.

Usage:
  # Take shadow-free screenshot
  python3 scripts/tap_screen.py screenshot [/tmp/screen.png]

  # Tap at iPhone phone-point coordinates (derived from SwiftUI layout)
  python3 scripts/tap_screen.py tap <phone_x> <phone_y>

  # Swipe between phone-point coordinates
  python3 scripts/tap_screen.py swipe <x1> <y1> <x2> <y2>

  # Type text into focused field
  python3 scripts/tap_screen.py type "hello world"

  # Navigation shortcuts
  python3 scripts/tap_screen.py home
  python3 scripts/tap_screen.py switcher
  python3 scripts/tap_screen.py spotlight

Coordinate transform (calibrated for iPhone 13 mini → 376x826 Mac window):
  pixel_x = phone_x * 1.9231 + 15.4
  pixel_y = phone_y * 1.9153 + 79.9
  screen_x = window_x + pixel_x / 2
  screen_y = window_y + pixel_y / 2
"""
import subprocess
import sys
import json
import time

INFO_FILE = "/tmp/iphone_mirror_info.json"

# Calibrated transform constants (iPhone 13 mini @ 376x826 Mac window)
# Derived from CalibrationView: two taps mapped phone points to screenshot pixels.
# If the device or window size changes, recalibrate using the Test tab.
SCALE_X = 1.9231
SCALE_Y = 1.9153
OFFSET_X = 15.4   # phone screen left edge in screenshot pixels
OFFSET_Y = 79.9   # phone screen top edge in screenshot pixels
MAC_SCALE = 2     # Retina backing scale


def get_window_info():
    """Get iPhone Mirroring window ID and position/size."""
    result = subprocess.run(
        ["swift", "-e", """
import CoreGraphics
let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in windowList {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    if owner.contains("iPhone Mirroring") {
        let wid = w["kCGWindowNumber"] as! Int
        let bounds = w["kCGWindowBounds"] as! [String: Any]
        print("\\(wid) \\(bounds["X"]!) \\(bounds["Y"]!) \\(bounds["Width"]!) \\(bounds["Height"]!)")
    }
}
"""],
        capture_output=True, text=True,
    )
    parts = result.stdout.strip().split()
    if len(parts) != 5:
        print("ERROR: iPhone Mirroring window not found", file=sys.stderr)
        sys.exit(1)

    info = {
        "window_id": int(parts[0]),
        "x": int(parts[1]),
        "y": int(parts[2]),
        "w": int(parts[3]),
        "h": int(parts[4]),
    }
    with open(INFO_FILE, "w") as f:
        json.dump(info, f)
    return info


def activate():
    """Bring iPhone Mirroring to front."""
    subprocess.run(
        ["osascript", "-e", 'tell application "iPhone Mirroring" to activate']
    )
    time.sleep(0.3)


def phone_to_screen(phone_x, phone_y, win_x, win_y):
    """Convert iPhone phone-point coordinates to macOS screen coordinates."""
    pixel_x = phone_x * SCALE_X + OFFSET_X
    pixel_y = phone_y * SCALE_Y + OFFSET_Y
    screen_x = win_x + pixel_x / MAC_SCALE
    screen_y = win_y + pixel_y / MAC_SCALE
    return screen_x, screen_y


def screenshot(output_path):
    """Take shadow-free screenshot of iPhone Mirroring window."""
    activate()
    info = get_window_info()
    subprocess.run(
        ["screencapture", "-x", "-o", f"-l{info['window_id']}", output_path],
        check=True,
    )
    print(json.dumps(info))


def load_info():
    """Load saved window info."""
    with open(INFO_FILE) as f:
        return json.load(f)


def tap(phone_x, phone_y):
    """Tap at iPhone phone-point coordinates."""
    info = load_info()
    screen_x, screen_y = phone_to_screen(phone_x, phone_y, info["x"], info["y"])
    activate()
    subprocess.run(["cliclick", f"c:{screen_x:.0f},{screen_y:.0f}"])
    print(f"Tapped screen ({screen_x:.0f}, {screen_y:.0f}) for phone ({phone_x}, {phone_y})")


def swipe(x1, y1, x2, y2):
    """Swipe between iPhone phone-point coordinates."""
    info = load_info()
    sx1, sy1 = phone_to_screen(x1, y1, info["x"], info["y"])
    sx2, sy2 = phone_to_screen(x2, y2, info["x"], info["y"])
    activate()
    subprocess.run(["cliclick", f"dd:{sx1:.0f},{sy1:.0f}", f"du:{sx2:.0f},{sy2:.0f}"])
    print(f"Swiped ({sx1:.0f},{sy1:.0f}) -> ({sx2:.0f},{sy2:.0f})")


def send_keys(cmd):
    """Send keyboard shortcut to iPhone Mirroring."""
    activate()
    if cmd == "home":
        subprocess.run(["cliclick", "kd:cmd", "t:1", "ku:cmd"])
    elif cmd == "switcher":
        subprocess.run(["cliclick", "kd:cmd", "t:2", "ku:cmd"])
    elif cmd == "spotlight":
        subprocess.run(["cliclick", "kd:cmd", "t:3", "ku:cmd"])
    print(f"Sent: {cmd}")


def type_text(text):
    """Type text into focused field."""
    activate()
    subprocess.run(["cliclick", f"t:{text}"])
    print(f"Typed: {text}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "screenshot":
        screenshot(sys.argv[2] if len(sys.argv) > 2 else "/tmp/device_screen.png")
    elif cmd == "tap":
        tap(float(sys.argv[2]), float(sys.argv[3]))
    elif cmd == "swipe":
        swipe(float(sys.argv[2]), float(sys.argv[3]),
              float(sys.argv[4]), float(sys.argv[5]))
    elif cmd in ("home", "switcher", "spotlight"):
        send_keys(cmd)
    elif cmd == "type":
        type_text(sys.argv[2])
    else:
        print(f"Unknown command: {cmd}")
