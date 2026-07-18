# Internal Display Off

A tiny macOS menu bar app that hides a MacBook's built-in display when an external display is connected.

It is intentionally small: launch the app, and it dims the built-in display, places a black fullscreen cover over it, keeps the pointer on an external display, and leaves the external display usable. Use the menu bar item to restore the internal display or quit.

## What it does

- Checks that an external display is currently active.
- Finds the built-in MacBook display.
- Saves the current built-in display brightness.
- Sets the built-in display brightness to zero, trying DisplayServices first and falling back to IOKit.
- Temporarily moves the built-in display to the upper-right corner of the external display to reduce accidental pointer crossings.
- Places a black fullscreen window over the built-in display.
- Keeps the pointer from slipping into the built-in display space with an event-driven guard.
- Automatically restores the built-in display if the external display disconnects.
- Reapplies the cover and dimming shortly after the Mac wakes from sleep.
- Keeps a menu bar item available for restoring the display.
- Restores the cover, pointer guard, display arrangement, and display brightness when the app quits normally.

## Important limitations

The default mode does not remove the built-in display from the macOS display layout. That is deliberate: it avoids the crash and recovery risks associated with private display-disable APIs, especially on Apple Silicon.

The app refuses to hide the internal display unless an external display is active.

This project intentionally does not ship a hardware display-disconnect mode. Earlier experimental builds included one, but it was removed because it relied on private APIs that can fail or leave users in a hard-to-recover display state.

If the external display is unplugged while the built-in display is hidden, the app listens for the macOS display reconfiguration event and restores the built-in display automatically.

If the Mac wakes from sleep while the built-in display is hidden, the app waits briefly for display hardware to settle, then retries for several seconds until the external display is available before reapplying the dimming, cover, and pointer guard.

The pointer guard uses a `CGEventTap` at the HID event layer when macOS allows it, and falls back to `NSEvent` mouse monitors if the event tap cannot be created. The HID event tap can clamp pointer events before they leave the external display; the fallback is less reliable and mainly exists as a best-effort safety net.

If the event tap cannot be created because Accessibility permission has not been granted yet, the app keeps retrying in the background and switches to the HID event tap automatically as soon as permission is granted — no relaunch required. Use the menu bar item's "Open Accessibility Settings" command to jump straight to the permission list.

### Keeping the permission across rebuilds

By default `build.sh` signs the app ad-hoc. Ad-hoc signatures change their code hash on every build, so macOS treats each rebuild as a *different* app: the Accessibility toggle may still look ON, but the grant is stale and the pointer guard keeps reporting "Needs Pointer Permission".

Two ways to deal with it:

- **Quick unblock after a rebuild:** remove the app from System Settings ▸ Privacy & Security ▸ Accessibility with the "−" button (or run `tccutil reset Accessibility local.codex.InternalDisplayOff`), then relaunch and grant again.
- **Permanent fix:** run `./create-signing-identity.sh` once to create a stable self-signed code-signing identity. After that `build.sh` signs with it automatically, and the Accessibility grant survives future rebuilds — you only grant permission once.

When hiding the internal display, the app also saves the current display arrangement and moves the built-in display to the upper-right corner of the preferred external display for the current login session. Restoring the display or quitting the app normally restores the saved arrangement.

Brightness control uses private DisplayServices symbols when available because newer Apple Silicon display paths may reject older IOKit brightness calls. IOKit is still kept as a fallback for older systems and configurations.

## Why hard-disable is not the default

Earlier versions of this project experimented with private display-disable APIs. That was too risky for a public project because:

- private display APIs can fail or behave differently across Mac models
- `applicationWillTerminate:` is not called after crashes or force quits
- a disabled display may disappear from display discovery APIs, so restoration must rely on a cached ID
- dynamic stack arrays are unnecessary for display enumeration

The current app is a safer visual-off tool with an event-driven pointer guard. It is less "true off" than a display disconnect, but it avoids the most annoying daily issue without taking over the system display stack.

## Requirements

- macOS 12 or later
- Apple Command Line Tools or Xcode
- A MacBook with an external display connected

Depending on macOS privacy settings, the pointer guard may require Accessibility or Input Monitoring permission for the app. If the menu bar status says `Needs Pointer Permission`, grant the permission and quit/reopen the app.

## Build

```sh
./build.sh
```

The built app will be written to:

```text
dist/Internal Display Off.app
```

This repository currently ships source code, not a notarized binary release. To use it, clone the repository and run `./build.sh`.

## Run

Open the app from Finder, or run:

```sh
open "dist/Internal Display Off.app"
```

If macOS blocks the first launch because the app is unsigned or locally signed, right-click the app and choose **Open**.

## Menu bar status

- `Display Ready`: the built-in display is not hidden by the app.
- `Internal Hidden`: the black cover is active and brightness was lowered.
- `Internal Covered`: the black cover is active, but brightness control was not accepted by macOS.
- `Needs Pointer Permission`: the display cover is active, but macOS did not allow the pointer event tap. Grant Accessibility or Input Monitoring permission, then quit and reopen the app.

## Project layout

```text
Sources/InternalDisplayOff/main.m  App source
Resources/Info.plist              macOS app bundle metadata
Resources/AppIcon.icns            App icon
Resources/AppIconSource.png       Source image for the app icon
build.sh                          Build and ad-hoc sign script
```

## License

MIT
