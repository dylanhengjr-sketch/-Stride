import Foundation

enum WorkoutCalculations {
    static func speedMPS(distanceMeters: Double, movingTimeSeconds: TimeInterval) -> Double {
        guard distanceMeters > 0, movingTimeSeconds > 0 else { return 0 }
        return distanceMeters / movingTimeSeconds
    }

    static func paceSecPerKm(distanceMeters: Double, movingTimeSeconds: TimeInterval) -> Double? {
        guard distanceMeters > 0.5, movingTimeSeconds > 0 else { return nil }
        let km = distanceMeters / 1_000.0
        guard km > 0 else { return nil }
        return movingTimeSeconds / km
    }

    static func estimateCalories(
        activityType: ActivityType,
        movingTimeSeconds: TimeInterval,
        weightKg: Double
    ) -> Double {
        guard movingTimeSeconds > 0, weightKg > 0 else { return 0 }
        let hours = movingTimeSeconds / 3_600.0
        return activityType.metValue * weightKg * hours
    }
}
