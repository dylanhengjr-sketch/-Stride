import SwiftUI
import Charts

struct StatisticsView: View {
    @ObservedObject var store: LocalDatabaseStore
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            let completed = store.fetchCompletedActivities()
            let totalDistance = completed.reduce(0) { $0 + $1.totalDistanceMeters }
            let totalMovingTime = completed.reduce(0) { $0 + ($1.hasUnavailableMovingMetrics ? 0 : $1.movingTimeSeconds) }
            let excludedMovingTimeCount = completed.filter(\.hasUnavailableMovingMetrics).count
            let totalElevGain = completed.reduce(0) { $0 + $1.elevationGainMeters }
            let totalCalories = completed.filter { !$0.hasUnavailableMovingMetrics }.reduce(0) { $0 + $1.estimatedCalories }
            let now = Date()
            let calendar = Calendar.current
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
            let monthInterval = calendar.dateInterval(of: .month, for: now)
            let weeklyDistance = completed
                .filter { activity in
                    guard let weekInterval else { return false }
                    return activity.startDate >= weekInterval.start && activity.startDate < weekInterval.end
                }
                .reduce(0) { $0 + $1.totalDistanceMeters }
            let monthlyDistance = completed
                .filter { activity in
                    guard let monthInterval else { return false }
                    return activity.startDate >= monthInterval.start && activity.startDate < monthInterval.end
                }
                .reduce(0) { $0 + $1.totalDistanceMeters }

            List {
                Section("Goals") {
                    goalRow(title: "This Week", distance: weeklyDistance, goal: settings.weeklyGoalMeters)
                    goalRow(title: "This Month", distance: monthlyDistance, goal: settings.monthlyGoalMeters)
                }

                Section {
                    LabeledContent("Completed Workouts", value: "\(completed.count)")
                    LabeledContent("Total Distance", value: formatDistance(totalDistance))
                    LabeledContent("Total Moving Time", value: formatDuration(totalMovingTime))
                    LabeledContent("Total Elevation Gain", value: String(format: "%.1f m", totalElevGain))
                    LabeledContent("Total Calories", value: String(format: "%.0f kcal", totalCalories))
                } header: {
                    Text("Totals")
                } footer: {
                    if excludedMovingTimeCount > 0 {
                        Text("Moving time, pace, speed and calories exclude \(excludedMovingTimeCount) workout(s) without measured moving-time data (for example, imported GPX tracks).")
                    }
                }

                Section("Distance by Activity") {
                    Chart(ActivityType.allCases) { type in
                        let matching = completed.filter { $0.activityType == type }
                        let distance = matching.reduce(0) { $0 + $1.totalDistanceMeters }
                        BarMark(
                            x: .value("Activity", type.displayName),
                            y: .value("Distance", settings.distanceUnitKilometers ? distance / 1_000 : distance / 1_609.344)
                        )
                    }
                    .frame(height: 190)
                    .chartYAxisLabel(settings.distanceUnitKilometers ? "Kilometres" : "Miles")
                }

                Section("By Activity") {
                    ForEach(ActivityType.allCases) { type in
                        let matching = completed.filter { $0.activityType == type }
                        let dist = matching.reduce(0) { $0 + $1.totalDistanceMeters }
                        LabeledContent(type.displayName) {
                            Text("\(matching.count) · \(formatDistance(dist))")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("Statistics")
        }
    }

    @ViewBuilder
    private func goalRow(title: String, distance: Double, goal: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(formatDistance(distance)) / \(formatDistance(goal))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: goal > 0 ? min(distance / goal, 1) : 0)
            Text(goal > 0 && distance >= goal ? "Goal reached" : String(format: "%.0f%%", goal > 0 ? distance / goal * 100 : 0))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
