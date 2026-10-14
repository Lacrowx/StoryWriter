import Foundation

/// Monotonic times keep clock adjustments from delaying draft protection.
struct AutosaveSchedule {
    static let minimumInterval: TimeInterval = 10
    static let maximumWait: TimeInterval = 30
    private(set) var pendingSince: TimeInterval?
    private var lastEdit: TimeInterval?
    private var lastSave: TimeInterval?

    mutating func edited(at time: TimeInterval) {
        if pendingSince == nil { pendingSince = time }
        lastEdit = time
    }

    func deadline(idleDelay: TimeInterval) -> TimeInterval? {
        guard let pendingSince, let lastEdit else { return nil }
        let afterPause = max(lastEdit + idleDelay, (lastSave ?? -.infinity) + Self.minimumInterval)
        return min(afterPause, pendingSince + Self.maximumWait)
    }

    mutating func beganSave() { pendingSince = nil; lastEdit = nil }
    mutating func saved(at time: TimeInterval) { lastSave = time }
}
