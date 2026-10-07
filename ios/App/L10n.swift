import Foundation

/// Localized strings built in code (model titles, notifications, strings
/// assembled with prices or dates), following the in-app language picker.
/// SwiftUI `Text` literals follow the `\.locale` environment set in
/// `LassoApp` instead; both read the same setting.
///
/// `String(localized:locale:)` only uses the locale to format interpolated
/// values, it does not pick the language. The language comes from the bundle,
/// so a chosen language loads that `.lproj` folder directly.
enum L10n {
    /// "en", "nl", or nil to follow the system.
    static var languageCode: String? {
        // Demo launches (screenshots) are English unless `-lang` says otherwise.
        if Demo.launched { return Demo.language }
        let choice = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        return choice == "system" ? nil : choice
    }

    /// For SwiftUI's environment and for formatting numbers and dates.
    static var locale: Locale {
        languageCode.map { Locale(identifier: $0) } ?? .autoupdatingCurrent
    }

    static var bundle: Bundle {
        guard let code = languageCode,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle, locale: locale)
    }
}
