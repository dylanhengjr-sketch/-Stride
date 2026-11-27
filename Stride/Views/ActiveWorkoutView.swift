import SwiftUI

struct ActiveWorkoutView: View {
    @ObservedObject var sessionController: WorkoutSessionController
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let banner = sessionController.statusBanner {
                        Text(banner)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let persistenceError = sessionController.persistenceError {
                        Text(persistenceError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if sessionController.state == .idle {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select Activity")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Picker("Activity", selection: $sessionController.selectedActivityType) {
                                ForEach(ActivityType.allCases) { type in
                                    Label(type.displayName, systemImage: type.systemImageName)
                                        .tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    } else {
                        HStack {
                            Label(
                                sessionController.selectedActivityType.displayName,
                                systemImage: sessionController.selectedActivityType.systemImageName
                            )
                            .font(.headline)
                            Spacer()
                            Text(stateLabel)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }

                    RouteMapView(points: sessionController.activeRoutePoints)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metricCard(title: "Distance", value: formattedDistance)
                        metricCard(title: "Moving Time", value: formattedDuration(sessionController.movingTimeSeconds))
                        metricCard(title: "Elapsed Time", value: formattedDuration(sessionController.elapsedTimeSeconds))
                        metricCard(title: "Current Pace", value: formattedPace(sessionController.currentPaceSecPerKm))
                        metricCard(title: "Avg Pace", value: formattedPace(sessionController.averagePaceSecPerKm))
                        metricCard(title: "Current Speed", value: formattedSpeed(sessionController.currentSpeedMPS))
                        metricCard(title: "Average Speed", value: formattedSpeed(sessionController.averageSpeedMPS))
                        metricCard(title: "Elev Gain", value: String(format: "%.1f m", sessionController.elevationGainMeters))
                        metricCard(title: "Calories", value: String(format: "%.0f kcal", sessionController.estimatedCalories))
                    }

                    controlsSection
                }
                .padding()
            }
            .navigationTitle("Stride")
        }
    }

    private var stateLabel: String {
        switch sessionController.state {
        case .idle:
            return "Ready"
        case .recording:
            return "Recording"
        case .paused(true):
            return "Auto-Paused"
        case .paused(false):
            return "Paused"
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        switch sessionController.state {
        case .idle:
            Button {
                sessionController.requestStartWorkout()
            } label: {
                Text("Start Workout")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)

        case .recording:
            HStack(spacing: 12) {
                Button {
                    sessionController.pauseWorkout(automatic: false)
                } label: {
                    Text("Pause")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    sessionController.finishWorkout()
                } label: {
                    Text("Finish")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
            }

        case .paused:
            HStack(spacing: 12) {
                Button {
                    sessionController.resumeWorkout()
                } label: {
                    Text("Resume")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    sessionController.finishWorkout()
                } label: {
                    Text("Finish")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    sessionController.discardWorkout()
                } label: {
                    Text("Discard")
                        .font(.headline)
                        .padding()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var formattedDistance: String {
        if settings.distanceUnitKilometers {
            return String(format: "%.2f km", sessionController.totalDistanceMeters / 1_000.0)
        } else {
            let miles = sessionController.totalDistanceMeters / 1_609.344
            return String(format: "%.2f mi", miles)
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
        let totalSeconds = Int(adjusted.rounded())
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        let unit = settings.distanceUnitKilometers ? "/km" : "/mi"
        return String(format: "%d:%02d %@", mins, secs, unit)
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
