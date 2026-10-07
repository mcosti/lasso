import ActivityKit
import Foundation

/// Live Activity shown on the Lock Screen and in the Dynamic Island during a
/// ride. Updated by the app on Bluetooth events; it does not keep the app
/// alive, the bluetooth-central background mode does that.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var connected: Bool
        var locked: Bool
        var battery: Int?
        var voltage: Double?    // V
        var speed: Int
        var distance: Int       // m
        var reunlocks: Int
        var lastEvent: String
        var updatedAt: Date
    }

    var startedAt: Date
}
