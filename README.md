# Stride

Stride is a native iOS 17+ SwiftUI fitness tracker using Core Location, MapKit, Core Motion and SwiftData.

## Included functionality

- Running, walking, cycling, and hiking workout modes.
- Core Location route recording with GPS accuracy, timestamp, and movement filtering.
- Background location updates using `UIBackgroundModes=location`, `allowsBackgroundLocationUpdates`, and `CLBackgroundActivitySession` on iOS 17+.
- Manual pause stops location and barometer updates; automatic pause retains lower-accuracy GPS recovery tracking.
- Distance, elapsed time, moving time, current/average pace and speed, elevation, and estimated calories.
- Automatic kilometre or mile splits and persisted split history.
- Activity history, route maps, statistics, weekly/monthly distance goals, and system/light/dark appearance.
- Local SwiftData persistence, GPX import/export, and JSON activity backup/restore.

All data remains local to the device. No authentication, cloud database, advertising, analytics, or subscriptions are included.

## Persistence safeguards

- Settings are explicitly saved when changed because Stride uses a manually created SwiftData context.
- Failed queued track-point saves are retried periodically while the app process is active, as well as when subsequent tracking events request a flush.
- Workout deletion runs in a separate SwiftData context. If the deletion operation fails, that context is discarded so the active workout context is not mutated by a failed delete.
- Unit tests cover settings reloading through a fresh context, timed track-point retry, discard metric reset, and failed deletion followed by retry.

## Project structure

```text
Stride/
├── Stride.xcodeproj/
│   └── xcshareddata/xcschemes/Stride.xcscheme
├── Stride/
│   ├── App/
│   ├── Models/
│   ├── Services/
│   ├── Views/
│   ├── Resources/Assets.xcassets/
│   ├── Info.plist
│   └── StrideApp.swift
├── StrideTests/
├── Config/Stride.xcconfig
├── project.yml
├── codemagic.yaml
└── README.md
```

## Build configuration

- Xcode project: `Stride.xcodeproj`
- Shared scheme: `Stride`
- App target: `Stride`
- Unit test target: `StrideTests`
- Minimum deployment target: iOS 17.0
- Bundle identifier: `com.stride.tracker.app` (customise before signing if desired)
- Swift language mode: Swift 5
- XcodeGen specification: `project.yml`

## Background location configuration

`Stride/Info.plist` includes the `location` background mode and the location usage descriptions. The app requests When In Use permission when a workout is started in the foreground. During an active workout it starts standard location updates, enables background updates, and retains a `CLBackgroundActivitySession` (iOS 17+). This supports normal background/locked-screen recording; it does not guarantee operation after the user force-quits the app or if iOS terminates the process.

## Codemagic unsigned build

1. Push this directory to a GitHub repository.
2. Connect the repository to Codemagic.
3. Select workflow `ios-stride-build-test-ipa`.
4. The workflow installs XcodeGen if needed and regenerates the Xcode project from `project.yml`.
5. It runs `xcodebuild test` on an available iPhone simulator.
6. It archives the app with code signing disabled and packages `build/ipa/Stride-unsigned.ipa`.

The build does not require an Apple Developer Program membership or App Store Connect API key. The unsigned IPA must be signed for device installation, for example with Sideloadly and a free Apple Account. Free-account provisioning generally expires after seven days.

## Verification status

The repository's root GitHub Actions workflow (`.github/workflows/main.yml`) runs the XCTest suite on an iPhone simulator and builds the Release app for a generic physical iOS device on pushes to `main` and `fix/**` branches, and on pull requests targeting `main`. The build is unsigned; installing it on a physical iPhone still requires signing with an Apple account or a paid distribution certificate.

A passing CI run verifies the covered tests and build configuration. It does not prove the app is free of defects, and real-device GPS, background recording, barometer behavior, and installation should still be checked on an iPhone.
