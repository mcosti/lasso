import SwiftUI
import UserNotifications

/// Three pages shown once on first launch: what Lasso does, how to set it up,
/// and an optional notifications step. The system permission prompt only
/// appears when the user asks for notifications here (or turns them on later
/// in Settings); declining keeps the app fully functional.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @State private var page = 0
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                howItWorks.tag(1)
                notifications.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .background(Theme.surface.ignoresSafeArea())
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: Pages

    private var welcome: some View {
        Page(symbol: "lock.open.fill", title: "Your bike, unlocked again") {
            Text("When a Cowboy's battery cuts out mid-ride, the bike locks itself. Lasso notices within a second and unlocks it again, so you can keep riding.")
            Text("Made for bikes with a faulty battery. Tested on a Cowboy 3 only.")
                .font(.footnote)
        }
    }

    private var howItWorks: some View {
        Page(symbol: "bicycle", title: "How it works") {
            Step(1, "Pair your phone with the bike in the official Cowboy app once.")
            Step(2, "Pick your bike from the list on the home screen.")
            Step(3, "Leave Lasso in the background; it re-unlocks the bike after a battery drop.")
            Text("Lasso talks to the bike over Bluetooth and keeps the connection while you ride. It never changes motor settings.")
                .font(.footnote)
        }
    }

    private var notifications: some View {
        Page(symbol: "bell.badge.fill", title: "Know when it happens") {
            Text("Lasso can send a notification each time it re-unlocks your bike. This is optional, and you can change it later in Settings.")
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if page < 2 {
            Button { withAnimation { page += 1 } } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboardingContinue")
        } else {
            VStack(spacing: 10) {
                Button {
                    busy = true
                    Task {
                        settings.notifyOnReunlock = await Notifications.request()
                        finish()
                    }
                } label: {
                    Text("Enable notifications").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)

                Button("Not now") {
                    settings.notifyOnReunlock = false
                    settings.notifyOnLockChange = false
                    finish()
                }
                .font(.subheadline)
                .disabled(busy)
            }
        }
    }

    private func finish() {
        withAnimation { settings.onboardingDone = true }
    }
}

// MARK: - Pieces

private struct Page<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 8)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            content
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.bottom, 32) // room for the page dots
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    init(_ number: Int, _ text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)
            Text(text)
        }
    }
}

/// The one place that asks iOS for notification permission.
enum Notifications {
    /// Asks when the user has not decided yet; otherwise just reports the
    /// current state. Returns whether notifications can be shown.
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}
