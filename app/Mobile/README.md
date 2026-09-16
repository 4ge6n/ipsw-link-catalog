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

`project.yml` is the source of truth. Edit that, not the generated project. The
icon is drawn by the Mac app's own `DrawIcon.swift` on the first build, so
neither it nor the generated project and Info.plist are checked in.

## On iPad

The catalog is a split view: builds on the left, the devices of the one that is
chosen on the right. A phone collapses that to the same list pushing a screen,
which is what a split view does on its own at that width.

## Where saved images go

The app's own Documents folder, which the Files app shows under IPSW Browser.
A transfer writes into `.incoming` beside it and is only moved into view once it
is whole, so a half-finished image is never mistaken for a saved one — and is
still there to carry on from.

## Transfers

A background URLSession, so a transfer carries on when the app is put away and
finishes even if iOS closes the app in the meantime; the system then starts the
app again to hand it over. What arrives is checked against Apple's SHA-1 before
it is called saved.

**This cannot be tested in the Simulator.** The background session's connection
to `nsurlsessiond` is refused there — `failed to create a background
NSURLSessionDownloadTask, as remote session is unavailable` — and every transfer
ends immediately as an unknown error. Run it on a device to see it work.

## What it does not do

There is no daily schedule, and nothing is deleted to make room. A transfer is
refused before it starts if the image will not fit.
