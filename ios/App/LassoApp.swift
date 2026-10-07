import SwiftUI
import UserNotifications

@main
struct LassoApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Applies the in-app language. SwiftUI `Text` literals look themselves up in
/// the String Catalog using the `\.locale` environment; strings built in code
/// go through `L10n`, which reads the same setting. Observing the settings
/// re-renders everything as soon as the picker changes, no restart needed.
struct RootView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        content
            .environment(\.locale, locale)
    }

    @ViewBuilder private var content: some View {
        if Demo.isActive && Demo.screen == "lockscreen" {
            DemoLockScreen()
        } else if !settings.onboardingDone && !Demo.launched {
            OnboardingView(settings: settings)
        } else {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }

    /// `L10n.locale` is the system locale for "system", so the environment
    /// is then left as SwiftUI would set it.
    private var locale: Locale {
        _ = settings.appLanguage // re-evaluate when the picker changes
        return L10n.locale
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Notification permission is asked in the onboarding (or from Settings), not here.
        // Before the bike connects, so the first policy decision knows the access.
        Store.shared.configure()
        // Creating the manager is what (re)establishes the pending connection,
        // also when iOS relaunches the app in the background for a Bluetooth event.
        BikeManager.shared.start()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
