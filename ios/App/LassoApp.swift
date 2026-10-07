import SwiftUI
import UserNotifications

@main
struct LassoApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            if Demo.isActive && Demo.screen == "lockscreen" {
                DemoLockScreen()
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if !Demo.isActive {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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
