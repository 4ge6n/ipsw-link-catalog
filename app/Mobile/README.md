# IPSW Browser (iOS / iPadOS)

Reads the same catalog the Mac app does, and saves an image into the Files app.
It does not sync a folder or link anything: iOS has no folder for Finder to
restore from, and no way to keep a nine-gigabyte download running once the app
is put away. Fetching, resuming and checking against Apple's SHA-1 are the Mac
app's own code, compiled straight into this target.

## Building

The project is generated rather than checked in, so it never conflicts:

```bash
brew install xcodegen          # once
cd app/Mobile && xcodegen generate
open IPSWBrowser.xcodeproj
```

Signing is left to you: pick your team under Signing & Capabilities the first
time, and Xcode fills in the rest. Nothing here is tied to a particular account.

`project.yml` is the source of truth. Edit that, not the generated project.

## Where saved images go

The app's own Documents folder, which the Files app shows under IPSW Browser.
A transfer writes into `.incoming` beside it and is only moved into view once it
is whole, so a half-finished image is never mistaken for a saved one — and is
still there to carry on from.

## What it does not do

Downloads stop when the app is put into the background; iOS ends them. There is
no daily schedule, and nothing is deleted to make room.
