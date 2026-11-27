import Foundation
import Combine
import CoreLocation

enum SessionState: Equatable {
    case idle
    case recording
    case paused(isAutomatic: Bool)

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var isAutoPaused: Bool {
        if case .paused(let isAutomatic) = self { return isAutomatic }
        return false
    }
}

@MainActor
final class WorkoutSessionController: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published var selectedActivityType: ActivityType = .running
    @Published private(set) var totalDistanceMeters: Double = 0
    @Published private(set) var elapsedTimeSeconds: TimeInterval = 0
    @Published private(set) var movingTimeSeconds: TimeInterval = 0
    @Published private(set) var currentSpeedMPS: Double = 0
    @Published private(set) var averageSpeedMPS: Double = 0
    @Published private(set) var maxSpeedMPS: Double = 0
    @Published private(set) var currentPaceSecPerKm: Double?
    @Published private(set) var averagePaceSecPerKm: Double?
    @Published private(set) var elevationGainMeters: Double = 0
    @Published private(set) var elevationLossMeters: Double = 0
    @Published private(set) var activeElevationSource: ElevationSource = .unknown
    @Published private(set) var estimatedCalories: Double = 0
    @Published private(set) var acceptedPointCount: Int = 0
    @Published private(set) var rejectedPointCount: Int = 0
    @Published private(set) var statusBanner: String?
    /// The persistence-failure message currently shown in `statusBanner`, if any.
    /// Tracked so it can be cleared once a later save succeeds.
    private var persistenceFailureBanner: String?
    @Published private(set) var persistenceError: String?

    private let locationService: LocationManagerService
    private let store: LocalDatabaseStore
    private let settings: AppSettings
    /// False in deterministic tests, where time is advanced explicitly.
    private let usesUITicker: Bool
    private let filterEngine = GPSFilterEngine()

    private var activeActivity: WorkoutActivity?
    private var uiTicker: Timer?
    private var sessionStartDate: Date?
    private var lastClockUpdateDate: Date?

    private var stationaryDurationSeconds: TimeInterval = 0
    private var lastConfirmedStationaryDate: Date?
    private var lastConfirmedMovingDate: Date?
    private var activeMovingSpeedMPS: Double = 0
    private var isAutoResumeMovementConfirmed: Bool = false
    private var autoResumeConfirmedSinceDate: Date?
    private var lastAutoResumeConfirmationDate: Date?
    private var autoResumeMovingDurationSeconds: TimeInterval = 0

    private var needsSegmentBreak: Bool = false
    private var pendingStartAfterPermission: Bool = false
    private var pendingResumeAfterPermission: Bool = false

    private var barometerAnchorAltitudeMeters: Double?
    private var elevationTracker = ElevationTracker()
    private var splitProgressMeters: Double = 0
    private var splitProgressSeconds: TimeInterval = 0
    private var lastSplitMovingTimeSeconds: TimeInterval = 0
    private var splitDistanceMetersForWorkout: Double = 1_000
    private var completedSplitCount: Int = 0

    private var cancellables = Set<AnyCancellable>()

    init(
        locationService: LocationManagerService,
        store: LocalDatabaseStore,
        settings: AppSettings,
        usesUITicker: Bool = true
    ) {
        self.locationService = locationService
        self.store = store
        self.settings = settings
        self.usesUITicker = usesUITicker
        bindLocationCallbacks()
        bindPersistenceErrors()
    }

    var currentStationaryDurationSeconds: TimeInterval {
        stationaryDurationSeconds
    }

    var currentAutoResumeMovingDurationSeconds: TimeInterval {
        autoResumeMovingDurationSeconds
    }

    var currentFilterMovementState: GPSMovementState {
        filterEngine.movementState
    }

    var activeRoutePoints: [TrackPoint] {
        (activeActivity?.trackPoints ?? [])
            .filter(\.isAccepted)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func bindPersistenceErrors() {
        store.$lastSaveError
            .receive(on: RunLoop.main)
            .sink { [weak self] errorMsg in
                if let errorMsg {
                    self?.persistenceError = "Storage warning: \(errorMsg)"
                } else {
                    self?.persistenceError = nil
                    // Check the store's current value: this delivery is asynchronous,
                    // so a newer failure may already have occurred.
                    if self?.store.lastSaveError == nil {
                        self?.clearPersistenceFailureBannerIfRecovered()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func bindLocationCallbacks() {
        locationService.onLocationReceived = { [weak self] location, baroAlt, isBaroActive in
            self?.handleIncomingLocation(
                location,
                barometricRelativeAltitude: baroAlt,
                isBarometerActive: isBaroActive
            )
        }
        locationService.onAuthorizationChanged = { [weak self] status in
            guard let self else { return }
            if self.pendingStartAfterPermission {
                self.pendingStartAfterPermission = false
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    self.beginWorkoutSession(now: Date())
                } else if status == .denied || status == .restricted {
                    self.statusBanner = "Location permission denied. Enable When In Use access in Settings to record."
                }
            } else if self.pendingResumeAfterPermission {
                self.pendingResumeAfterPermission = false
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    self.completeResumeAfterAuthorization(now: Date())
                } else if status == .denied || status == .restricted {
                    self.statusBanner = "Location permission denied. Enable When In Use access in Settings to resume."
                }
            } else if status == .denied || status == .restricted {
                self.statusBanner = "Location permission is required to record GPS workouts."
            }
        }
    }

    func requestStartWorkout(now: Date = Date()) {
        guard state == .idle else { return }

        switch locationService.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            statusBanner = nil
            beginWorkoutSession(now: now)
        case .notDetermined:
            pendingStartAfterPermission = true
            statusBanner = "Requesting When In Use location permission..."
            locationService.requestWhenInUseAuthorization()
        case .denied, .restricted:
            statusBanner = "Location access is turned off. Allow When In Use in iPhone Settings to start a workout."
        @unknown default:
            statusBanner = "Unable to verify location permission."
        }
    }

    func beginWorkoutSession(now: Date) {
        let title = "\(selectedActivityType.displayName) - \(now.formatted(date: .abbreviated, time: .shortened))"
        let activity = store.createActivity(title: title, activityType: selectedActivityType, startDate: now)

        activeActivity = activity
        sessionStartDate = now
        lastClockUpdateDate = now
        stationaryDurationSeconds = 0
        lastConfirmedStationaryDate = nil
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0
        isAutoResumeMovementConfirmed = false
        autoResumeConfirmedSinceDate = nil
        lastAutoResumeConfirmationDate = nil
        autoResumeMovingDurationSeconds = 0
        needsSegmentBreak = false
        splitProgressMeters = 0
        splitProgressSeconds = 0
        lastSplitMovingTimeSeconds = 0
        splitDistanceMetersForWorkout = settings.distanceUnitKilometers ? 1_000.0 : 1_609.344
        completedSplitCount = 0

        totalDistanceMeters = 0
        elapsedTimeSeconds = 0
        movingTimeSeconds = 0
        currentSpeedMPS = 0
        averageSpeedMPS = 0
        maxSpeedMPS = 0
        currentPaceSecPerKm = nil
        averagePaceSecPerKm = nil
        elevationGainMeters = 0
        elevationLossMeters = 0
        activeElevationSource = .unknown
        estimatedCalories = 0
        acceptedPointCount = 0
        rejectedPointCount = 0

        barometerAnchorAltitudeMeters = nil
        elevationTracker = ElevationTracker()

        filterEngine.reset()
        locationService.restoreBarometricOffset(meters: nil)

        state = .recording
        startTicker()
        locationService.startActiveTracking(
            for: selectedActivityType,
            useBarometer: settings.useBarometerWhenAvailable
        )
    }

    func restoreInProgressWorkoutIfAvailable(now: Date = Date()) {
        guard state == .idle, let existing = store.fetchInProgressActivity() else { return }

        selectedActivityType = existing.activityType
        activeActivity = existing
        sessionStartDate = existing.startDate
        lastClockUpdateDate = now

        let sortedPoints = existing.trackPoints.sorted { $0.timestamp < $1.timestamp }
        acceptedPointCount = sortedPoints.filter(\.isAccepted).count
        rejectedPointCount = sortedPoints.filter { !$0.isAccepted && !$0.isSegmentBreak }.count

        totalDistanceMeters = existing.totalDistanceMeters
        movingTimeSeconds = existing.movingTimeSeconds
        completedSplitCount = existing.splits.count
        splitDistanceMetersForWorkout = existing.splits.last?.distanceMeters
            ?? (settings.distanceUnitKilometers ? 1_000.0 : 1_609.344)
        splitProgressMeters = max(0, existing.totalDistanceMeters - existing.splits.reduce(0) { $0 + $1.distanceMeters })
        splitProgressSeconds = max(0, existing.movingTimeSeconds - existing.splits.reduce(0) { $0 + $1.durationSeconds })
        lastSplitMovingTimeSeconds = existing.movingTimeSeconds
        elapsedTimeSeconds = max(existing.elapsedTimeSeconds, now.timeIntervalSince(existing.startDate))
        maxSpeedMPS = existing.maxSpeedMPS
        elevationGainMeters = existing.elevationGainMeters
        elevationLossMeters = existing.elevationLossMeters
        activeElevationSource = existing.elevationSource
        estimatedCalories = existing.estimatedCalories
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0

        elevationTracker = ElevationTracker(
            initialGainMeters: existing.elevationGainMeters,
            initialLossMeters: existing.elevationLossMeters
        )
        if let firstBaro = sortedPoints.first(where: { $0.isAccepted && $0.elevationSource == .barometer })?.normalisedElevationMeters {
            barometerAnchorAltitudeMeters = firstBaro
        }

        let lastReferenceDate = sortedPoints.last?.timestamp ?? existing.lastUpdatedDate
        let gapSinceLastActivity = now.timeIntervalSince(lastReferenceDate)
        let hadInterruptionGap = gapSinceLastActivity >= AppConfig.recoveryInterruptionThresholdSeconds

        if hadInterruptionGap {
            filterEngine.reset()
            needsSegmentBreak = true
        } else {
            let lastAccepted = sortedPoints.last(where: \.isAccepted)?.clLocation
            filterEngine.seed(lastLocation: lastAccepted)
            needsSegmentBreak = false
        }

        let lastBaro = sortedPoints.last(where: { $0.barometricRelativeAltitude != nil })?.barometricRelativeAltitude
        locationService.restoreBarometricOffset(meters: lastBaro)

        averageSpeedMPS = WorkoutCalculations.speedMPS(distanceMeters: totalDistanceMeters, movingTimeSeconds: movingTimeSeconds)
        averagePaceSecPerKm = WorkoutCalculations.paceSecPerKm(distanceMeters: totalDistanceMeters, movingTimeSeconds: movingTimeSeconds)

        switch existing.status {
        case .pausedAuto, .pausedManual:
            existing.status = .pausedManual
            state = .paused(isAutomatic: false)
            stationaryDurationSeconds = 0
            lastConfirmedStationaryDate = nil
            isAutoResumeMovementConfirmed = false
            autoResumeConfirmedSinceDate = nil
            lastAutoResumeConfirmationDate = nil
            autoResumeMovingDurationSeconds = 0
            statusBanner = hadInterruptionGap
                ? "Restored paused workout after interruption — tap Resume to restart GPS"
                : "Restored paused workout — tap Resume to restart GPS"
            startTicker()
        case .recording:
            if locationService.isAuthorizedForWorkout {
                state = .recording
                statusBanner = hadInterruptionGap
                    ? "Restored active workout after interruption"
                    : "Restored active workout"
                startTicker()
                locationService.startActiveTracking(
                    for: selectedActivityType,
                    useBarometer: settings.useBarometerWhenAvailable
                )
            } else {
                existing.status = .pausedManual
                state = .paused(isAutomatic: false)
                statusBanner = "Restored workout paused — grant location permission to resume"
                startTicker()
            }
        case .completed, .discarded:
            activeActivity = nil
            state = .idle
        }
    }

    func pauseWorkout(automatic: Bool, now: Date = Date()) {
        guard state == .recording else { return }
        advanceClocks(to: now)
        // advanceClocks may itself trigger automatic pause at this timestamp.
        // Do not apply a second pause transition if that happened.
        guard state == .recording else { return }
        transitionToPaused(automatic: automatic, now: max(lastClockUpdateDate ?? now, now))
    }

    private func transitionToPaused(automatic: Bool, now: Date) {
        guard state == .recording else { return }
        elevationTracker.commitActiveSeries()
        state = .paused(isAutomatic: automatic)
        currentSpeedMPS = 0
        currentPaceSecPerKm = nil
        activeMovingSpeedMPS = 0
        stationaryDurationSeconds = 0
        lastConfirmedStationaryDate = nil
        isAutoResumeMovementConfirmed = false
        autoResumeConfirmedSinceDate = nil
        lastAutoResumeConfirmationDate = nil
        autoResumeMovingDurationSeconds = 0
        statusBanner = automatic ? "Auto-paused while stationary" : "Workout paused"

        if let activeActivity {
            activeActivity.status = automatic ? .pausedAuto : .pausedManual
            syncSummaryMetrics(to: activeActivity)
            persistActivity(
                activeActivity,
                flushPoints: true,
                now: now,
                failureMessage: "Workout paused, but progress could not be saved. Check device storage."
            )
        }
        locationService.applyPauseMode(isAutomatic: automatic, activityType: selectedActivityType)
    }

    func resumeWorkout(now: Date = Date()) {
        guard case .paused = state else { return }

        switch locationService.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            completeResumeAfterAuthorization(now: now)
        case .notDetermined:
            pendingResumeAfterPermission = true
            statusBanner = "Requesting When In Use location permission..."
            locationService.requestWhenInUseAuthorization()
        case .denied, .restricted:
            statusBanner = "Location access is turned off. Allow When In Use in iPhone Settings to resume."
        @unknown default:
            statusBanner = "Unable to verify location permission."
        }
    }

    private func completeResumeAfterAuthorization(now: Date) {
        guard case .paused = state else { return }

        let gpsReady = locationService.ensureActiveSessionForResume(
            activityType: selectedActivityType,
            useBarometer: settings.useBarometerWhenAvailable
        )
        guard gpsReady else {
            statusBanner = locationService.lastErrorMessage ?? "Cannot resume without location permission."
            return
        }

        let effectiveNow = max(lastClockUpdateDate ?? now, now)
        lastClockUpdateDate = effectiveNow

        stationaryDurationSeconds = 0
        lastConfirmedStationaryDate = nil
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0
        isAutoResumeMovementConfirmed = false
        autoResumeConfirmedSinceDate = nil
        lastAutoResumeConfirmationDate = nil
        autoResumeMovingDurationSeconds = 0
        needsSegmentBreak = true
        filterEngine.reset()
        elevationTracker.commitActiveSeries()
        state = .recording
        statusBanner = nil
        startTicker()

        if let activeActivity {
            activeActivity.status = .recording
            syncSummaryMetrics(to: activeActivity)
            persistActivity(
                activeActivity,
                flushPoints: true,
                now: effectiveNow,
                failureMessage: "Workout resumed, but progress could not be saved. Check device storage."
            )
        }
    }

    func finishWorkout(now: Date = Date()) {
        guard state != .idle, let activity = activeActivity else { return }
        advanceClocks(to: now)
        elevationTracker.commitActiveSeries()
        stopTicker()
        locationService.stopActiveTracking()

        // advanceClocks clamps time to the last accepted clock value. Use that
        // same timestamp for the persisted finish date and save operation.
        let effectiveFinishDate = lastClockUpdateDate ?? now
        activity.status = .completed
        activity.finishDate = effectiveFinishDate
        syncSummaryMetrics(to: activity)

        guard store.updateActivity(activity, flushPoints: true, now: effectiveFinishDate) else {
            // Keep the activity attached to the session so the user can retry
            // finishing; do not report success or discard the in-memory data.
            activity.status = .pausedManual
            activity.finishDate = nil
            state = .paused(isAutomatic: false)
            statusBanner = "Workout could not be saved. Check storage and tap Finish to retry."
            return
        }

        activeActivity = nil
        sessionStartDate = nil
        lastClockUpdateDate = nil
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0
        needsSegmentBreak = false
        state = .idle
        statusBanner = "Workout saved"
    }

    func discardWorkout(now: Date = Date()) {
        guard state != .idle else { return }

        if let activity = activeActivity,
           !store.deleteActivity(activity, now: now) {
            let failureMessage = "Workout could not be discarded. Check storage and try again."
            statusBanner = failureMessage
            persistenceFailureBanner = failureMessage
            return
        }

        pendingStartAfterPermission = false
        pendingResumeAfterPermission = false
        needsSegmentBreak = false
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0
        stopTicker()
        locationService.stopActiveTracking()

        activeActivity = nil
        sessionStartDate = nil
        lastClockUpdateDate = nil
        state = .idle
        resetLiveMetricsAfterDiscard()
        clearPersistenceFailureBannerIfRecovered()
        statusBanner = "Workout discarded"
    }

    private func resetLiveMetricsAfterDiscard() {
        totalDistanceMeters = 0
        elapsedTimeSeconds = 0
        movingTimeSeconds = 0
        currentSpeedMPS = 0
        averageSpeedMPS = 0
        maxSpeedMPS = 0
        currentPaceSecPerKm = nil
        averagePaceSecPerKm = nil
        elevationGainMeters = 0
        elevationLossMeters = 0
        activeElevationSource = .unknown
        estimatedCalories = 0
        acceptedPointCount = 0
        rejectedPointCount = 0

        stationaryDurationSeconds = 0
        lastConfirmedStationaryDate = nil
        lastConfirmedMovingDate = nil
        activeMovingSpeedMPS = 0
        isAutoResumeMovementConfirmed = false
        autoResumeConfirmedSinceDate = nil
        lastAutoResumeConfirmationDate = nil
        autoResumeMovingDurationSeconds = 0
        barometerAnchorAltitudeMeters = nil
        elevationTracker = ElevationTracker()
        filterEngine.reset()

        splitProgressMeters = 0
        splitProgressSeconds = 0
        lastSplitMovingTimeSeconds = 0
        completedSplitCount = 0
    }

    func handleLifecycleTransition(isBackgroundOrInactive: Bool, now: Date = Date()) {
        guard state != .idle else { return }
        advanceClocks(to: now)
        if let activeActivity {
            syncSummaryMetrics(to: activeActivity)
            persistActivity(
                activeActivity,
                flushPoints: isBackgroundOrInactive,
                now: now,
                failureMessage: "Progress could not be saved. Check device storage."
            )
        }
    }

    /// Saves the activity and surfaces a banner if persistence fails, so the
    /// user is never silently recording into a store that is not saving.
    @discardableResult
    private func persistActivity(
        _ activity: WorkoutActivity,
        flushPoints: Bool,
        now: Date,
        failureMessage: String
    ) -> Bool {
        let saved = store.updateActivity(activity, flushPoints: flushPoints, now: now)
        if saved {
            clearPersistenceFailureBannerIfRecovered()
        } else {
            statusBanner = failureMessage
            persistenceFailureBanner = failureMessage
        }
        return saved
    }

    /// Removes a stale "could not be saved" banner once persistence has recovered.
    /// Any other banner that replaced it in the meantime is left untouched.
    private func clearPersistenceFailureBannerIfRecovered() {
        guard let failure = persistenceFailureBanner else { return }
        if statusBanner == failure {
            statusBanner = nil
        }
        persistenceFailureBanner = nil
    }

    private func startTicker() {
        stopTicker()
        guard usesUITicker else { return }
        uiTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.state != .idle else {
                    self.stopTicker()
                    return
                }
                self.advanceClocks(to: Date())
            }
        }
    }

    private func stopTicker() {
        uiTicker?.invalidate()
        uiTicker = nil
    }

    private func overlapDuration(
        intervalStart: Date,
        intervalEnd: Date,
        windowStart: Date,
        windowEnd: Date
    ) -> TimeInterval {
        let start = max(intervalStart, windowStart)
        let end = min(intervalEnd, windowEnd)
        return max(0, end.timeIntervalSince(start))
    }

    func advanceClocks(to now: Date) {
        guard let start = sessionStartDate else { return }

        let prevClock = lastClockUpdateDate ?? now
        let effectiveNow = max(prevClock, now)
        lastClockUpdateDate = effectiveNow

        elapsedTimeSeconds = max(elapsedTimeSeconds, max(0, effectiveNow.timeIntervalSince(start)))

        if state == .recording {
            if filterEngine.movementState == .confirmedMoving && activeMovingSpeedMPS > 0,
               let lastMoving = lastConfirmedMovingDate {
                let windowEnd = lastMoving.addingTimeInterval(AppConfig.activeMovementSignalMaxAgeSeconds)
                let freshMovingDt = overlapDuration(
                    intervalStart: prevClock,
                    intervalEnd: effectiveNow,
                    windowStart: lastMoving,
                    windowEnd: windowEnd
                )
                movingTimeSeconds += freshMovingDt
            }
            estimatedCalories = WorkoutCalculations.estimateCalories(
                activityType: selectedActivityType,
                movingTimeSeconds: movingTimeSeconds,
                weightKg: settings.userWeightKg
            )
            averageSpeedMPS = WorkoutCalculations.speedMPS(
                distanceMeters: totalDistanceMeters,
                movingTimeSeconds: movingTimeSeconds
            )
            averagePaceSecPerKm = WorkoutCalculations.paceSecPerKm(
                distanceMeters: totalDistanceMeters,
                movingTimeSeconds: movingTimeSeconds
            )

            if settings.autoPauseEnabled && filterEngine.movementState == .confirmedStationary,
               let lastStationary = lastConfirmedStationaryDate {
                let windowEnd = lastStationary.addingTimeInterval(AppConfig.stationarySignalMaxAgeSeconds)
                let clockGap = effectiveNow.timeIntervalSince(prevClock)
                let freshStationaryDt = clockGap <= AppConfig.stationarySignalMaxAgeSeconds
                    ? overlapDuration(
                        intervalStart: prevClock,
                        intervalEnd: effectiveNow,
                        windowStart: lastStationary,
                        windowEnd: windowEnd
                    )
                    : 0
                stationaryDurationSeconds += freshStationaryDt
                if stationaryDurationSeconds >= AppConfig.defaultAutoPauseGracePeriod {
                    // Use the internal transition: calling pauseWorkout here would
                    // re-enter advanceClocks and recursively trigger auto-pause.
                    transitionToPaused(automatic: true, now: effectiveNow)
                }
            }
        } else if case .paused(let isAutomatic) = state {
            if isAutomatic && settings.autoPauseEnabled && isAutoResumeMovementConfirmed {
                if let lastConf = lastAutoResumeConfirmationDate,
                   let confirmedSince = autoResumeConfirmedSinceDate,
                   effectiveNow.timeIntervalSince(lastConf) <= AppConfig.autoResumeSignalMaxAgeSeconds {
                    let windowEnd = lastConf.addingTimeInterval(AppConfig.autoResumeSignalMaxAgeSeconds)
                    let validDt = overlapDuration(
                        intervalStart: max(prevClock, confirmedSince),
                        intervalEnd: effectiveNow,
                        windowStart: confirmedSince,
                        windowEnd: windowEnd
                    )
                    autoResumeMovingDurationSeconds += validDt
                } else {
                    isAutoResumeMovementConfirmed = false
                    autoResumeConfirmedSinceDate = nil
                    lastAutoResumeConfirmationDate = nil
                    autoResumeMovingDurationSeconds = 0
                }
            }
            evaluateAutoResumeIfReady(at: effectiveNow)
        }

        if let activeActivity {
            syncSummaryMetrics(to: activeActivity)
        }
    }

    private func evaluateAutoResumeIfReady(at now: Date) {
        guard case .paused(true) = state,
              settings.autoPauseEnabled,
              isAutoResumeMovementConfirmed,
              let lastConf = lastAutoResumeConfirmationDate,
              now.timeIntervalSince(lastConf) <= AppConfig.autoResumeSignalMaxAgeSeconds,
              autoResumeMovingDurationSeconds >= AppConfig.defaultAutoResumeGracePeriod else {
            return
        }
        resumeWorkout(now: now)
    }

    func handleIncomingLocation(
        _ location: CLLocation,
        barometricRelativeAltitude: Double?,
        isBarometerActive: Bool = true,
        now: Date = Date()
    ) {
        guard state != .idle, let activity = activeActivity else { return }

        if store.pendingPointCount > 0 && store.lastSaveError != nil {
            _ = store.retryPendingFlush(now: now)
        }

        if case .paused(let isAutomatic) = state {
            needsSegmentBreak = true

            if isAutomatic && settings.autoPauseEnabled {
                let recoveryConfig = GPSFilterConfig.autoPauseRecovery(for: selectedActivityType)
                let decision = filterEngine.evaluate(location: location, config: recoveryConfig, now: now)
                switch decision {
                case .accept(_, let impliedSpeed, let movementState, _):
                    if movementState == .confirmedMoving && impliedSpeed > settings.autoPauseSpeedThresholdMPS {
                        if !isAutoResumeMovementConfirmed {
                            autoResumeConfirmedSinceDate = now
                        }
                        isAutoResumeMovementConfirmed = true
                        lastAutoResumeConfirmationDate = now
                    } else {
                        isAutoResumeMovementConfirmed = false
                        autoResumeConfirmedSinceDate = nil
                        lastAutoResumeConfirmationDate = nil
                        autoResumeMovingDurationSeconds = 0
                    }
                case .reject:
                    filterEngine.clearConfirmationStatePreservingAnchor()
                    isAutoResumeMovementConfirmed = false
                    autoResumeConfirmedSinceDate = nil
                    lastAutoResumeConfirmationDate = nil
                    autoResumeMovingDurationSeconds = 0
                }
            }

            advanceClocks(to: now)

            syncSummaryMetrics(to: activity)
            return
        }

        advanceClocks(to: now)

        let config = GPSFilterConfig.for(
            activityType: selectedActivityType,
            maxAccuracy: settings.maxHorizontalAccuracyMeters
        )

        let decision = filterEngine.evaluate(location: location, config: config, now: now)

        switch decision {
        case .accept(let distanceDelta, let impliedSpeed, let movementState, let isRoutePoint):
            let hasConfirmedMovement = movementState == .confirmedMoving
            let confirmedMovingSpeed: Double
            if hasConfirmedMovement {
                lastConfirmedMovingDate = now
                let candidateSpeed = impliedSpeed > 0
                    ? impliedSpeed
                    : (location.speed > 0 ? location.speed : max(activeMovingSpeedMPS, 0.5))
                activeMovingSpeedMPS = candidateSpeed
                confirmedMovingSpeed = candidateSpeed
            } else {
                activeMovingSpeedMPS = 0
                confirmedMovingSpeed = 0
            }

            if movementState == .confirmedStationary {
                lastConfirmedStationaryDate = now
            }

            let isAcceptedRouteMovement = hasConfirmedMovement && isRoutePoint
            totalDistanceMeters += isAcceptedRouteMovement ? distanceDelta : 0
            if isAcceptedRouteMovement && impliedSpeed > maxSpeedMPS {
                maxSpeedMPS = impliedSpeed
            }
            if isAcceptedRouteMovement {
                let splitDuration = max(0, movingTimeSeconds - lastSplitMovingTimeSeconds)
                lastSplitMovingTimeSeconds = movingTimeSeconds
                recordSplitProgress(distanceMeters: distanceDelta, durationSeconds: splitDuration, activity: activity, now: now)
            }

            currentSpeedMPS = hasConfirmedMovement ? confirmedMovingSpeed : 0
            currentPaceSecPerKm = (hasConfirmedMovement && confirmedMovingSpeed > 0.2)
                ? (1_000.0 / confirmedMovingSpeed)
                : nil

            let elevationOutcome = normaliseElevation(
                location: location,
                barometricRelativeAltitude: barometricRelativeAltitude,
                isBarometerActive: isBarometerActive
            )

            updateStationaryStateForAutoPause(movementState: movementState)

            let markBreak = isRoutePoint && needsSegmentBreak
            if markBreak {
                needsSegmentBreak = false
            }

            if isRoutePoint {
                acceptedPointCount += 1
            }

            let point = TrackPoint(
                location: location,
                activityID: activity.id,
                barometricRelativeAltitude: barometricRelativeAltitude,
                normalisedElevationMeters: elevationOutcome.normalisedAltitude,
                elevationSource: elevationOutcome.source,
                isAccepted: isRoutePoint,
                isSegmentBreak: markBreak,
                activity: activity
            )
            store.enqueueTrackPoint(point, now: now)

        case .reject:
            filterEngine.clearConfirmationStatePreservingAnchor()
            stationaryDurationSeconds = 0
            lastConfirmedStationaryDate = nil
            activeMovingSpeedMPS = 0
            currentSpeedMPS = 0
            currentPaceSecPerKm = nil
            rejectedPointCount += 1
            let point = TrackPoint(
                location: location,
                activityID: activity.id,
                barometricRelativeAltitude: barometricRelativeAltitude,
                normalisedElevationMeters: nil,
                elevationSource: .unknown,
                isAccepted: false,
                isSegmentBreak: false,
                activity: activity
            )
            store.enqueueTrackPoint(point, now: now)
        }

        syncSummaryMetrics(to: activity)
    }

    private func recordSplitProgress(
        distanceMeters: Double,
        durationSeconds: TimeInterval,
        activity: WorkoutActivity,
        now: Date
    ) {
        let splitDistance = splitDistanceMetersForWorkout
        var remainingDistance = max(0, distanceMeters)
        var remainingDuration = max(0, durationSeconds)

        while splitProgressMeters + remainingDistance >= splitDistance && remainingDistance > 0 {
            let distanceNeeded = splitDistance - splitProgressMeters
            let fractionOfCurrentSegment = min(1, distanceNeeded / remainingDistance)
            let splitDuration = splitProgressSeconds + remainingDuration * fractionOfCurrentSegment
            completedSplitCount += 1
            let split = ActivitySplit(
                activityID: activity.id,
                splitIndex: completedSplitCount,
                distanceMeters: splitDistance,
                durationSeconds: splitDuration,
                averagePaceSecPerKm: splitDuration / (splitDistance / 1_000.0),
                activity: activity
            )
            store.addSplit(split, to: activity, now: now)

            remainingDistance -= distanceNeeded
            remainingDuration *= (1 - fractionOfCurrentSegment)
            splitProgressMeters = 0
            splitProgressSeconds = 0
        }

        splitProgressMeters += remainingDistance
        splitProgressSeconds += remainingDuration
    }

    private func normaliseElevation(
        location: CLLocation,
        barometricRelativeAltitude: Double?,
        isBarometerActive: Bool
    ) -> (normalisedAltitude: Double?, source: ElevationSource) {
        let canUseBaro = settings.useBarometerWhenAvailable && isBarometerActive && barometricRelativeAltitude != nil

        if canUseBaro, let relBaro = barometricRelativeAltitude {
            if barometerAnchorAltitudeMeters == nil {
                // Barometric altitude is relative. Anchor it to GPS only when
                // vertical accuracy is useful; otherwise use a neutral baseline.
                let base = location.verticalAccuracy >= 0 && location.verticalAccuracy <= 25
                    ? location.altitude
                    : 0.0
                barometerAnchorAltitudeMeters = base
            }
            let normalised = (barometerAnchorAltitudeMeters ?? 0.0) + relBaro
            activeElevationSource = .barometer
            let result = elevationTracker.recordSample(altitude: normalised, source: .barometer)
            elevationGainMeters = result.gainMeters
            elevationLossMeters = result.lossMeters
            return (normalised, .barometer)
        } else if location.verticalAccuracy >= 0 {
            activeElevationSource = .gps
            let result = elevationTracker.recordSample(altitude: location.altitude, source: .gps)
            elevationGainMeters = result.gainMeters
            elevationLossMeters = result.lossMeters
            return (location.altitude, .gps)
        }

        return (nil, activeElevationSource)
    }

    private func updateStationaryStateForAutoPause(movementState: GPSMovementState) {
        guard settings.autoPauseEnabled, state == .recording else {
            stationaryDurationSeconds = 0
            lastConfirmedStationaryDate = nil
            return
        }

        switch movementState {
        case .confirmedMoving:
            stationaryDurationSeconds = 0
            lastConfirmedStationaryDate = nil
        case .confirmedStationary:
            break
        case .unknownOrUnconfirmed:
            stationaryDurationSeconds = 0
            lastConfirmedStationaryDate = nil
        }
    }

    private func syncSummaryMetrics(to activity: WorkoutActivity) {
        activity.totalDistanceMeters = totalDistanceMeters
        activity.elapsedTimeSeconds = elapsedTimeSeconds
        activity.movingTimeSeconds = movingTimeSeconds
        activity.averageSpeedMPS = averageSpeedMPS
        activity.maxSpeedMPS = maxSpeedMPS
        activity.averagePaceSecPerKm = averagePaceSecPerKm
        activity.elevationGainMeters = elevationGainMeters
        activity.elevationLossMeters = elevationLossMeters
        activity.elevationSource = activeElevationSource
        activity.estimatedCalories = estimatedCalories
    }
}
