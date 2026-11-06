# Cutscene

A native macOS screen recorder for developer demos: record a display, window
or area with your camera and mic, and export a finished video with auto-zoom,
a smoothed cursor, click effects and a styled background. Built in-house for
the DevRel team; no subscription, no account.

## Install

You need macOS 15+ and the Xcode Command Line Tools (`xcode-select --install`).
Ask Marouane for access to this private repo if you don't have it yet.

```bash
git clone git@github.com:MarouaneKhoukh/cutscene.git
cd cutscene
make dev-cert   # once; asks for your Mac password to trust a local signing cert
make install    # builds and puts Cutscene.app in /Applications, then launches it
```

The first build takes a few minutes. To update later: `git pull && make install`.

## Test it

1. Cutscene lives in the menu bar (◎ icon, no Dock icon). The recorder window
   opens at launch; ⇧⌘R brings it back.
2. Choose **Display**, turn on the microphone, press **Record**. Allow Screen
   Recording when macOS asks, then quit and relaunch Cutscene once.
3. The window hides and a recording pill appears. Click and type a bit, then
   press **Stop**.
4. The editor opens with your take. Trim if you like and press **Export video**
   (⌘E). The MP4 is in `~/Movies/Cutscene/Exports`.

Also try: a **Window** or **Area** recording, the camera bubble, and the
teleprompter (⇧⌘T). Settings (⌘,) has the default preset and folders.

Stuck on permissions? Check System Settings › Privacy & Security › Screen &
System Audio Recording, or run
`tccutil reset ScreenCapture app.cutscene.Cutscene` and relaunch.

## Feedback

Open an issue in this repo with what you recorded, what you expected and what
you got. Crashes and odd exports are the most useful reports.

## More

Project background, status, architecture and the full `make` reference are in
[`docs/OVERVIEW.md`](docs/OVERVIEW.md); the design is in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and the task list in
[`docs/PLAN.md`](docs/PLAN.md).
