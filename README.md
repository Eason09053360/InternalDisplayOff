# Internal Display Off

A tiny macOS menu bar app that soft-disconnects a MacBook's built-in display when an external display is connected.

It is intentionally small: launch the app, and it turns off the internal display. Use the menu bar item to restore the internal display or quit.

## What it does

- Checks that an external display is currently active.
- Finds the built-in MacBook display.
- Uses macOS display configuration APIs to disable the built-in display.
- Keeps a menu bar item available for restoring the display.
- Attempts to restore the built-in display automatically when the app quits.

## Important limitations

This app uses `CGSConfigureDisplayEnabled`, a private macOS display configuration function. That is the same class of approach used by display-management tools that expose display enable/disable controls, but it is not a public Apple API.

That means:

- behavior may vary by macOS version and Mac model
- the app is not suitable for Mac App Store distribution
- you should test carefully before relying on it in a production workflow
- if anything behaves oddly, unplugging/replugging the external display or rebooting should restore macOS' normal display state

The app refuses to turn off the internal display unless an external display is active, so you should not lose access to all screens through normal use.

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
