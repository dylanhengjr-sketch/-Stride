import Foundation
import SwiftData

@Model
final class WorkoutActivity {
    var id: UUID
    var title: String
    var activityTypeRaw: String
    var statusRaw: String
    var startDate: Date
    var finishDate: Date?
    var lastUpdatedDate: Date
    var totalDistanceMeters: Double
    var elapsedTimeSeconds: TimeInterval
    var movingTimeSeconds: TimeInterval
    var averageSpeedMPS: Double
    var maxSpeedMPS: Double
    var averagePaceSecPerKm: Double?
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var elevationSourceRaw: String
    var estimatedCalories: Double

    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.activity)
    var trackPoints: [TrackPoint] = []

    @Relationship(deleteRule: .cascade, inverse: \ActivitySplit.activity)
    var splits: [ActivitySplit] = []

    var activityType: ActivityType {
        get { ActivityType(rawValue: activityTypeRaw) ?? .running }
        set { activityTypeRaw = newValue.rawValue }
    }

    var status: ActivityStatus {
        get { ActivityStatus(rawValue: statusRaw) ?? .recording }
        set { statusRaw = newValue.rawValue }
    }

    /// True when a route has distance but no measured moving time or speed.
    /// This also covers untimed GPX imports, where elapsed time is unavailable.
    var hasUnavailableMovingMetrics: Bool {
        movingTimeSeconds <= 0
            && averageSpeedMPS <= 0
            && totalDistanceMeters > 0
    }

    var elevationSource: ElevationSource {
        get { ElevationSource(rawValue: elevationSourceRaw) ?? .unknown }
        set { elevationSourceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        activityType: ActivityType,
        status: ActivityStatus = .recording,
        startDate: Date,
        finishDate: Date? = nil,
        lastUpdatedDate: Date? = nil,
        totalDistanceMeters: Double = 0,
        elapsedTimeSeconds: TimeInterval = 0,
        movingTimeSeconds: TimeInterval = 0,
        averageSpeedMPS: Double = 0,
        maxSpeedMPS: Double = 0,
        averagePaceSecPerKm: Double? = nil,
        elevationGainMeters: Double = 0,
        elevationLossMeters: Double = 0,
        elevationSource: ElevationSource = .unknown,
        estimatedCalories: Double = 0
    ) {
        self.id = id
        self.title = title
        self.activityTypeRaw = activityType.rawValue
        self.statusRaw = status.rawValue
        self.startDate = startDate
        self.finishDate = finishDate
        self.lastUpdatedDate = lastUpdatedDate ?? startDate
        self.totalDistanceMeters = totalDistanceMeters
        self.elapsedTimeSeconds = elapsedTimeSeconds
        self.movingTimeSeconds = movingTimeSeconds
        self.averageSpeedMPS = averageSpeedMPS
        self.maxSpeedMPS = maxSpeedMPS
        self.averagePaceSecPerKm = averagePaceSecPerKm
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.elevationSourceRaw = elevationSource.rawValue
        self.estimatedCalories = estimatedCalories
    }
}
