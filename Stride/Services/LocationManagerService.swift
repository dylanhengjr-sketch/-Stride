import Foundation
import CoreLocation
import CoreMotion

struct BarometricAltitudeAccumulator: Sendable {
    private(set) var accumulatedAltitudeMeters: Double?
    private(set) var latestSampleAltitudeMeters: Double?

    private var sessionStartAltitudeMeters: Double = 0
    private var isSessionActive = false

    mutating func restore(_ altitudeMeters: Double?) {
        accumulatedAltitudeMeters = altitudeMeters.flatMap { $0.isFinite ? $0 : nil }
        latestSampleAltitudeMeters = nil
        sessionStartAltitudeMeters = accumulatedAltitudeMeters ?? 0
        isSessionActive = false
    }

    mutating func beginSession() {
        guard !isSessionActive else { return }
        sessionStartAltitudeMeters = accumulatedAltitudeMeters ?? 0
        latestSampleAltitudeMeters = nil
        isSessionActive = true
    }

    @discardableResult
    mutating func record(relativeAltitudeMeters: Double) -> Double? {
        guard isSessionActive, relativeAltitudeMeters.isFinite else { return nil }
        let normalisedAltitude = sessionStartAltitudeMeters + relativeAltitudeMeters
        guard normalisedAltitude.isFinite else { return nil }

        accumulatedAltitudeMeters = normalisedAltitude
        latestSampleAltitudeMeters = normalisedAltitude
        return normalisedAltitude
    }

    mutating func endSession() {
        guard isSessionActive else {
            latestSampleAltitudeMeters = nil
            return
        }

        if let latestSampleAltitudeMeters {
            accumulatedAltitudeMeters = latestSampleAltitudeMeters
        }
        sessionStartAltitudeMeters = accumulatedAltitudeMeters ?? 0
        latestSampleAltitudeMeters = nil
        isSessionActive = false
    }
}

final class LocationManagerService: NSObject, CLLocationManagerDelegate {
    var onLocationReceived: ((CLLocation, Double?, Bool) -> Void)?
    var onAuthorizationChanged: ((CLAuthorizationStatus) -> Void)?

    private let locationManager = CLLocationManager()
    private let authorizationStatusOverride: CLAuthorizationStatus?
    private let altimeter = CMAltimeter()
    private var backgroundActivitySession: CLBackgroundActivitySession?

    private var isTrackingActive: Bool = false
    private var isBarometerRunning: Bool = false
    private var barometricAltitudeAccumulator = BarometricAltitudeAccumulator()
    private var activeBarometerSessionID: UUID?
    private(set) var lastErrorMessage: String?

    override init() {
        authorizationStatusOverride = nil
        super.init()
        configureLocationManager()
    }

    /// Allows deterministic authorization in unit tests without changing device permissions.
    init(authorizationStatusOverride: CLAuthorizationStatus) {
        self.authorizationStatusOverride = authorizationStatusOverride
        super.init()
        configureLocationManager()
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus {
        authorizationStatusOverride ?? locationManager.authorizationStatus
    }

    var isAuthorizedForWorkout: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    func requestWhenInUseAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func restoreBarometricOffset(meters: Double?) {
        barometricAltitudeAccumulator.restore(meters)
    }

    func startActiveTracking(for activityType: ActivityType, useBarometer: Bool) {
        guard isAuthorizedForWorkout else {
            lastErrorMessage = "Location authorization not granted."
            return
        }

        lastErrorMessage = nil
        configureLocationManager(for: activityType, isPaused: false)
        beginBackgroundActivitySessionIfAvailable()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
        isTrackingActive = true

        if useBarometer {
            startBarometerIfAvailable()
        } else {
            stopBarometer()
        }
    }

    func stopActiveTracking() {
        isTrackingActive = false
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        endBackgroundActivitySessionIfAvailable()
        stopBarometer()
    }

    func applyPauseMode(isAutomatic: Bool, activityType: ActivityType) {
        if isAutomatic {
            guard isAuthorizedForWorkout else {
                stopActiveTracking()
                return
            }
            configureLocationManager(for: activityType, isPaused: true)
            beginBackgroundActivitySessionIfAvailable()
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            isTrackingActive = true
            stopBarometer()
        } else {
            // A manual pause must not keep GPS or the barometer running.
            isTrackingActive = false
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            endBackgroundActivitySessionIfAvailable()
            stopBarometer()
        }
    }

    func ensureActiveSessionForResume(activityType: ActivityType, useBarometer: Bool) -> Bool {
        guard isAuthorizedForWorkout else {
            lastErrorMessage = "Location permission is required to resume tracking."
            return false
        }
        lastErrorMessage = nil
        configureLocationManager(for: activityType, isPaused: false)
        beginBackgroundActivitySessionIfAvailable()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
        isTrackingActive = true

        if useBarometer {
            startBarometerIfAvailable()
        } else {
            stopBarometer()
        }
        return true
    }

    private func beginBackgroundActivitySessionIfAvailable() {
        if #available(iOS 17.0, *) {
            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
            }
        }
    }

    private func endBackgroundActivitySessionIfAvailable() {
        if #available(iOS 17.0, *) {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }
    }

    private func configureLocationManager(for activityType: ActivityType, isPaused: Bool) {
        switch activityType {
        case .cycling:
            locationManager.desiredAccuracy = isPaused ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
        case .running, .walking, .hiking:
            locationManager.desiredAccuracy = isPaused ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBestForNavigation
        }
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func startBarometerIfAvailable() {
        guard !isBarometerRunning, CMAltimeter.isRelativeAltitudeAvailable() else { return }

        barometricAltitudeAccumulator.beginSession()
        let sessionID = UUID()
        activeBarometerSessionID = sessionID
        isBarometerRunning = true

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, self.activeBarometerSessionID == sessionID else { return }

            if let error {
                self.lastErrorMessage = error.localizedDescription
                self.activeBarometerSessionID = nil
                self.isBarometerRunning = false
                self.altimeter.stopRelativeAltitudeUpdates()
                self.barometricAltitudeAccumulator.endSession()
                return
            }

            if let relativeAltitude = data?.relativeAltitude.doubleValue {
                _ = self.barometricAltitudeAccumulator.record(relativeAltitudeMeters: relativeAltitude)
            }
        }
    }

    private func stopBarometer() {
        guard isBarometerRunning else { return }
        activeBarometerSessionID = nil
        isBarometerRunning = false
        altimeter.stopRelativeAltitudeUpdates()
        barometricAltitudeAccumulator.endSession()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTrackingActive else { return }
        let baroActive = settingsBarometerActive()
        let barometricAltitude = baroActive ? barometricAltitudeAccumulator.latestSampleAltitudeMeters : nil

        for location in locations {
            onLocationReceived?(location, barometricAltitude, baroActive)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        lastErrorMessage = error.localizedDescription
    }

    private func settingsBarometerActive() -> Bool {
        isBarometerRunning && CMAltimeter.isRelativeAltitudeAvailable()
    }
}
