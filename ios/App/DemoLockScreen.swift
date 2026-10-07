import SwiftUI

/// A stand-in for the iOS Lock Screen, showing the Live Activity card and the
/// re-unlock notification the way they appear on a phone. Only reachable in
/// demo mode (`-demo -screen lockscreen`), for App Store screenshots: the
/// Simulator cannot capture its real Lock Screen with a Live Activity on it.
struct DemoLockScreen: View {
    private let state = RideActivityAttributes.ContentState(
        connected: true, locked: false, battery: 54, voltage: 37.65, speed: 21, distance: 3400,
        reunlocks: 1, lastEvent: "Bike unlocked again", updatedAt: Date())

    /// Matches the 9:41 the screenshot script puts in the status bar.
    private let clock = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.10),
                                    Color(red: 0.36, green: 0.19, blue: 0.08),
                                    Color(red: 0.10, green: 0.07, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                Text(clock, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(clock, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, -6)
                Spacer()
                VStack(spacing: 10) {
                    RideLockScreenView(state: state, startedAt: Demo.rideStartedAt)
                        .background(Theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    HStack(spacing: 12) {
                        Image("NotificationIcon")
                            .resizable().scaledToFit()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Bike unlocked again").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("now").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(AppInfo.name) re-unlocked your bike.").font(.subheadline)
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(.horizontal, 16)
                Spacer().frame(height: 120)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}
