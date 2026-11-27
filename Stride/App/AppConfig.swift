import Foundation

enum AppConfig {
    static let movingConfirmationSamples: Int = 3
    static let stationaryConfirmationSamples: Int = 2
    static let autoPauseRecoveryMaxHorizontalAccuracy: Double = 100.0
    static let recoveryInterruptionThresholdSeconds: TimeInterval = 300.0
    static let defaultAutoPauseGracePeriod: TimeInterval = 12.0
    static let defaultAutoResumeGracePeriod: TimeInterval = 4.0
    static let activeMovementSignalMaxAgeSeconds: TimeInterval = 10.0
    static let stationarySignalMaxAgeSeconds: TimeInterval = 15.0
    static let autoResumeSignalMaxAgeSeconds: TimeInterval = 8.0
    static let pointFlushBatchSize: Int = 25
    static let pointFlushMaxIntervalSeconds: TimeInterval = 5.0
    static let pointFlushRetryIntervalSeconds: TimeInterval = 5.0
}
