import Foundation
import SwiftData

@Model
final class ActivitySplit {
    var id: UUID
    var activityID: UUID
    var splitIndex: Int
    var distanceMeters: Double
    var durationSeconds: TimeInterval
    var averagePaceSecPerKm: Double
    var activity: WorkoutActivity?

    init(
        id: UUID = UUID(),
        activityID: UUID,
        splitIndex: Int,
        distanceMeters: Double,
        durationSeconds: TimeInterval,
        averagePaceSecPerKm: Double,
        activity: WorkoutActivity? = nil
    ) {
        self.id = id
        self.activityID = activityID
        self.splitIndex = splitIndex
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.averagePaceSecPerKm = averagePaceSecPerKm
        self.activity = activity
    }
}
