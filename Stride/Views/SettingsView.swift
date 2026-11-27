import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @ObservedObject var store: LocalDatabaseStore

    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: StrideDataDocument?
    @State private var exportFilename = "Stride-Backup.json"
    @State private var exportContentType: UTType = .json
    @State private var transferError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Units & Body Weight") {
                    Toggle("Use Kilometers", isOn: $settings.distanceUnitKilometers)
                    Stepper(
                        value: $settings.userWeightKg,
                        in: 35...200,
                        step: 1.0
                    ) {
                        LabeledContent("Weight", value: String(format: "%.0f kg", settings.userWeightKg))
                    }
                }

                Section("Auto-Pause & Sensors") {
                    Toggle("Automatic Pause", isOn: $settings.autoPauseEnabled)
                    Toggle("Barometric Elevation", isOn: $settings.useBarometerWhenAvailable)
                    Stepper(
                        value: $settings.maxHorizontalAccuracyMeters,
                        in: 5...100,
                        step: 5
                    ) {
                        LabeledContent("Max GPS Accuracy", value: String(format: "%.0f m", settings.maxHorizontalAccuracyMeters))
                    }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearanceModeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }

                Section("Fitness Goals") {
                    Stepper(value: $settings.weeklyGoalMeters, in: 1_000...200_000, step: 1_000) {
                        LabeledContent("Weekly Goal", value: formatGoal(settings.weeklyGoalMeters))
                    }
                    Stepper(value: $settings.monthlyGoalMeters, in: 5_000...800_000, step: 5_000) {
                        LabeledContent("Monthly Goal", value: formatGoal(settings.monthlyGoalMeters))
                    }
                }

                Section("Import & Backup") {
                    Button("Export JSON Backup") {
                        do {
                            exportDocument = StrideDataDocument(data: try store.makeJSONBackup())
                            exportFilename = "Stride-Backup.json"
                            exportContentType = .json
                            showingExporter = true
                        } catch {
                            transferError = error.localizedDescription
                        }
                    }
                    Button("Import GPX or JSON Backup") {
                        showingImporter = true
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.distanceUnitKilometers) { _, _ in persistSettings() }
            .onChange(of: settings.userWeightKg) { _, _ in persistSettings() }
            .onChange(of: settings.autoPauseEnabled) { _, _ in persistSettings() }
            .onChange(of: settings.autoPauseSpeedThresholdMPS) { _, _ in persistSettings() }
            .onChange(of: settings.maxHorizontalAccuracyMeters) { _, _ in persistSettings() }
            .onChange(of: settings.useBarometerWhenAvailable) { _, _ in persistSettings() }
            .onChange(of: settings.appearanceModeRaw) { _, _ in persistSettings() }
            .onChange(of: settings.weeklyGoalMeters) { _, _ in persistSettings() }
            .onChange(of: settings.monthlyGoalMeters) { _, _ in persistSettings() }            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json, .xml, UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: false
            ) { result in
                importSelectedFile(result)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                if case .failure(let error) = result {
                    transferError = error.localizedDescription
                }
            }
            .alert("File Operation", isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )) {
                Button("OK", role: .cancel) { transferError = nil }
            } message: {
                Text(transferError ?? "")
            }
        }
    }

    private func persistSettings() {
        guard store.saveSettings() else {
            transferError = store.lastSaveError ?? "Settings could not be saved. Check device storage."
            return
        }
    }

    private func formatGoal(_ meters: Double) -> String {
        settings.distanceUnitKilometers
            ? String(format: "%.0f km", meters / 1_000)
            : String(format: "%.0f mi", meters / 1_609.344)
    }

    private func importSelectedFile(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "gpx" {
                try store.importGPX(data)
            } else if url.pathExtension.lowercased() == "json" {
                try store.importJSONBackup(data)
            } else {
                throw NSError(domain: "StrideTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a .gpx or .json file."])
            }
        } catch {
            transferError = error.localizedDescription
        }
    }
}

struct StrideDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .xml, UTType(filenameExtension: "gpx") ?? .xml] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
