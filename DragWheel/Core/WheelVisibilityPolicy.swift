import Foundation

enum WheelZone: Equatable {
    /// Over the centre hub (right where the wheel spawns).
    case hub
    /// Over the slices.
    case ring
    /// Outside the wheel.
    case outside
}

/// Pure state machine deciding when the wheel appears and disappears during a file drag.
///
/// - Appears when the trigger is held and the wheel hasn't been dismissed.
/// - Before the pointer reaches the slices: releasing the trigger dismisses it.
/// - After the pointer reached the slices: leaving the wheel dismisses it; releasing the trigger doesn't.
/// - Esc or leaving dismisses it until the trigger has been released and pressed again.
struct WheelVisibilityPolicy {
    enum HideReason: Equatable { case triggerReleased, escape, leftWheel, dragEnded }
    enum Action: Equatable { case none, show, hide(HideReason) }

    private(set) var isShown = false
    private(set) var reachedSlices = false
    private(set) var suppressed = false

    mutating func update(triggerDown: Bool, escapeDown: Bool, zone: WheelZone) -> Action {
        if isShown {
            if escapeDown { return dismiss(.escape, suppress: true) }
            if zone == .ring { reachedSlices = true }
            if reachedSlices {
                if zone == .outside { return dismiss(.leftWheel, suppress: true) }
                return .none
            }
            if zone == .outside, triggerDown { return .none }
            if !triggerDown { return dismiss(.triggerReleased, suppress: false) }
            return .none
        }

        if !triggerDown { suppressed = false; return .none }
        if escapeDown { suppressed = true; return .none }
        if suppressed { return .none }
        isShown = true
        reachedSlices = false
        return .show
    }

    mutating func dragEnded() -> Action {
        defer { self = WheelVisibilityPolicy() }
        return isShown ? .hide(.dragEnded) : .none
    }

    private mutating func dismiss(_ reason: HideReason, suppress: Bool) -> Action {
        isShown = false
        reachedSlices = false
        suppressed = suppress
        return .hide(reason)
    }
}
