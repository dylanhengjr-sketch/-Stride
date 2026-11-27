import Foundation
import CoreLocation
import CoreMotion

final class LocationManagerService: NSObject, CLLocationManagerDelegate {
    var onLocationReceived: ((CLLocation, Double?, Bool) -> Void)?
    var onAuthorizationChanged: ((CLAuthorizationStatus) -> Void)?

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var backgroundActivitySession: CLBackgroundActivitySession?

    private var isTrackingActive: Bool = false
    private var isBarometerRunning: Bool = false
    private var latestBarometricRelativeAltitude: Double?
    private var barometricOffsetMeters: Double?
    private(set) var lastErrorMessage: String?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
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
        barometricOffsetMeters = meters
        latestBarometricRelativeAltitude = meters
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
        isBarometerRunning = true

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }

            if let error {
                self.lastErrorMessage = error.localizedDescription
                self.altimeter.stopRelativeAltitudeUpdates()
                self.isBarometerRunning = false
                self.latestBarometricRelativeAltitude = nil
                return
            }

            if let relAlt = data?.relativeAltitude.doubleValue {
                let offset = self.barometricOffsetMeters ?? 0.0
                self.latestBarometricRelativeAltitude = offset + relAlt
            }
        }
    }

    private func stopBarometer() {
        guard isBarometerRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isBarometerRunning = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTrackingActive else { return }
        let baroActive = settingsBarometerActive()

        for location in locations {
            onLocationReceived?(location, latestBarometricRelativeAltitude, baroActive)
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
