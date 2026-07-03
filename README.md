# Internal Display Off

A tiny macOS menu bar app that hides a MacBook's built-in display when an external display is connected.

It is intentionally small: launch the app, and it dims the built-in display, places a black fullscreen cover over it, and keeps the external display usable. Use the menu bar item to restore the internal display or quit.

## What it does

- Checks that an external display is currently active.
- Finds the built-in MacBook display.
- Saves the current built-in display brightness.
- Sets the built-in display brightness to zero.
- Places a black fullscreen window over the built-in display.
- Moves the pointer to an external display if needed.
- Keeps a menu bar item available for restoring the display.
- Restores the cover and brightness when the app quits normally.

## Important limitations

The default mode does not remove the built-in display from the macOS display layout. That is deliberate: it avoids the crash and recovery risks associated with private display-disable APIs, especially on Apple Silicon.

The app includes an **Experimental Hard Disable** menu action that calls `CGSConfigureDisplayEnabled`, a private macOS display configuration function. This is off the default path and requires a confirmation prompt.

Hard-disable mode has serious caveats:

- behavior may vary by macOS version and Mac model
- Apple Silicon support is not guaranteed
- a crash or force quit can prevent automatic restoration
- the app must keep the original display ID cached to restore reliably
- the app is not suitable for Mac App Store distribution
- if anything behaves oddly, rebooting should restore macOS' normal display state

The app refuses to hide or hard-disable the internal display unless an external display is active.

## Why hard-disable is not the default

Earlier versions of this project attempted to call the private display-disable API on launch. That was too risky for a public project because:

- private display APIs can fail or behave differently across Mac models
- `applicationWillTerminate:` is not called after crashes or force quits
- a disabled display may disappear from display discovery APIs, so restoration must rely on a cached ID
- dynamic stack arrays are unnecessary for display enumeration

The current default is a safer visual-off mode. It is less "true off" than a display disconnect, but it is recoverable and better suited for general use.

## Requirements

- macOS 12 or later
- Apple Command Line Tools or Xcode
- A MacBook with an external display connected

## Build

```sh
./build.sh
```

The built app will be written to:

```text
dist/Internal Display Off.app
```

## Run

Open the app from Finder, or run:

```sh
open "dist/Internal Display Off.app"
```

If macOS blocks the first launch because the app is unsigned or locally signed, right-click the app and choose **Open**.

## Project layout

```text
Sources/InternalDisplayOff/main.m  App source
Resources/Info.plist              macOS app bundle metadata
build.sh                          Build and ad-hoc sign script
```

## License

MIT
