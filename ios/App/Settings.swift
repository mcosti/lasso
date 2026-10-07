import Foundation
import SwiftUI

/// When the app unlocks the bike by itself.
enum AutoUnlockMode: String, CaseIterable, Identifiable {
    /// Only re-unlock a bike that locked itself mid-ride: a reconnect shortly
    /// after an unexpected disconnect, or a lock while the bike was moving.
    /// Locking it on purpose (official app, auto-lock when parked) is respected.
    case ride
    /// Unlock every time the phone connects, like the official Auto Unlock but
    /// without waiting for the bike to be moved.
    case always
    /// Watch and log only. The Unlock / Lock buttons still work.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ride: L10n.string("During a ride")
        case .always: L10n.string("Always")
        case .off: L10n.string("Off")
        }
    }

    var explanation: String {
        switch self {
        case .ride:
            L10n.string("Re-unlocks the bike when it locks itself while you are riding, for example after a battery hiccup. Locking it on purpose, or the bike's own auto-lock when parked, is left alone.")
        case .always:
            L10n.string("Unlocks the bike every time your phone connects to it, no matter how it got locked.")
        case .off:
            L10n.string("Only watches the bike and keeps the log. Use the buttons to lock and unlock by hand.")
        }
    }
}

/// A bundle of mechanism settings, so alternatives can be tried in one tap.
struct MechanismPreset: Identifiable, Equatable {
    /// Not translated: short names people mention in support mails.
    let name: String
    let withResponse: Bool
    let delay: Double
    let retries: Int
    let retryInterval: Double
    let pollInterval: Double
    let undoAnyLock: Bool

    var id: String { name }

    /// Computed so it follows the in-app language picker.
    var summary: String {
        switch name {
        case "Default": L10n.string("Write with response, 1 s after reconnect, 3 retries every 2 s.")
        case "Patient": L10n.string("Gives a rebooting bike 3 s, then 5 retries every 3 s.")
        case "Key fob": L10n.string("Write without response like the nRF fob, 0.5 s delay, 5 retries every 1 s.")
        case "Aggressive": L10n.string("0.5 s delay, 6 retries every 1.5 s, polls the lock every 5 s and undoes any lock during a ride. Lock from this app.")
        default: ""
        }
    }

    static let all: [MechanismPreset] = [
        MechanismPreset(name: "Default",
                        withResponse: true, delay: 1, retries: 3, retryInterval: 2, pollInterval: 0, undoAnyLock: false),
        MechanismPreset(name: "Patient",
                        withResponse: true, delay: 3, retries: 5, retryInterval: 3, pollInterval: 0, undoAnyLock: false),
        MechanismPreset(name: "Key fob",
                        withResponse: false, delay: 0.5, retries: 5, retryInterval: 1, pollInterval: 0, undoAnyLock: false),
        MechanismPreset(name: "Aggressive",
                        withResponse: true, delay: 0.5, retries: 6, retryInterval: 1.5, pollInterval: 5, undoAnyLock: true),
    ]
}

/// User preferences and the little bit of ride state that has to survive the
/// app being relaunched by iOS for a Bluetooth event.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("autoUnlockMode") var modeRaw = AutoUnlockMode.ride.rawValue
    /// A reconnect this soon after a disconnect counts as the same ride.
    @AppStorage("reconnectWindow") var reconnectWindow: Double = 60
    /// A lock this soon after the bike was last seen moving is a glitch.
    @AppStorage("movingGrace") var movingGrace: Double = 15
    @AppStorage("notifyOnReunlock") var notifyOnReunlock = true
    @AppStorage("notifyOnLockChange") var notifyOnLockChange = false
    /// Lock Screen / Dynamic Island card while a ride is active.
    @AppStorage("liveActivity") var liveActivity = true
    @AppStorage("bikePeripheralID") var bikePeripheralID = ""

    // Mechanism switches, so an alternative can be tried without a rebuild.
    /// Write the unlock byte with or without a response from the bike.
    @AppStorage("unlockWithResponse") var unlockWithResponse = true
    /// Seconds to wait after a reconnect before sending the unlock.
    @AppStorage("unlockDelay") var unlockDelay: Double = 1
    @AppStorage("unlockRetries") var unlockRetries = 3
    @AppStorage("unlockRetryInterval") var unlockRetryInterval: Double = 2
    /// 0 = off. Reads the lock state this often during a ride, in case the
    /// bike does not notify a change.
    @AppStorage("lockPollInterval") var lockPollInterval: Double = 0
    /// Undo every lock during a ride, not only those while moving. Lock the
    /// bike from this app (which ends the ride) instead of the official one.
    @AppStorage("undoAnyLockDuringRide") var undoAnyLockDuringRide = false
    /// Subscribe to the dashboard stream (speed, battery, …).
    @AppStorage("liveDashboard") var liveDashboard = true
    /// Log what would be done instead of writing the unlock.
    @AppStorage("dryRun") var dryRun = false
    /// Shows the Testing section in Settings. Toggled by tapping Version 7 times.
    @AppStorage("developerMode") var developerMode = false
    /// The onboarding pages were completed (or skipped) once.
    @AppStorage("onboardingDone") var onboardingDone = false
    /// The trial terms were presented once, when the first bike was paired.
    @AppStorage("paywallShown") var paywallShown = false
    /// "system", "en" or "nl". Read by `L10n` and the root view's locale.
    @AppStorage("appLanguage") var appLanguage = "system"

    // Ride state. Persisted because iOS may relaunch the app mid-ride.
    @AppStorage("rideActive") var rideActive = false
    @AppStorage("lastDisconnectAt") var lastDisconnectAt: Double = 0
    @AppStorage("lastMovingAt") var lastMovingAt: Double = 0

    var mode: AutoUnlockMode {
        get { AutoUnlockMode(rawValue: modeRaw) ?? .ride }
        set { modeRaw = newValue.rawValue }
    }

    var currentPreset: MechanismPreset? {
        MechanismPreset.all.first { p in
            p.withResponse == unlockWithResponse && p.delay == unlockDelay && p.retries == unlockRetries
                && p.retryInterval == unlockRetryInterval && p.pollInterval == lockPollInterval
                && p.undoAnyLock == undoAnyLockDuringRide
        }
    }

    func apply(_ p: MechanismPreset) {
        unlockWithResponse = p.withResponse
        unlockDelay = p.delay
        unlockRetries = p.retries
        unlockRetryInterval = p.retryInterval
        lockPollInterval = p.pollInterval
        undoAnyLockDuringRide = p.undoAnyLock
    }

    var bikeID: UUID? {
        get { UUID(uuidString: bikePeripheralID) }
        set { bikePeripheralID = newValue?.uuidString ?? "" }
    }

    private init() {}
}
