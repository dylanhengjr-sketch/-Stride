import SwiftUI
import SwiftData

@main
struct StrideApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let modelContainer: ModelContainer
    private let store: LocalDatabaseStore
    private let settings: AppSettings
    private let locationService: LocationManagerService
    @StateObject private var sessionController: WorkoutSessionController

    init() {
        let schema = Schema([
            WorkoutActivity.self,
            TrackPoint.self,
            ActivitySplit.self,
            AppSettings.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize Stride SwiftData ModelContainer: \(error)")
        }

        let context = ModelContext(modelContainer)
        let dbStore = LocalDatabaseStore(modelContext: context) { contextToSave in
            if contextToSave.hasChanges {
                try contextToSave.save()
            }
        }
        let appSettings = dbStore.fetchOrCreateSettings()
        let locService = LocationManagerService()
        let controller = WorkoutSessionController(
            locationService: locService,
            store: dbStore,
            settings: appSettings
        )

        self.store = dbStore
        self.settings = appSettings
        self.locationService = locService
        self._sessionController = StateObject(wrappedValue: controller)
    }

    private var preferredColorScheme: ColorScheme? {
        switch settings.appearanceModeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                sessionController: sessionController,
                store: store,
                settings: settings
            )
            .onAppear {
                sessionController.restoreInProgressWorkoutIfAvailable()
            }
            .preferredColorScheme(preferredColorScheme)
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            let isBackgroundOrInactive = (newPhase == .inactive || newPhase == .background)
            sessionController.handleLifecycleTransition(isBackgroundOrInactive: isBackgroundOrInactive)
        }
    }
}
