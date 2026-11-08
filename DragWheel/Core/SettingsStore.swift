import AppKit
import Combine

enum OutputLocationMode: String, CaseIterable, Identifiable {
    case nextToOriginal
    case fixedFolder

    var id: String { rawValue }
    var label: String {
        switch self {
        case .nextToOriginal: return "Next to the original file"
        case .fixedFolder: return "Fixed folder"
        }
    }
}

enum TriggerModifier: String, CaseIterable, Identifiable {
    case shift, option, control, command

    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        case .command: return .command
        }
    }
    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        }
    }
}

/// UserDefaults-backed settings. Injectable defaults make it unit-testable.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let enabled = "enabled"
        static let outputMode = "outputMode"
        static let fixedFolder = "fixedFolderPath"
        static let quality = "imageQuality"
        static let trigger = "triggerModifier"
        static let wheelSize = "wheelSize"
        static let showUnavailable = "showUnavailable"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    @Published var outputMode: OutputLocationMode { didSet { defaults.set(outputMode.rawValue, forKey: Key.outputMode) } }
    @Published var fixedFolderPath: String { didSet { defaults.set(fixedFolderPath, forKey: Key.fixedFolder) } }
    /// JPEG / HEIC / WebP quality, 0.1...1.0
    @Published var imageQuality: Double { didSet { defaults.set(imageQuality, forKey: Key.quality) } }
    @Published var triggerModifier: TriggerModifier { didSet { defaults.set(triggerModifier.rawValue, forKey: Key.trigger) } }
    /// Wheel scale factor, 0.8...1.4
    @Published var wheelSize: Double { didSet { defaults.set(wheelSize, forKey: Key.wheelSize) } }
    @Published var showUnavailable: Bool { didSet { defaults.set(showUnavailable, forKey: Key.showUnavailable) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: true,
            Key.outputMode: OutputLocationMode.nextToOriginal.rawValue,
            Key.fixedFolder: "",
            Key.quality: 0.85,
            Key.trigger: TriggerModifier.shift.rawValue,
            Key.wheelSize: 1.0,
            Key.showUnavailable: true,
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        outputMode = OutputLocationMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "") ?? .nextToOriginal
        fixedFolderPath = defaults.string(forKey: Key.fixedFolder) ?? ""
        imageQuality = min(1, max(0.1, defaults.double(forKey: Key.quality)))
        triggerModifier = TriggerModifier(rawValue: defaults.string(forKey: Key.trigger) ?? "") ?? .shift
        wheelSize = min(1.4, max(0.8, defaults.double(forKey: Key.wheelSize)))
        showUnavailable = defaults.bool(forKey: Key.showUnavailable)
    }

    var conversionOptions: ConversionOptions {
        ConversionOptions(imageQuality: imageQuality)
    }

    var fixedFolderURL: URL? {
        fixedFolderPath.isEmpty ? nil : URL(fileURLWithPath: fixedFolderPath, isDirectory: true)
    }
}
