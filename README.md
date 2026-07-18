# Internal Display Off

A tiny macOS menu bar app that hides a MacBook's built-in display while an external display is connected.

Launch it and it dims the built-in display, covers it with a black fullscreen window, and keeps the pointer from wandering onto it. Use the menu bar item to restore the display or quit.

## What it does

- Dims the built-in display to zero (DisplayServices, falling back to IOKit).
- Covers it with a black fullscreen window.
- Moves it to the upper-right of the external display so the pointer rarely crosses over, then restores the original arrangement afterwards.
- Clamps the pointer to the external display with a `CGEventTap`.
- Restores everything if the external display disconnects, and reapplies after the Mac wakes from sleep.

It refuses to hide the internal display unless an external display is active, so you cannot lock yourself out of a screen.

## Requirements

- macOS 12 or later
- Apple Command Line Tools or Xcode
- A MacBook with an external display connected

## Build and run

```sh
./build.sh
open "dist/Internal Display Off.app"
```

This repository ships source, not a notarized release. If macOS blocks the first launch, right-click the app and choose **Open**.

## Accessibility permission

The pointer guard needs Accessibility permission. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility — the menu bar item's **Open Accessibility Settings** command jumps straight there. The guard turns on automatically once granted; no relaunch needed.

**If the toggle is already ON but the status still says `Needs Pointer Permission`:** `build.sh` signs ad-hoc by default, and ad-hoc signatures change on every build, so macOS treats each rebuild as a different app and the old grant goes stale.

- One-off fix: remove the app from the Accessibility list with the "−" button, then relaunch and grant again.
- Permanent fix: run `./create-signing-identity.sh` once. `build.sh` then signs with a stable identity and the grant survives rebuilds.

## Menu bar status

- `Display Ready` — not hiding anything.
- `Internal Hidden` — cover active, brightness lowered.
- `Internal Covered` — cover active, but macOS rejected the brightness change.
- `Needs Pointer Permission` — cover active, but the pointer event tap was refused. See above.

## Why it does not truly disable the display

Earlier versions used private display-disable APIs to drop the built-in display from the macOS layout, and those were removed: they behave inconsistently across Mac models and can leave the display stack in a state that is hard to recover from. Covering and dimming is less "true off" than a hardware disconnect, but it is safe to quit, crash, or force quit at any point.

## License

MIT
