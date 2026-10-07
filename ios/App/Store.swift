import Foundation
import RevenueCat
import UserNotifications

/// Purchases for the App Store build: a free 7-day trial and a one-time
/// Lifetime unlock. Both are non-consumables in App Store Connect; the trial
/// is the Price Tier 0 "7-day Trial" product (guideline 3.1.1).
///
/// The RevenueCat key comes from the `RevenueCatAPIKey` Info.plist entry,
/// filled from the `REVENUECAT_API_KEY` build setting. When it is empty (the
/// open-source build) or in demo mode, everything is free and RevenueCat is
/// never touched.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    enum Access: Equatable {
        /// No purchases in this build.
        case open
        /// Purchases exist but the trial has not been started.
        case none
        case trial(endsAt: Date)
        case expired
        case lifetime
        /// Not loaded yet and nothing cached.
        case unknown
    }

    static let trialProductID = "lasso.trial7"
    static let lifetimeProductID = "lasso.lifetime"
    static let trialEntitlement = "trial"
    static let lifetimeEntitlement = "lifetime"
    static let trialLength: TimeInterval = 7 * 24 * 3600

    @Published private(set) var access: Access = .unknown
    @Published private(set) var lifetimePrice: String?

    let apiKey: String
    var isConfigured: Bool { !apiKey.isEmpty && !Demo.isActive }

    private var trialProduct: StoreProduct?
    private var lifetimeProduct: StoreProduct?
    private var lifetimePackage: Package?
    private var started = false
    private var streamTask: Task<Void, Never>?

    private static let cacheKey = "storeAccess"

    private init() {
        apiKey = (Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        access = isConfigured ? Self.cachedAccess() : .open
    }

    /// Automatic unlocks are allowed. Unknown counts as allowed so a network
    /// hiccup on first launch never leaves a rider locked.
    var canAutoUnlock: Bool {
        switch access {
        case .open, .lifetime, .unknown: true
        case .trial(let endsAt): Date() < endsAt
        case .none, .expired: false
        }
    }

    func configure() {
        guard isConfigured, !started else { return }
        started = true
        #if DEBUG
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: apiKey)
        streamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard isConfigured, started else { return }
        if let info = try? await Purchases.shared.customerInfo() {
            apply(info)
        }
        if let offering = try? await Purchases.shared.offerings().current {
            lifetimePackage = offering.availablePackages.first { $0.storeProduct.productIdentifier == Self.lifetimeProductID }
        }
        let products = await Purchases.shared.products([Self.trialProductID, Self.lifetimeProductID])
        trialProduct = products.first { $0.productIdentifier == Self.trialProductID }
        lifetimeProduct = lifetimePackage?.storeProduct ?? products.first { $0.productIdentifier == Self.lifetimeProductID }
        lifetimePrice = lifetimeProduct?.localizedPriceString
    }

    func startTrial() async throws {
        guard isConfigured else { return }
        if trialProduct == nil { await refresh() }
        guard let product = trialProduct else { throw StoreError.productUnavailable }
        let result = try await Purchases.shared.purchase(product: product)
        guard !result.userCancelled else { return }
        apply(result.customerInfo)
        EventLog.shared.add(.info, "Free trial started")
    }

    func buyLifetime() async throws {
        guard isConfigured else { return }
        if lifetimeProduct == nil { await refresh() }
        let result: PurchaseResultData
        if let lifetimePackage {
            result = try await Purchases.shared.purchase(package: lifetimePackage)
        } else if let lifetimeProduct {
            result = try await Purchases.shared.purchase(product: lifetimeProduct)
        } else {
            throw StoreError.productUnavailable
        }
        guard !result.userCancelled else { return }
        apply(result.customerInfo)
        EventLog.shared.add(.info, "Lifetime purchased")
    }

    func restore() async throws {
        guard isConfigured else { return }
        let info = try await Purchases.shared.restorePurchases()
        apply(info)
        EventLog.shared.add(.info, "Purchases restored")
    }

    /// True for errors the user caused by backing out of the sheet.
    static func isCancellation(_ error: Error) -> Bool {
        if let code = error as? RevenueCat.ErrorCode { return code == .purchaseCancelledError }
        return (error as NSError).code == RevenueCat.ErrorCode.purchaseCancelledError.rawValue
            && (error as NSError).domain == RevenueCat.ErrorCode.errorDomain
    }

    // MARK: - Access

    private func apply(_ info: CustomerInfo) {
        let new = Self.access(from: info)
        guard new != access else { return }
        let old = access
        access = new
        Self.cache(new)
        Self.scheduleTrialEndNotification(for: new)
        if old != .unknown || new == .expired {
            EventLog.shared.add(.info, "Access changed: \(Self.describe(new))")
        }
    }

    /// A local notification at the end of the trial, so the rider learns that
    /// automatic re-unlock is off before the next battery drop. Replaced on
    /// every access change and removed once Lifetime is owned (or the trial
    /// is already over). Silently does nothing without notification permission.
    private static let trialEndNotificationID = "trialEnded"

    private static func scheduleTrialEndNotification(for access: Access) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [trialEndNotificationID])
        guard case .trial(let endsAt) = access, endsAt > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.string("Your Lasso trial has ended")
        content.body = L10n.string("Automatic re-unlock is off. Keep it forever with a one-time purchase in Lasso.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, endsAt.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: trialEndNotificationID, content: content, trigger: trigger))
    }

    private static func access(from info: CustomerInfo) -> Access {
        if info.entitlements[lifetimeEntitlement]?.isActive == true { return .lifetime }
        if info.nonSubscriptions.contains(where: { $0.productIdentifier == lifetimeProductID }) { return .lifetime }
        let trialStart = info.nonSubscriptions
            .filter { $0.productIdentifier == trialProductID }
            .map(\.purchaseDate).min()
            ?? info.entitlements[trialEntitlement]?.originalPurchaseDate
        guard let trialStart else { return .none }
        let endsAt = trialStart.addingTimeInterval(trialLength)
        return Date() < endsAt ? .trial(endsAt: endsAt) : .expired
    }

    static func describe(_ access: Access) -> String {
        switch access {
        case .open: "open build"
        case .none: "no trial yet"
        case .trial(let endsAt): "trial until \(endsAt.formatted(date: .abbreviated, time: .shortened))"
        case .expired: "trial ended"
        case .lifetime: "lifetime"
        case .unknown: "unknown"
        }
    }

    /// The last known access, so an offline relaunch keeps honouring an
    /// ended trial instead of falling back to unknown (allowed).
    private static func cachedAccess() -> Access {
        guard let raw = UserDefaults.standard.string(forKey: cacheKey) else { return .unknown }
        switch raw {
        case "none": return .none
        case "expired": return .expired
        case "lifetime": return .lifetime
        default:
            if raw.hasPrefix("trial:"), let t = Double(raw.dropFirst(6)) {
                let endsAt = Date(timeIntervalSince1970: t)
                return Date() < endsAt ? .trial(endsAt: endsAt) : .expired
            }
            return .unknown
        }
    }

    private static func cache(_ access: Access) {
        let raw: String? = switch access {
        case .none: "none"
        case .expired: "expired"
        case .lifetime: "lifetime"
        case .trial(let endsAt): "trial:\(endsAt.timeIntervalSince1970)"
        case .open, .unknown: nil
        }
        UserDefaults.standard.set(raw, forKey: cacheKey)
    }

    enum StoreError: LocalizedError {
        case productUnavailable
        var errorDescription: String? { L10n.string("The App Store did not return this product. Check your connection and try again.") }
    }
}
