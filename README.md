# Szept

Menu bar app for macOS that removes background noise from microphone audio
using Apple's AUSoundIsolation audio unit and sends the result to a virtual
device. Apps without their own noise suppression, such as Slack, use that
device as their microphone.

Input device -> AUSoundIsolation -> BlackHole -> call app

## Requirements

- macOS 14 or newer, Apple Silicon
- BlackHole 2ch, installed separately (GPL-3, not bundled)
- Swift 6 toolchain: Xcode 16 or newer, or Command Line Tools

## Installing BlackHole

    brew install --cask blackhole-2ch

Reboot after installing, or run sudo killall coreaudiod. Without Homebrew,
install the pkg from https://existential.audio and reboot.

## Install from a release

Unzip the download and move Szept.app to /Applications. The build is ad
hoc signed, so on first launch approve it under System Settings, Privacy
and Security. Approve the microphone prompt, then pick your input device
in Settings.

## Build and run

    swift build -c release
    bash scripts/package.sh

Or open the folder in Xcode and run the Szept scheme. Grant microphone
access when prompted.

## Using it

1. Settings: pick your input device. Output defaults to the first
   BlackHole device.
2. Call app: microphone set to BlackHole 2ch, its own noise suppression
   off.
3. Strength is a fixed choice: Gentle, Medium, or Max.

Hotkeys: ctrl+opt+N start or stop, ctrl+opt+C cycle clarity, ctrl+opt+[
and ctrl+opt+] strength, ctrl+opt+B hold to bypass. Stream Deck and
scripts can open szept://toggle, szept://clarity, szept://strength, and
szept://bypass instead.

## Known issues

- AUSoundIsolation is undocumented and may change or stop working in a
  future macOS version. Where it is unavailable, audio passes through
  unprocessed.
- The input device and BlackHole run on unsynchronised clocks, so very
  long sessions can drift.
- On macOS 26 the Control Center mic indicator and the microphone
  privacy list show a blank icon. Cosmetic, appears to be a Tahoe quirk
  rather than a problem in this bundle.
- FaceTime blocks BlackHole.

## Credits

Fork of kocheck/Szept, MIT licence. BlackHole by Existential Audio,
GPL-3, installed separately and never bundled here.
