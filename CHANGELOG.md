# Changelog

## Final build

- Removed spoken split announcements, their Settings preference, and the audio background mode. Automatic split calculation and persisted split history remain.

- Finishing a workout now reports persistence failures: the session stays paused with a retry banner instead of reporting success. `finishDate` uses the clamped clock value.
- Pause, resume and lifecycle (background/inactive) saves now surface a status banner when persistence fails, instead of failing silently.
- `LocalDatabaseStore.updateActivity` returns a `Bool` (`@discardableResult`).
- GPX import no longer treats elapsed time as moving time; moving time, average speed and pace are left unavailable. Imported titles are prefixed "Imported GPX -".
- GPX export is a single implementation in `LocalDatabaseStore.makeGPXData` (XML-escaped title) and reuses one `ISO8601DateFormatter` for all track points.
- Barometric altitude is anchored to GPS only when vertical accuracy is 25 m or better; otherwise a neutral baseline is used. The barometer stops when a manual pause turns off location updates.
- Weekly/monthly distance goals use half-open `[start, end)` date intervals.
- Added tests: save-failure retry on finish, banner on pause/lifecycle save failure, barometer anchor threshold (25 m vs 26 m), GPX import moving-time and title assertions.

- The "could not be saved" banner now clears automatically once a later save succeeds, instead of staying on screen after recovery.
- Fixed a compile error: `ActivityDetailView` called `store.makeGPXData` without having a `store`. The store is now injected from `ActivityHistoryView`.
- Activities with distance and elapsed time but no moving-time data (chiefly imported GPX tracks) now show "—" instead of zero or a pace placeholder: moving time and average pace in History; moving time, average pace and average speed in Detail. They are excluded from the Total Moving Time statistic, with an explanatory footer. The check is heuristic (`hasUnavailableMovingMetrics`), not an explicit import flag. Stored values are unchanged, so no data migration is needed.
- Added tests: banner clears after a failed pause save recovers, resume after a failed pause save, failed resume save recovery, and the unavailable-metrics flag for imported and zero-distance activities.

## Previous archive

- Removed recursive `advanceClocks()` re-entry during automatic pause by separating the pause-state transition from the public pause method.
- Manual pause now stops standard location updates, disables background location updates, and stops the barometer; automatic pause retains low-power recovery location updates.
- Added iOS 17+ `CLBackgroundActivitySession` and iOS 18+ `CLServiceSession` lifecycle handling for active workouts.
- Corrected Swift language mode to `5.0` in the XcodeGen specification, xcconfig, and checked-in Xcode project.
- Removed the development-signing configuration from Codemagic and hardened simulator discovery and unsigned IPA packaging.
- Corrected the route-speed expectation in the moving-time regression test.
- Implemented persisted kilometre/mile splits.
- Added GPX import/export and JSON backup/restore, including workout points, splits, and app settings.
- Added weekly/monthly distance goals, progress indicators, activity-distance chart, and system/light/dark appearance selection.
- Added average speed to the live workout metrics and supplied a 1024x1024 app icon placeholder.
- Added regression tests for split persistence and GPX/JSON transfer.

## Verification limits

Swift syntax parsing, YAML parsing, Info.plist parsing, and asset catalog JSON parsing were performed in the available Linux environment. Xcode compilation and XCTest execution were not available and have not been performed.
