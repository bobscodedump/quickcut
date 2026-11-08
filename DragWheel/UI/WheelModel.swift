import SwiftUI

struct WheelSlice: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let isEnabled: Bool
    let disabledReason: String?
    var isMore = false
}

/// Builds the slices: up to 8 on the main ring; otherwise the 7 most common + "More…" and a second ring.
enum WheelLayout {
    static let maxPrimary = 8

    static func build(targets: [FormatTarget], showUnavailable: Bool) -> (primary: [WheelSlice], secondary: [WheelSlice]) {
        let slices = targets
            .filter { showUnavailable || $0.availability.isAvailable }
            .map {
                WheelSlice(
                    id: $0.format.id, title: $0.format.displayName, symbol: $0.format.symbolName,
                    isEnabled: $0.availability.isAvailable, disabledReason: $0.availability.reason
                )
            }
        guard slices.count > maxPrimary else { return (slices, []) }
        let more = WheelSlice(id: "more", title: "More…", symbol: "ellipsis.circle", isEnabled: true, disabledReason: nil, isMore: true)
        return (Array(slices.prefix(maxPrimary - 1)) + [more], Array(slices.dropFirst(maxPrimary - 1)))
    }
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var primary: [WheelSlice] = []
    @Published var secondary: [WheelSlice] = []
    @Published var hovered: SliceRef?
    @Published var expanded = false
    @Published var isPresented = false
    @Published var centerTitle = ""
    @Published var centerSubtitle = ""
    @Published var scale: CGFloat = 1
    /// Non-nil → show a small message bubble instead of the wheel.
    @Published var message: String?

    func slice(at ref: SliceRef?) -> WheelSlice? {
        guard let ref else { return nil }
        let list = ref.ring == .primary ? primary : secondary
        return list.indices.contains(ref.index) ? list[ref.index] : nil
    }
}
