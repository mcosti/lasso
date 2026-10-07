import Foundation

/// The one place the product name lives in code. The bundle display name is
/// set in project.yml; keep the two in sync.
enum AppInfo {
    static let name = "Lasso"
    /// Shown in Settings; the app is an independent project.
    static let disclaimer = "Lasso is an independent app and is not affiliated with or endorsed by Cowboy SA. Cowboy is a trademark of its owner."
    /// Empty hides the support button (open-source builds).
    static let supportEmail = ""
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
