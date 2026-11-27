import SwiftUI
import UniformTypeIdentifiers

struct ActivityDetailView: View {
    let activity: WorkoutActivity
    @Bindable var settings: AppSettings
    let store: LocalDatabaseStore
    @State private var exportDocument: StrideDataDocument?
    @State private var showingExporter = false
    @State private var exportError: String?

    var body: some View {
        List {
            if activity.trackPoints.contains(where: \.isAccepted) {
                Section("Route") {
                    RouteMapView(points: activity.trackPoints)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Summary") {
                LabeledContent("Activity", value: activity.activityType.displayName)
                LabeledContent("Distance", value: formattedDistance)
                LabeledContent("Moving Time", value: activity.hasUnavailableMovingMetrics ? "—" : formattedDuration(activity.movingTimeSeconds))
                LabeledContent("Elapsed Time", value: formattedDuration(activity.elapsedTimeSeconds))
                LabeledContent("Avg Pace", value: activity.hasUnavailableMovingMetrics ? "—" : formattedPace(activity.averagePaceSecPerKm))
                LabeledContent("Avg Speed", value: activity.hasUnavailableMovingMetrics ? "—" : formattedSpeed(activity.averageSpeedMPS))
                LabeledContent("Elevation Gain", value: String(format: "%.1f m", activity.elevationGainMeters))
                LabeledContent("Elevation Loss", value: String(format: "%.1f m", activity.elevationLossMeters))
                LabeledContent("Calories", value: activity.hasUnavailableMovingMetrics ? "—" : String(format: "%.0f kcal", activity.estimatedCalories))
            }

            if !activity.splits.isEmpty {
                Section("Splits") {
                    ForEach(activity.splits.sorted { $0.splitIndex < $1.splitIndex }) { split in
                        HStack {
                            Text("Split \(split.splitIndex)")
                            Spacer()
                            Text(formattedDuration(split.durationSeconds))
                                .monospacedDigit()
                            Text(formattedPace(split.averagePaceSecPerKm))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Export") {
                Button("Export GPX Route") {
                    do {
                        exportDocument = StrideDataDocument(data: try makeGPXData())
                        showingExporter = true
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            }

            Section("Route Points") {
                let accepted = activity.trackPoints.filter(\.isAccepted)
                LabeledContent("Accepted Points", value: "\(accepted.count)")
                LabeledContent("Total Recorded Samples", value: "\(activity.trackPoints.count)")
            }
        }
        .navigationTitle(activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: UTType(filenameExtension: "gpx") ?? .xml,
            defaultFilename: "Stride-\(activity.id.uuidString).gpx"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("GPX Export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func makeGPXData() throws -> Data {
        try store.makeGPXData(for: activity)
    }

    private var formattedDistance: String {
        if settings.distanceUnitKilometers {
            return String(format: "%.2f km", activity.totalDistanceMeters / 1_000.0)
        } else {
            return String(format: "%.2f mi", activity.totalDistanceMeters / 1_609.344)
        }
    }

    private func formattedSpeed(_ mps: Double) -> String {
        if settings.distanceUnitKilometers {
            return String(format: "%.1f km/h", mps * 3.6)
        } else {
            return String(format: "%.1f mph", mps * 2.236936)
        }
    }

    private func formattedPace(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "--:--" }
        let adjusted = settings.distanceUnitKilometers ? secPerKm : (secPerKm * 1.609344)
        let total = Int(adjusted.rounded())
        let unit = settings.distanceUnitKilometers ? "/km" : "/mi"
        return String(format: "%d:%02d %@", total / 60, total % 60, unit)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let mins = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }
}
