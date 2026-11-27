import SwiftUI

struct ActivityHistoryView: View {
    @ObservedObject var store: LocalDatabaseStore
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            let completed = store.fetchCompletedActivities()
            List {
                if completed.isEmpty {
                    ContentUnavailableView(
                        "No Completed Workouts",
                        systemImage: "figure.walk",
                        description: Text("Finished workouts will appear here.")
                    )
                } else {
                    ForEach(completed) { activity in
                        NavigationLink {
                            ActivityDetailView(activity: activity, settings: settings, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.title)
                                    .font(.headline)
                                HStack(spacing: 12) {
                                    Text(formatDistance(activity.totalDistanceMeters))
                                    Text(activity.hasUnavailableMovingMetrics ? "—" : formatDuration(activity.movingTimeSeconds))
                                    Text(activity.hasUnavailableMovingMetrics ? "—" : formatPace(activity.averagePaceSecPerKm))
                                }
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if settings.distanceUnitKilometers {
            return String(format: "%.2f km", meters / 1_000.0)
        } else {
            return String(format: "%.2f mi", meters / 1_609.344)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "--:--" }
        let adjusted = settings.distanceUnitKilometers ? secPerKm : (secPerKm * 1.609344)
        let total = Int(adjusted.rounded())
        let unit = settings.distanceUnitKilometers ? "/km" : "/mi"
        return String(format: "%d:%02d %@", total / 60, total % 60, unit)
    }
}
