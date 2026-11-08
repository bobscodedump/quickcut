import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    private let tools = ToolLocator.shared

    var body: some View {
        Form {
            Section("Output") {
                Picker("Save converted files", selection: $settings.outputMode) {
                    ForEach(OutputLocationMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.outputMode == .fixedFolder {
                    HStack {
                        Text(settings.fixedFolderPath.isEmpty ? "No folder chosen" : settings.fixedFolderPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(settings.fixedFolderPath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("JPEG / HEIC / WebP quality")
                        Spacer()
                        Text("\(Int(settings.imageQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.imageQuality, in: 0.1...1.0)
                }
            }
            Section("Wheel") {
                Picker("Trigger key", selection: $settings.triggerModifier) {
                    ForEach(TriggerModifier.allCases) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Wheel size")
                        Spacer()
                        Text("\(Int(settings.wheelSize * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.wheelSize, in: 0.8...1.4)
                }
                Toggle("Show greyed-out unavailable formats", isOn: $settings.showUnavailable)
            }
            Section("Tools") {
                toolRow("ffmpeg", hint: "brew install ffmpeg")
                toolRow("cwebp", hint: "brew install webp")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toolRow(_ name: String, hint: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let url = tools.locate(name) {
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            } else {
                Text("Not found — \(hint)").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.fixedFolderPath = url.path }
    }
}
