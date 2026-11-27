import SwiftUI

struct ContentView: View {
    @ObservedObject var sessionController: WorkoutSessionController
    @ObservedObject var store: LocalDatabaseStore
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            ActiveWorkoutView(
                sessionController: sessionController,
                settings: settings
            )
            .tabItem {
                Label("Workout", systemImage: "figure.run.circle.fill")
            }

            ActivityHistoryView(
                store: store,
                settings: settings
            )
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            StatisticsView(
                store: store,
                settings: settings
            )
            .tabItem {
                Label("Stats", systemImage: "chart.bar.fill")
            }

            SettingsView(
                settings: settings,
                store: store
            )
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }
}
