# Szept

Menu bar app for macOS that cleans up microphone audio using Apple's
AUSoundIsolation audio unit and sends the result to a virtual audio device.
Apps without built in noise suppression, such as Slack, can use that device
as their microphone.

## How it works

Input device -> AUSoundIsolation -> BlackHole -> call app

## Requirements

- macOS 14 or newer, Apple Silicon
- BlackHole, installed separately from https://existential.audio
- Swift 6 toolchain to build: Xcode 16 or newer, or Command Line Tools

## Build and run

Release build from the command line:

    swift build -c release

Or open the repository folder in Xcode, which reads Package.swift, and run
the Szept scheme. To get a launchable app bundle run:

    bash scripts/package.sh

Grant microphone access when prompted.

## Using it

1. Open Settings and pick your input device. Output defaults to the first
   BlackHole device found.
2. In your call app, set the microphone to BlackHole 2ch.
3. Turn off noise suppression in the call app. Two suppression layers
   stacked sound bad.
4. Auto adjust is off by default. Loud noise such as barking pushes
   isolation to maximum and parks it there. Use a fixed preset.
5. There is no software gain stage. Set levels on your interface or mixer.

## Known issues

- AUSoundIsolation is undocumented. It may change or stop working in a
  future macOS version. Where it is unavailable, audio passes through
  unprocessed.
- The input device and BlackHole run on unsynchronised clocks, so very long
  sessions can drift.
- FaceTime blocks BlackHole.

## Credits

Fork of kocheck/Szept, MIT licence. BlackHole by Existential Audio, GPL-3,
installed separately and never bundled here.
