import Foundation
import SwiftData
import Combine
import CoreLocation

@MainActor
final class LocalDatabaseStore: ObservableObject {
    @Published private(set) var lastSaveError: String?
    @Published private(set) var pendingPointCount: Int = 0

    private let modelContext: ModelContext
    private let saveHandler: (ModelContext) throws -> Void
    private var pendingPoints: [TrackPoint] = []
    private var lastFlushDate: Date?

    init(
        modelContext: ModelContext,
        saveHandler: ((ModelContext) throws -> Void)? = nil
    ) {
        self.modelContext = modelContext
        if let saveHandler {
            self.saveHandler = saveHandler
        } else {
            self.saveHandler = { context in
                if context.hasChanges {
                    try context.save()
                }
            }
        }
    }

    func fetchOrCreateSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let created = AppSettings()
        modelContext.insert(created)
        _ = commitContext(now: Date())
        return created
    }

    func createActivity(
        title: String,
        activityType: ActivityType,
        startDate: Date
    ) -> WorkoutActivity {
        let activity = WorkoutActivity(
            title: title,
            activityType: activityType,
            status: .recording,
            startDate: startDate,
            lastUpdatedDate: startDate
        )
        modelContext.insert(activity)
        lastFlushDate = startDate
        _ = commitContext(now: startDate)
        return activity
    }

    func fetchInProgressActivity() -> WorkoutActivity? {
        let descriptor = FetchDescriptor<WorkoutActivity>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let activities = try? modelContext.fetch(descriptor) else {
            return nil
        }
        return activities.first { activity in
            activity.status == .recording ||
            activity.status == .pausedManual ||
            activity.status == .pausedAuto
        }
    }

    func fetchCompletedActivities() -> [WorkoutActivity] {
        let descriptor = FetchDescriptor<WorkoutActivity>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let activities = try? modelContext.fetch(descriptor) else {
            return []
        }
        return activities.filter { $0.status == .completed }
    }

    @discardableResult
    func updateActivity(
        _ activity: WorkoutActivity,
        flushPoints: Bool = false,
        now: Date = Date()
    ) -> Bool {
        activity.lastUpdatedDate = now
        if flushPoints {
            return flushPendingTrackPoints(now: now)
        }
        return commitContext(now: now)
    }

    @discardableResult
    func deleteActivity(_ activity: WorkoutActivity, now: Date = Date()) -> Bool {
        // Save queued points first so the deletion is isolated from workout updates.
        guard flushPendingTrackPoints(now: now) else {
            return false
        }

        // Delete in the owning context. A second context can invalidate the
        // live workout's SwiftData objects even when its save subsequently fails.
        modelContext.delete(activity)
        guard commitContext(now: now) else {
            // The save handler failed before the deletion was persisted.
            // Reinsert the same model rather than rolling back the entire
            // context, which can invalidate SwiftData relationship snapshots.
            modelContext.insert(activity)
            return false
        }
        return true
    }

    func enqueueTrackPoint(
        _ point: TrackPoint,
        forceFlush: Bool = false,
        now: Date = Date()
    ) {
        modelContext.insert(point)
        pendingPoints.append(point)
        pendingPointCount = pendingPoints.count

        let shouldFlushByCount = pendingPoints.count >= AppConfig.pointFlushBatchSize
        let shouldFlushByTime: Bool
        if let lastFlush = lastFlushDate {
            shouldFlushByTime = now.timeIntervalSince(lastFlush) >= AppConfig.pointFlushMaxIntervalSeconds
        } else {
            shouldFlushByTime = true
        }

        if forceFlush || shouldFlushByCount || shouldFlushByTime {
            _ = flushPendingTrackPoints(now: now)
        }
    }

    @discardableResult
    func flushPendingTrackPoints(now: Date = Date()) -> Bool {
        guard !pendingPoints.isEmpty else {
            return commitContext(now: now)
        }
        let succeeded = commitContext(now: now)
        if succeeded {
            pendingPoints.removeAll()
            pendingPointCount = 0
            lastFlushDate = now
        }
        return succeeded
    }

    @discardableResult
    func retryPendingFlush(now: Date = Date()) -> Bool {
        flushPendingTrackPoints(now: now)
    }


    func addSplit(_ split: ActivitySplit, to activity: WorkoutActivity, now: Date = Date()) {
        guard split.activityID == activity.id else { return }
        // The split's activity relationship updates activity.splits automatically.
        modelContext.insert(split)
        if pendingPoints.isEmpty {
            _ = commitContext(now: now)
        } else {
            _ = flushPendingTrackPoints(now: now)
        }
    }

    func fetchAllActivities() -> [WorkoutActivity] {
        let descriptor = FetchDescriptor<WorkoutActivity>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func makeJSONBackup() throws -> Data {
        let allActivities = try modelContext.fetch(FetchDescriptor<WorkoutActivity>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))
        let records = allActivities.map { StrideBackupActivity(activity: $0) }
        let currentSettings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first
        let backup = StrideBackup(
            version: 1,
            exportedAt: Date(),
            settings: currentSettings.map { StrideBackupSettings(settings: $0) },
            activities: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    func importJSONBackup(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(StrideBackup.self, from: data)
        guard backup.version == 1 else {
            throw TransferError.unsupportedBackupVersion(backup.version)
        }
        var existingIDs = Set(fetchAllActivities().map(\.id))
        if let settingsRecord = backup.settings {
            let settingsDescriptor = FetchDescriptor<AppSettings>()
            let destinationSettings = try modelContext.fetch(settingsDescriptor).first
            if let destinationSettings {
                settingsRecord.apply(to: destinationSettings)
            } else {
                let restoredSettings = settingsRecord.makeSettings()
                modelContext.insert(restoredSettings)
            }
        }
        for record in backup.activities where !existingIDs.contains(record.id) {
            existingIDs.insert(record.id)
            let activity = record.makeActivity()
            modelContext.insert(activity)
            for pointRecord in record.trackPoints {
                let point = pointRecord.makeTrackPoint(activity: activity)
                modelContext.insert(point)
            }
            for splitRecord in record.splits {
                let split = splitRecord.makeSplit(activity: activity)
                modelContext.insert(split)
            }
        }
        try modelContext.save()
        pendingPoints.removeAll()
        pendingPointCount = 0
        lastFlushDate = Date()
        lastSaveError = nil
    }

    func makeGPXData(for activity: WorkoutActivity) throws -> Data {
        let points = activity.trackPoints
            .filter(\.isAccepted)
            .sorted { $0.timestamp < $1.timestamp }
        guard !points.isEmpty else { throw TransferError.noRoutePoints }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"Stride\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        xml += "  <trk><name>\(Self.xmlEscaped(activity.title))</name>\n"
        let timeFormatter = ISO8601DateFormatter()
        var segmentOpen = false
        for (index, point) in points.enumerated() {
            if !segmentOpen || point.isSegmentBreak {
                if segmentOpen { xml += "      </trkseg>\n" }
                xml += "      <trkseg>\n"
                segmentOpen = true
            }
            xml += String(format: "        <trkpt lat=\"%.8f\" lon=\"%.8f\">\n", point.latitude, point.longitude)
            if point.normalisedElevationMeters != nil || point.verticalAccuracy >= 0 {
                xml += String(format: "          <ele>%.2f</ele>\n", point.normalisedElevationMeters ?? point.altitude)
            }
            xml += "          <time>\(timeFormatter.string(from: point.timestamp))</time>\n"
            xml += "        </trkpt>\n"
            if index == points.count - 1 { xml += "      </trkseg>\n" }
        }
        xml += "  </trk></gpx>\n"
        guard let data = xml.data(using: .utf8) else { throw TransferError.encodingFailed }
        return data
    }

    func importGPX(_ data: Data) throws {
        let parsed = try GPXImportParser.parse(data)
        guard !parsed.points.isEmpty else { throw TransferError.noRoutePoints }
        let importedAt = Date()
        let resolvedTimestamps = Self.resolvedGPXPointTimestamps(parsed.points, fallbackDate: importedAt)
        let hasCompleteTimestamps = parsed.points.allSatisfy { $0.timestamp != nil }
        let firstDate = resolvedTimestamps.first ?? importedAt
        let lastDate = resolvedTimestamps.last ?? firstDate
        var distance = 0.0
        var gain = 0.0
        var loss = 0.0
        var previous: GPXImportPoint?
        for point in parsed.points {
            if let previous, !point.startsNewSegment {
                let a = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                let b = CLLocation(latitude: point.latitude, longitude: point.longitude)
                distance += a.distance(from: b)
                if point.hasElevation && previous.hasElevation {
                    let delta = point.elevation - previous.elevation
                    if delta > 0 { gain += delta } else { loss += abs(delta) }
                }
            }
            previous = point
        }
        // Missing GPX timestamps are synthesized only to keep route points ordered.
        // They must not be presented as a measured workout duration.
        let elapsed = hasCompleteTimestamps ? max(0, lastDate.timeIntervalSince(firstDate)) : 0
        let activity = WorkoutActivity(
            title: parsed.name.isEmpty
                ? "Imported GPX - \(firstDate.formatted(date: .abbreviated, time: .shortened))"
                : "Imported GPX - \(parsed.name)",
            activityType: .running,
            status: .completed,
            startDate: firstDate,
            finishDate: lastDate,
            lastUpdatedDate: Date(),
            totalDistanceMeters: distance,
            elapsedTimeSeconds: elapsed,
            // GPX timestamps provide elapsed time, but do not reliably identify
            // pauses or moving intervals. Leave moving-only metrics unavailable.
            movingTimeSeconds: 0,
            averageSpeedMPS: 0,
            averagePaceSecPerKm: nil,
            elevationGainMeters: gain,
            elevationLossMeters: loss
        )
        modelContext.insert(activity)
        for (index, point) in parsed.points.enumerated() {
            let trackPoint = TrackPoint(
                activityID: activity.id,
                latitude: point.latitude,
                longitude: point.longitude,
                timestamp: resolvedTimestamps[index],
                horizontalAccuracy: 5,
                verticalAccuracy: point.hasElevation ? 5 : -1,
                altitude: point.elevation,
                speedMPS: 0,
                courseDegrees: 0,
                normalisedElevationMeters: point.hasElevation ? point.elevation : nil,
                elevationSource: point.hasElevation ? .gps : .unknown,
                isAccepted: true,
                isSegmentBreak: point.startsNewSegment,
                activity: activity
            )
            modelContext.insert(trackPoint)
        }
        try modelContext.save()
        pendingPoints.removeAll()
        pendingPointCount = 0
        lastFlushDate = Date()
        lastSaveError = nil
    }

    private static func resolvedGPXPointTimestamps(
        _ points: [GPXImportPoint],
        fallbackDate: Date
    ) -> [Date] {
        var resolved = points.map(\.timestamp)

        // A valid GPX track may omit every point timestamp. Use import-time
        // timestamps with tiny offsets to preserve point order without implying
        // a measurable elapsed duration.
        guard resolved.contains(where: { $0 != nil }) else {
            return points.indices.map {
                fallbackDate.addingTimeInterval(Double($0) * 0.001)
            }
        }

        var index = 0
        while index < resolved.count {
            if resolved[index] != nil {
                index += 1
                continue
            }

            let gapStart = index
            while index < resolved.count, resolved[index] == nil {
                index += 1
            }
            let gapEnd = index
            let gapLength = gapEnd - gapStart
            let previous = gapStart > 0 ? resolved[gapStart - 1] : nil
            let next = gapEnd < resolved.count ? resolved[gapEnd] : nil

            for offset in 0..<gapLength {
                let pointIndex = gapStart + offset
                if let previous, let next, next > previous {
                    let fraction = Double(offset + 1) / Double(gapLength + 1)
                    resolved[pointIndex] = previous.addingTimeInterval(
                        next.timeIntervalSince(previous) * fraction
                    )
                } else if let previous {
                    resolved[pointIndex] = previous.addingTimeInterval(Double(offset + 1))
                } else if let next {
                    resolved[pointIndex] = next.addingTimeInterval(-Double(gapLength - offset))
                } else {
                    resolved[pointIndex] = fallbackDate.addingTimeInterval(Double(pointIndex) * 0.001)
                }
            }
        }

        return resolved.map { $0 ?? fallbackDate }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    @discardableResult
    private func commitContext(now: Date, context: ModelContext? = nil) -> Bool {
        do {
            try saveHandler(context ?? modelContext)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error.localizedDescription
            return false
        }
    }
}


private enum TransferError: LocalizedError {
    case unsupportedBackupVersion(Int)
    case noRoutePoints
    case encodingFailed
    case invalidGPX

    var errorDescription: String? {
        switch self {
        case .unsupportedBackupVersion(let version): return "Unsupported Stride backup version: \(version)."
        case .noRoutePoints: return "This activity contains no exportable route points."
        case .encodingFailed: return "The export file could not be encoded."
        case .invalidGPX: return "The selected GPX file is invalid or contains no track points."
        }
    }
}

private struct StrideBackup: Codable {
    let version: Int
    let exportedAt: Date
    let settings: StrideBackupSettings?
    let activities: [StrideBackupActivity]
}

private struct StrideBackupSettings: Codable {
    let userWeightKg: Double
    let autoPauseEnabled: Bool
    let autoPauseSpeedThresholdMPS: Double
    let maxHorizontalAccuracyMeters: Double
    let useBarometerWhenAvailable: Bool
    let distanceUnitKilometers: Bool
    let appearanceModeRaw: String
    let weeklyGoalMeters: Double
    let monthlyGoalMeters: Double

    init(settings: AppSettings) {
        userWeightKg = settings.userWeightKg
        autoPauseEnabled = settings.autoPauseEnabled
        autoPauseSpeedThresholdMPS = settings.autoPauseSpeedThresholdMPS
        maxHorizontalAccuracyMeters = settings.maxHorizontalAccuracyMeters
        useBarometerWhenAvailable = settings.useBarometerWhenAvailable
        distanceUnitKilometers = settings.distanceUnitKilometers
        appearanceModeRaw = settings.appearanceModeRaw
        weeklyGoalMeters = settings.weeklyGoalMeters
        monthlyGoalMeters = settings.monthlyGoalMeters
    }

    func makeSettings() -> AppSettings {
        AppSettings(
            userWeightKg: userWeightKg,
            autoPauseEnabled: autoPauseEnabled,
            autoPauseSpeedThresholdMPS: autoPauseSpeedThresholdMPS,
            maxHorizontalAccuracyMeters: maxHorizontalAccuracyMeters,
            useBarometerWhenAvailable: useBarometerWhenAvailable,
            distanceUnitKilometers: distanceUnitKilometers,
            appearanceModeRaw: appearanceModeRaw,
            weeklyGoalMeters: weeklyGoalMeters,
            monthlyGoalMeters: monthlyGoalMeters
        )
    }

    func apply(to settings: AppSettings) {
        settings.userWeightKg = userWeightKg
        settings.autoPauseEnabled = autoPauseEnabled
        settings.autoPauseSpeedThresholdMPS = autoPauseSpeedThresholdMPS
        settings.maxHorizontalAccuracyMeters = maxHorizontalAccuracyMeters
        settings.useBarometerWhenAvailable = useBarometerWhenAvailable
        settings.distanceUnitKilometers = distanceUnitKilometers
        settings.appearanceModeRaw = appearanceModeRaw
        settings.weeklyGoalMeters = weeklyGoalMeters
        settings.monthlyGoalMeters = monthlyGoalMeters
    }
}

private struct StrideBackupActivity: Codable {
    let id: UUID
    let title: String
    let activityTypeRaw: String
    let statusRaw: String
    let startDate: Date
    let finishDate: Date?
    let lastUpdatedDate: Date
    let totalDistanceMeters: Double
    let elapsedTimeSeconds: TimeInterval
    let movingTimeSeconds: TimeInterval
    let averageSpeedMPS: Double
    let maxSpeedMPS: Double
    let averagePaceSecPerKm: Double?
    let elevationGainMeters: Double
    let elevationLossMeters: Double
    let elevationSourceRaw: String
    let estimatedCalories: Double
    let trackPoints: [StrideBackupTrackPoint]
    let splits: [StrideBackupSplit]

    init(activity: WorkoutActivity) {
        id = activity.id
        title = activity.title
        activityTypeRaw = activity.activityTypeRaw
        statusRaw = activity.statusRaw
        startDate = activity.startDate
        finishDate = activity.finishDate
        lastUpdatedDate = activity.lastUpdatedDate
        totalDistanceMeters = activity.totalDistanceMeters
        elapsedTimeSeconds = activity.elapsedTimeSeconds
        movingTimeSeconds = activity.movingTimeSeconds
        averageSpeedMPS = activity.averageSpeedMPS
        maxSpeedMPS = activity.maxSpeedMPS
        averagePaceSecPerKm = activity.averagePaceSecPerKm
        elevationGainMeters = activity.elevationGainMeters
        elevationLossMeters = activity.elevationLossMeters
        elevationSourceRaw = activity.elevationSourceRaw
        estimatedCalories = activity.estimatedCalories
        trackPoints = activity.trackPoints.map { StrideBackupTrackPoint(point: $0) }
        splits = activity.splits.map { StrideBackupSplit(split: $0) }
    }

    func makeActivity() -> WorkoutActivity {
        let activity = WorkoutActivity(
            id: id,
            title: title,
            activityType: ActivityType(rawValue: activityTypeRaw) ?? .running,
            status: ActivityStatus(rawValue: statusRaw) ?? .completed,
            startDate: startDate,
            finishDate: finishDate,
            lastUpdatedDate: lastUpdatedDate,
            totalDistanceMeters: totalDistanceMeters,
            elapsedTimeSeconds: elapsedTimeSeconds,
            movingTimeSeconds: movingTimeSeconds,
            averageSpeedMPS: averageSpeedMPS,
            maxSpeedMPS: maxSpeedMPS,
            averagePaceSecPerKm: averagePaceSecPerKm,
            elevationGainMeters: elevationGainMeters,
            elevationLossMeters: elevationLossMeters,
            elevationSource: ElevationSource(rawValue: elevationSourceRaw) ?? .unknown,
            estimatedCalories: estimatedCalories
        )
        return activity
    }
}

private struct StrideBackupTrackPoint: Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let altitude: Double
    let speedMPS: Double
    let courseDegrees: Double
    let barometricRelativeAltitude: Double?
    let normalisedElevationMeters: Double?
    let elevationSourceRaw: String
    let isAccepted: Bool
    let isSegmentBreak: Bool

    init(point: TrackPoint) {
        id = point.id
        latitude = point.latitude
        longitude = point.longitude
        timestamp = point.timestamp
        horizontalAccuracy = point.horizontalAccuracy
        verticalAccuracy = point.verticalAccuracy
        altitude = point.altitude
        speedMPS = point.speedMPS
        courseDegrees = point.courseDegrees
        barometricRelativeAltitude = point.barometricRelativeAltitude
        normalisedElevationMeters = point.normalisedElevationMeters
        elevationSourceRaw = point.elevationSourceRaw
        isAccepted = point.isAccepted
        isSegmentBreak = point.isSegmentBreak
    }

    func makeTrackPoint(activity: WorkoutActivity) -> TrackPoint {
        TrackPoint(
            id: id,
            activityID: activity.id,
            latitude: latitude,
            longitude: longitude,
            timestamp: timestamp,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            altitude: altitude,
            speedMPS: speedMPS,
            courseDegrees: courseDegrees,
            barometricRelativeAltitude: barometricRelativeAltitude,
            normalisedElevationMeters: normalisedElevationMeters,
            elevationSource: ElevationSource(rawValue: elevationSourceRaw) ?? .unknown,
            isAccepted: isAccepted,
            isSegmentBreak: isSegmentBreak,
            activity: activity
        )
    }
}

private struct StrideBackupSplit: Codable {
    let id: UUID
    let splitIndex: Int
    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let averagePaceSecPerKm: Double

    init(split: ActivitySplit) {
        id = split.id
        splitIndex = split.splitIndex
        distanceMeters = split.distanceMeters
        durationSeconds = split.durationSeconds
        averagePaceSecPerKm = split.averagePaceSecPerKm
    }

    func makeSplit(activity: WorkoutActivity) -> ActivitySplit {
        ActivitySplit(
            id: id,
            activityID: activity.id,
            splitIndex: splitIndex,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            averagePaceSecPerKm: averagePaceSecPerKm,
            activity: activity
        )
    }
}

private struct GPXImportPoint {
    let latitude: Double
    let longitude: Double
    let timestamp: Date?
    let elevation: Double
    let hasElevation: Bool
    let startsNewSegment: Bool
}

private final class GPXImportParser: NSObject, XMLParserDelegate {
    private(set) var points: [GPXImportPoint] = []
    private(set) var name = ""
    private var currentElement = ""
    private var text = ""
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double = 0
    private var hasElevation = false
    private var currentTime: Date?
    private var startsNewSegment = true
    private let isoFormatter = ISO8601DateFormatter()
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ data: Data) throws -> (name: String, points: [GPXImportPoint]) {
        let parserDelegate = GPXImportParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(), !parserDelegate.points.isEmpty else { throw TransferError.invalidGPX }
        return (parserDelegate.name, parserDelegate.points)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        text = ""
        if elementName == "trkseg" || elementName == "rte" { startsNewSegment = true }
        if elementName == "trkpt" || elementName == "rtept" {
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentElevation = 0
            hasElevation = false
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "name": if name.isEmpty { name = value }
        case "ele":
            if let elevation = Double(value) { currentElevation = elevation; hasElevation = true }
        case "time":
            currentTime = isoFormatter.date(from: value) ?? fractionalISOFormatter.date(from: value)
        case "trkpt", "rtept":
            if let latitude = currentLatitude, let longitude = currentLongitude,
               abs(latitude) <= 90, abs(longitude) <= 180 {
                points.append(GPXImportPoint(
                    latitude: latitude,
                    longitude: longitude,
                    timestamp: currentTime,
                    elevation: currentElevation,
                    hasElevation: hasElevation,
                    startsNewSegment: startsNewSegment
                ))
                startsNewSegment = false
            }
        default: break
        }
        currentElement = ""
        text = ""
    }
}
