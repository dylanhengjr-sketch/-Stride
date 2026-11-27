# Stride

Stride is a native iOS 17+ SwiftUI fitness tracker using Core Location, MapKit, Core Motion, SwiftData, and AVFoundation.

## Included functionality

- Running, walking, cycling, and hiking workout modes.
- Core Location route recording with GPS accuracy, timestamp, and movement filtering.
- Background location updates using `UIBackgroundModes=location`, `allowsBackgroundLocationUpdates`, and `CLBackgroundActivitySession` on iOS 17+.
- `CLServiceSession(authorization: .whenInUse)` on iOS 18+ while an active workout requires location access.
- Manual pause stops location and barometer updates; automatic pause retains lower-accuracy GPS recovery tracking.
- Distance, elapsed time, moving time, current/average pace and speed, elevation, and estimated calories.
- Automatic kilometre or mile splits, optional spoken split announcements, and persisted split history.
- Activity history, route maps, statistics, weekly/monthly distance goals, and system/light/dark appearance.
- Local SwiftData persistence, GPX import/export, and JSON activity backup/restore.

All data remains local to the device. No authentication, cloud database, advertising, analytics, or subscriptions are included.

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

`Stride/Info.plist` includes the `location` and `audio` background modes and the location usage descriptions. The app requests When In Use permission when a workout is started in the foreground. During an active workout it starts standard location updates, enables background updates, and retains a `CLBackgroundActivitySession` (iOS 17+). On iOS 18+, it also holds a When In Use `CLServiceSession`. These APIs support normal background/locked-screen recording; they do not guarantee operation after the user force-quits the app or if iOS terminates the process.

## Codemagic unsigned build

1. Push this directory to a GitHub repository.
2. Connect the repository to Codemagic.
3. Select workflow `ios-stride-build-test-ipa`.
4. The workflow installs XcodeGen if needed and regenerates the Xcode project from `project.yml`.
5. It runs `xcodebuild test` on an available iPhone simulator.
6. It archives the app with code signing disabled and packages `build/ipa/Stride-unsigned.ipa`.

The build does not require an Apple Developer Program membership or App Store Connect API key. The unsigned IPA must be signed for device installation, for example with Sideloadly and a free Apple Account. Free-account provisioning generally expires after seven days.

## Verification status

The project files have been statically inspected and Swift syntax parsing, YAML parsing, and Info.plist parsing have been performed in the available environment. No Xcode/iOS SDK is available here, so this archive has **not** been compiled with Xcode and XCTest has **not** been executed. Run the Codemagic workflow and resolve any actual compiler/test failures before relying on the app.
