import Foundation

extension Notification.Name {
    public static let claudegotchiPetDidChange = Notification.Name("claudegotchi.petDidChange")
}

// Callers (ApplyTransaction, TickDriver, MidnightDriver) MUST call this AFTER
// db.write(...) returns — never inside the closure (GRDB queue is non-reentrant).
public func postPetDidChange() {
    NotificationCenter.default.post(name: .claudegotchiPetDidChange, object: nil)
}
