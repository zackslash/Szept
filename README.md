# Szept

Menu bar app for macOS that cleans up microphone audio using Apple's
AUSoundIsolation audio unit and sends the result to a virtual audio device.
Apps without built in noise suppression, such as Slack, can use that device
as their microphone.

## How it works

Input device -> AUSoundIsolation -> BlackHole -> call app

## Requirements

- macOS 14 or newer, Apple Silicon
- BlackHole 2ch, installed separately (GPL-3, not bundled)
- Swift 6 toolchain to build: Xcode 16 or newer, or Command Line Tools

## Installing BlackHole

With Homebrew:

    brew install --cask blackhole-2ch

Reboot after installing, or run sudo killall coreaudiod. Without Homebrew,
download the pkg from https://existential.audio, install it, then reboot.

## Install from a release

Download the zip from Releases, unzip it, and move Szept.app to
/Applications. The build is ad hoc signed (no Developer ID), so macOS
blocks it on first launch: open System Settings, go to Privacy and
Security, and click Open Anyway. Then approve the microphone prompt and
pick your interface as the input device in Settings.

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
4. Strength is a fixed choice: Gentle, Medium, or Max. There is no auto
   mode.
5. There is no software gain stage. Set levels on your interface or mixer.

## Known issues

- AUSoundIsolation is undocumented. It may change or stop working in a
  future macOS version. Where it is unavailable, audio passes through
  unprocessed.
- The input device and BlackHole run on unsynchronised clocks, so very long
  sessions can drift.
- The Control Center mic indicator and the Privacy and Security microphone
  list show a blank icon for Szept on macOS 26. Attribution itself works:
  the app is listed and the permission functions. Finder, the Dock, the app
  switcher and the About panel all show the icon. Tested without effect:
  icns only, a compiled asset catalog with and without a flat AppIcon
  stack, a resource fork custom icon, an unsigned build, and a verified
  bundle and registration. Menu bar only apps from other developers show
  their icons in the same lists, and signed apps such as Chrome have
  reported generic icons in privacy lists too, so this looks like a Tahoe
  icon pipeline quirk rather than a problem in this bundle.
- FaceTime blocks BlackHole.

## Credits

Fork of kocheck/Szept, MIT licence. BlackHole by Existential Audio, GPL-3,
installed separately and never bundled here.
