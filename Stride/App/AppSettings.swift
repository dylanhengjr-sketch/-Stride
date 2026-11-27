import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID
    var userWeightKg: Double
    var autoPauseEnabled: Bool
    var autoPauseSpeedThresholdMPS: Double
    var maxHorizontalAccuracyMeters: Double
    var useBarometerWhenAvailable: Bool
    var distanceUnitKilometers: Bool
    var voiceAnnouncementsEnabled: Bool
    var appearanceModeRaw: String
    var weeklyGoalMeters: Double
    var monthlyGoalMeters: Double

    init(
        id: UUID = UUID(),
        userWeightKg: Double = 70.0,
        autoPauseEnabled: Bool = true,
        autoPauseSpeedThresholdMPS: Double = 0.45,
        maxHorizontalAccuracyMeters: Double = 25.0,
        useBarometerWhenAvailable: Bool = true,
        distanceUnitKilometers: Bool = true,
        voiceAnnouncementsEnabled: Bool = false,
        appearanceModeRaw: String = "system",
        weeklyGoalMeters: Double = 20_000,
        monthlyGoalMeters: Double = 80_000
    ) {
        self.id = id
        self.userWeightKg = userWeightKg
        self.autoPauseEnabled = autoPauseEnabled
        self.autoPauseSpeedThresholdMPS = autoPauseSpeedThresholdMPS
        self.maxHorizontalAccuracyMeters = maxHorizontalAccuracyMeters
        self.useBarometerWhenAvailable = useBarometerWhenAvailable
        self.distanceUnitKilometers = distanceUnitKilometers
        self.voiceAnnouncementsEnabled = voiceAnnouncementsEnabled
        self.appearanceModeRaw = appearanceModeRaw
        self.weeklyGoalMeters = weeklyGoalMeters
        self.monthlyGoalMeters = monthlyGoalMeters
    }
}
