import SwiftUI

/// Trial and Lifetime purchase sheet. Only reachable when `Store.isConfigured`.
struct PaywallView: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    private var price: String { store.lifetimePrice ?? "…" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.locked)
                    }
                    if busy {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .padding(20)
            }
            .background(Theme.surface.ignoresSafeArea())
            .toolbar { Button("Close") { dismiss() } }
            .task { await store.refresh() }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var header: some View {
        Image(systemName: store.access == .lifetime ? "checkmark.seal.fill" : "lock.open.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(store.access == .lifetime ? Theme.unlocked : Theme.accent)
        Text(title).font(.system(size: 28, weight: .black))
    }

    private var title: String {
        switch store.access {
        case .trial(let endsAt):
            L10n.string("Trial ends \(endsAt.formatted(Date.RelativeFormatStyle(presentation: .named, locale: L10n.locale)))")
        case .expired: L10n.string("Your trial has ended")
        case .lifetime: L10n.string("You own Lasso. Thank you.")
        default: L10n.string("Try Lasso free for 7 days")
        }
    }

    @ViewBuilder private var content: some View {
        switch store.access {
        case .lifetime:
            Text("Automatic re-unlock, the Live Activity and the log are yours to keep.")
                .font(.body).foregroundStyle(Theme.secondaryText)
            restoreButton
        case .trial:
            benefits
            Text("After the trial, automatic re-unlock stops; the manual buttons and the log keep working. Keep it forever for \(price) (one-time purchase, no subscription).")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            primary("Buy Lifetime \(price)") { try await store.buyLifetime() }
            restoreButton
        case .expired:
            Text("Lasso no longer unlocks the bike by itself after a battery drop. The Unlock, Lock and Lights buttons and the log keep working. Buy Lifetime once to turn automatic re-unlock back on; there is no subscription.")
                .font(.body).foregroundStyle(Theme.secondaryText)
            primary("Buy Lifetime \(price)") { try await store.buyLifetime() }
            restoreButton
        default:
            benefits
            Text("The trial lasts 7 days. After it ends, automatic re-unlock stops; the manual buttons and the log keep working. Keep it forever for \(price) (one-time purchase, no subscription).")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            primary("Start free trial") { try await store.startTrial() }
            secondary("Buy Lifetime \(price)") { try await store.buyLifetime() }
            restoreButton
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("bolt.fill", "Automatic re-unlock when the bike locks itself after a battery drop mid-ride")
            bullet("platter.filled.top.iphone", "Live Activity on the Lock Screen and in the Dynamic Island")
            bullet("list.bullet.rectangle", "A detailed log of every connection, lock and unlock")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bullet(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.subheadline)
        }
    }

    private func primary(_ title: LocalizedStringKey, _ action: @escaping () async throws -> Void) -> some View {
        Button { run(action) } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)
    }

    private func secondary(_ title: LocalizedStringKey, _ action: @escaping () async throws -> Void) -> some View {
        Button { run(action) } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .disabled(busy)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") { run { try await store.restore() } }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .disabled(busy)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await action()
            } catch where !Store.isCancellation(error) {
                self.error = error.localizedDescription
            } catch {}
            busy = false
        }
    }
}
