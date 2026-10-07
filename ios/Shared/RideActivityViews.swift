import SwiftUI

/// The Live Activity's Lock Screen card. Shared with the app so the
/// screenshot demo can render it outside ActivityKit.
struct RideLockScreenView: View {
    let state: RideActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RideLockBadge(state: state)
                Spacer()
                RideBatteryText(state: state)
            }
            HStack(spacing: 16) {
                Label("\(state.speed) km/h", systemImage: "speedometer")
                Label(String(format: "%.1f km", Double(state.distance) / 1000), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                if state.reunlocks > 0 {
                    Label("\(state.reunlocks)×", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(startedAt, style: .timer).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(state.lastEvent)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

struct RideLockBadge: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.locked ? "lock.fill" : "lock.open.fill")
            Text(state.connected ? (state.locked ? "Locked" : "Unlocked") : "Out of range")
        }
        .font(.headline)
        .foregroundStyle(state.connected ? (state.locked ? .red : .green) : .gray)
    }
}

struct RideBatteryText: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(state.battery.map { "\($0)%" } ?? "—").font(.headline).monospacedDigit()
            if let v = state.voltage {
                Text(String(format: "%.1f V", v)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
