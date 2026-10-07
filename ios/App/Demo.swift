import Foundation

/// Fake bike for the Simulator, driven by launch arguments. Used by the
/// screenshot UI tests (`-demo -screen home|log|lockscreen`); never active
/// on a device launched normally.
enum Demo {
    /// Launched with `-demo` (UI tests). Bluetooth is never started.
    static let launched = ProcessInfo.processInfo.arguments.contains("-demo")
    /// Entered from the pairing screen at runtime, for App Review and for
    /// people without a bike nearby. See `BikeManager.enterDemo()`.
    static var runtime = false
    static var isActive: Bool { launched || runtime }

    /// Which screen to open straight away, if any.
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Mid-ride numbers, consistent across the home screen and the Live Activity.
    static var dashboard: Dashboard {
        var d = Dashboard()
        d.tripId = 916150592
        d.speed = 21
        d.power = 165
        d.battery = 54
        d.batteryVoltage = 37650
        d.batteryTemp = Float((24 + 273.15) * 10)
        d.distance = 3400
        d.duration = 11 * 60 + 42
        d.assistance = 2
        d.pedalTorque = 23
        d.updatedAt = Date()
        return d
    }

    static let rideStartedAt = Date().addingTimeInterval(-(11 * 60 + 42))
    static let connectedSince = Date().addingTimeInterval(-128)
    static let reunlocks = 1

    /// The exact sequence a real battery drop produced on the bike, with
    /// timestamps shifted so it reads as "just now".
    static func logEntries() -> [EventLog.Entry] {
        typealias K = EventLog.Entry.Kind
        let now = Date()
        let events: [(Double, K, String)] = [
            (83, .info, "Signal changed -98 → -87 dBm"),
            (129, .info, "New trip id 916150592"),
            (129, .info, "UART reply motor read → 8"),
            (129, .info, "UART reply ff01"),
            (130, .lock, "Bike unlocked lock=unlocked batt=55% 36.84V 24°C dash 0s ago speed=10 trip=555287944 rssi=-98 ride=on app=bg"),
            (130, .info, "Bike acknowledged lock write"),
            (130, .info, "Write 01 with response"),
            (130, .unlock, "Sending unlock (attempt 1): locked 0 s after last movement"),
            (130, .lock, "Bike locked lock=locked batt=55% 36.84V 24°C dash 0s ago speed=10 trip=555287944 rssi=-98 ride=on app=bg"),
            (142, .info, "UART reply battery read → 55"),
            (142, .info, "UART reply motor read → 8"),
            (145, .lock, "Bike is unlocked on connect (3 s after disconnect) lock=unlocked batt=55% 37.82V 24°C dash 0s ago speed=0 trip=555287944 rssi=-98 ride=on app=bg"),
            (145, .info, "Service 6E400001: 6E400002 [Ww], 6E400003 [N]"),
            (145, .info, "Service C0B0A000: C0B0A001 [RWN], C0B0A00A [N]"),
            (145, .info, "Services: [C0B0A000, 6E400001]"),
            (146, .connection, "Connected (3 s after disconnect) lock=unknown batt=55% 37.82V 24°C dash 4s ago speed=0 trip=555287944 rssi=-98 ride=on app=bg"),
            (149, .info, "Drop mid-ride; will re-unlock if the bike is back within 60 s"),
            (149, .connection, "Disconnected after 1842.0 s: CBErrorDomain 7: The specified device has disconnected from us. | lock=unlocked batt=55% 37.82V 24°C dash 1s ago speed=12 trip=555287944 rssi=-98 ride=on app=bg"),
            (209, .info, "Signal changed -88 → -98 dBm"),
            (1991, .connection, "Connected (first connection) lock=unknown speed=0 ride=off app=fg"),
            (1992, .info, "Live Activity started"),
            (1998, .info, "App started"),
        ]
        return events.map { EventLog.Entry(date: now.addingTimeInterval(-$0.0), kind: $0.1, message: $0.2) }.reversed()
    }
}
