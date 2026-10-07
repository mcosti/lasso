import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LassoWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
    }
}

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x21 / 255))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RideLockBadge(state: context.state).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RideBatteryText(state: context.state).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.lastEvent).lineLimit(1)
                        Spacer()
                        Text(context.state.updatedAt, style: .time)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.locked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(context.state.connected ? (context.state.locked ? .red : .green) : .gray)
            } compactTrailing: {
                Text(verbatim: context.state.battery.map { "\($0)%" } ?? "—").font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.locked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(context.state.connected ? (context.state.locked ? .red : .green) : .gray)
            }
        }
    }
}
