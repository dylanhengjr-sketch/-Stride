import Foundation
import CoreLocation
import SwiftData

@Model
final class TrackPoint {
    var id: UUID
    var activityID: UUID
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var altitude: Double
    var speedMPS: Double
    var courseDegrees: Double
    var barometricRelativeAltitude: Double?
    var normalisedElevationMeters: Double?
    var elevationSourceRaw: String
    var isAccepted: Bool
    var isSegmentBreak: Bool

    var activity: WorkoutActivity?

    var elevationSource: ElevationSource {
        get { ElevationSource(rawValue: elevationSourceRaw) ?? .unknown }
        set { elevationSourceRaw = newValue.rawValue }
    }

    var clLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: courseDegrees,
            speed: speedMPS,
            timestamp: timestamp
        )
    }

    init(
        id: UUID = UUID(),
        activityID: UUID,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        verticalAccuracy: Double = 5.0,
        altitude: Double,
        speedMPS: Double = 0,
        courseDegrees: Double = 0,
        barometricRelativeAltitude: Double? = nil,
        normalisedElevationMeters: Double? = nil,
        elevationSource: ElevationSource = .unknown,
        isAccepted: Bool,
        isSegmentBreak: Bool = false,
        activity: WorkoutActivity? = nil
    ) {
        self.id = id
        self.activityID = activityID
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.altitude = altitude
        self.speedMPS = speedMPS
        self.courseDegrees = courseDegrees
        self.barometricRelativeAltitude = barometricRelativeAltitude
        self.normalisedElevationMeters = normalisedElevationMeters
        self.elevationSourceRaw = elevationSource.rawValue
        self.isAccepted = isAccepted
        self.isSegmentBreak = isSegmentBreak
        self.activity = activity
    }

    convenience init(
        id: UUID = UUID(),
        location: CLLocation,
        activityID: UUID,
        barometricRelativeAltitude: Double?,
        normalisedElevationMeters: Double?,
        elevationSource: ElevationSource,
        isAccepted: Bool,
        isSegmentBreak: Bool = false,
        activity: WorkoutActivity? = nil
    ) {
        self.init(
            id: id,
            activityID: activityID,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            altitude: location.altitude,
            speedMPS: location.speed,
            courseDegrees: location.course,
            barometricRelativeAltitude: barometricRelativeAltitude,
            normalisedElevationMeters: normalisedElevationMeters,
            elevationSource: elevationSource,
            isAccepted: isAccepted,
            isSegmentBreak: isSegmentBreak,
            activity: activity
        )
    }
}
