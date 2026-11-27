import Foundation

enum ActivityType: String, Codable, CaseIterable, Identifiable, Sendable {
    case walking
    case hiking
    case running
    case cycling

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        }
    }

    var systemImageName: String {
        switch self {
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        }
    }

    var maxPlausibleSpeedMPS: Double {
        switch self {
        case .walking: return 5.5
        case .hiking: return 6.5
        case .running: return 13.0
        case .cycling: return 28.0
        }
    }

    var metValue: Double {
        switch self {
        case .walking: return 3.5
        case .hiking: return 6.0
        case .running: return 9.8
        case .cycling: return 7.5
        }
    }
}

enum ActivityStatus: String, Codable, Sendable {
    case recording
    case pausedManual
    case pausedAuto
    case completed
    case discarded
}

enum ElevationSource: String, Codable, Sendable {
    case unknown
    case barometer
    case gps
}
