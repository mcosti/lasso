import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @ObservedObject private var bike = BikeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var log = EventLog.shared
    @ObservedObject private var store = Store.shared
    @State private var showSettings = false
    @State private var showPaywall = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if bike.hasBike {
                            StatusCard(bike: bike, settings: settings)
                            ActionButtons(bike: bike)
                            ModeCard(settings: settings)
                            if store.isConfigured, let text = TrialBanner.text(for: store.access) {
                                TrialBanner(text: text, ended: store.access == .expired) { showPaywall = true }
                            }
                        } else {
                            HowItWorksCard()
                            PairingCard(bike: bike)
                        }
                        LogCard(log: log).id("log")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .background(Theme.surface.ignoresSafeArea())
                .navigationTitle(AppInfo.name)
                .toolbar {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settings")
                }
                .sheet(isPresented: $showSettings) { SettingsScreen(bike: bike, settings: settings) }
                .sheet(isPresented: $showPaywall) { PaywallView(store: store) }
                .onAppear {
                    guard Demo.screen == "log" else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("log", anchor: .top)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                bike.appBecameActive()
                Task { await store.refresh() }
            }
        }
        .onChange(of: store.access, initial: true) { _, access in
            // Show the trial terms once, before any automatic unlock can happen.
            guard store.isConfigured, access == .none, !settings.paywallShown else { return }
            settings.paywallShown = true
            showPaywall = true
        }
    }
}

// MARK: - Status

struct StatusCard: View {
    @ObservedObject var bike: BikeManager
    @ObservedObject var settings: AppSettings

    private var lockColor: Color {
        switch bike.lockState {
        case .unlocked: Theme.unlocked
        case .locked: Theme.locked
        case .unknown: Theme.secondaryText
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Circle().fill(bike.connection == .connected ? Theme.unlocked : Theme.secondaryText)
                        .frame(width: 10, height: 10)
                    Text(bike.connection.title).font(.subheadline.weight(.medium))
                    Spacer()
                    if let since = bike.connectedSince {
                        Text("since \(since, style: .time)").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: bike.lockState == .unlocked ? "lock.open.fill" : "lock.fill")
                        .font(.title)
                    Text(lockTitle).font(.system(size: 34, weight: .black))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    if settings.rideActive {
                        Label("Ride active", systemImage: "figure.outdoor.cycle")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .foregroundStyle(lockColor)

                let d = bike.dashboard
                HStack(spacing: 0) {
                    Metric(value: d.battery.map { "\($0)%" }, unit: "battery")
                    Metric(value: d.batteryVoltage.map { String(format: "%.1f V", Double($0) / 1000) }, unit: "voltage")
                    Metric(value: d.batteryTempCelsius.map { String(format: "%.0f °C", $0) }, unit: "temp")
                }
                HStack(spacing: 0) {
                    Metric(value: "\(d.speed) km/h", unit: "speed")
                    Metric(value: "\(d.power) W", unit: "power")
                    Metric(value: String(format: "%.1f km", Double(d.distance) / 1000), unit: "trip")
                }
                if let sag = d.minLoadedVoltage {
                    Text(String(format: "Lowest voltage under load this ride: %.2f V at %d W", Double(sag) / 1000, d.minLoadedVoltagePower))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if let updated = d.updatedAt {
                    Text("Dashboard updated \(updated, style: .relative) ago")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }
                if settings.dryRun {
                    Label("Dry run: decisions are logged, nothing is written", systemImage: "eye")
                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                }
                if bike.demoBike {
                    Label("Demo bike: nothing here is real. Leave it from Settings.", systemImage: "theatermasks")
                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                }
                Text("Leave the app in the background; iOS does not relaunch a force-quit app for Bluetooth events.")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var lockTitle: String {
        switch bike.lockState {
        case .unlocked: "UNLOCKED"
        case .locked: "LOCKED"
        case .unknown: bike.connection == .connected ? "READING…" : "—"
        }
    }
}

struct Metric: View {
    let value: String?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Actions

struct ActionButtons: View {
    @ObservedObject var bike: BikeManager

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Unlock", icon: "lock.open.fill", color: Theme.unlocked) {
                bike.unlock(reason: "manual")
            }
            ActionButton(title: "Lock", icon: "lock.fill", color: Theme.locked) {
                bike.lock()
            }
            ActionButton(title: bike.dashboard.lights ? "Lights off" : "Lights on", icon: "headlight.high.beam", color: Theme.accent) {
                bike.setLights(on: !bike.dashboard.lights)
            }
        }
        .disabled(bike.connection != .connected)
        .opacity(bike.connection == .connected ? 1 : 0.4)
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(color)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Mode

struct ModeCard: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Auto unlock").font(.headline)
                Picker("Auto unlock", selection: $settings.modeRaw) {
                    ForEach(AutoUnlockMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.mode.explanation)
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - Trial

/// Opens the paywall from the home screen while the trial is not started,
/// running or over.
struct TrialBanner: View {
    let text: String
    let ended: Bool
    let action: () -> Void

    static func text(for access: Store.Access) -> String? {
        switch access {
        case .none: return "Try automatic re-unlock free for 7 days"
        case .expired: return "Trial ended, automatic unlock is off"
        case .trial(let endsAt):
            let days = max(1, Int((endsAt.timeIntervalSinceNow / 86400).rounded(.up)))
            return "Free trial: \(days) \(days == 1 ? "day" : "days") left"
        default: return nil
        }
    }

    var body: some View {
        Button(action: action) {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: ended ? "exclamationmark.triangle.fill" : "gift.fill")
                        .foregroundStyle(ended ? .yellow : Theme.accent)
                    Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

// MARK: - Pairing

/// Three steps shown before a bike is paired.
struct HowItWorksCard: View {
    private let steps = [
        "Pair your phone with the bike in the official Cowboy app once.",
        "Pick your bike below.",
        "Leave Lasso in the background; it re-unlocks the bike after a battery drop.",
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("How it works").font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                        Text(step).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }
}

struct PairingCard: View {
    @ObservedObject var bike: BikeManager

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair your bike").font(.headline)
                Text("Make sure the bike is awake and nearby. Your iPhone already knows the bike from the official app, so no code should be needed.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)

                if bike.connection == .scanning {
                    HStack { ProgressView(); Text("Looking for bikes…").font(.subheadline) }
                }
                ForEach(bike.discovered, id: \.identifier) { peripheral in
                    Button { bike.pair(peripheral) } label: {
                        HStack {
                            Image(systemName: "bicycle")
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? "Bike").font(.body.weight(.semibold))
                                    + Text(peripheral.state == .connected ? "  · linked" : "").font(.caption).foregroundColor(Theme.unlocked)
                                Text(peripheral.identifier.uuidString).font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .foregroundStyle(.white)
                }

                HStack {
                    Button(bike.connection == .scanning ? "Stop" : "Scan") {
                        bike.connection == .scanning ? bike.stopScan() : bike.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bike.connection == .bluetoothOff || bike.connection == .unauthorized)
                    Button("Try with a demo bike") { bike.enterDemo() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("demoBike")
                }

                if bike.connection == .bluetoothOff || bike.connection == .unauthorized {
                    Text(bike.connection.title).font(.footnote).foregroundStyle(Theme.locked)
                }
            }
        }
    }
}

// MARK: - Log

struct LogCard: View {
    @ObservedObject var log: EventLog
    @State private var showAll = false
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", connection = "Connection", lock = "Lock", problems = "Problems"
        var id: String { rawValue }

        func matches(_ kind: EventLog.Entry.Kind) -> Bool {
            switch self {
            case .all: true
            case .connection: kind == .connection
            case .lock: kind == .lock || kind == .unlock
            case .problems: kind == .warning || kind == .error
            }
        }
    }

    private var visible: [EventLog.Entry] {
        let filtered = log.entries.reversed().filter { filter.matches($0.kind) }
        return showAll ? Array(filtered) : Array(filtered.prefix(40))
    }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Log").font(.headline)
                    Spacer()
                    Text("\(log.entries.count)").font(.caption).foregroundStyle(Theme.secondaryText)
                    ShareLink(item: log.exportFile()) { Image(systemName: "square.and.arrow.up") }
                    Menu {
                        Button(showAll ? "Show recent" : "Show all") { showAll.toggle() }
                        Button("Clear log", role: .destructive) { log.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if log.entries.isEmpty {
                    Text("Nothing yet.").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(visible) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                        Text(entry.message)
                            .foregroundStyle(color(for: entry.kind))
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func color(for kind: EventLog.Entry.Kind) -> Color {
        switch kind {
        case .unlock: Theme.unlocked
        case .lock: Theme.accent
        case .warning: .yellow
        case .error: Theme.locked
        case .connection: .white
        case .info, .action: Theme.secondaryText
        }
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @ObservedObject var bike: BikeManager
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmForget = false
    @State private var showPaywall = false
    @State private var versionTaps = 0

    var body: some View {
        NavigationStack {
            Form {
                if store.isConfigured {
                    Section("Lasso") {
                        Button { showPaywall = true } label: {
                            LabeledContent("Purchase", value: purchaseStatus)
                        }
                        .foregroundStyle(.white)
                    }
                }

                Section {
                    Stepper(value: $settings.reconnectWindow, in: 30...900, step: 30) {
                        LabeledContent("Reconnect window", value: "\(Int(settings.reconnectWindow)) s")
                    }
                    Stepper(value: $settings.movingGrace, in: 5...120, step: 5) {
                        LabeledContent("Moving grace", value: "\(Int(settings.movingGrace)) s")
                    }
                } header: {
                    Text("During a ride")
                } footer: {
                    Text("A reconnect within the window counts as the same ride and gets re-unlocked. A lock within the grace period after the bike last moved is treated as a glitch.")
                }

                Section {
                    ForEach(MechanismPreset.all) { preset in
                        Button {
                            settings.apply(preset)
                            EventLog.shared.add(.info, "Preset \(preset.name) applied")
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name).foregroundStyle(.white)
                                    Text(preset.summary).font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if settings.currentPreset == preset {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("One tap sets all the mechanism values below. Try the next one if the bike does not come back unlocked.")
                }

                Section {
                    Toggle("Unlock write with response", isOn: $settings.unlockWithResponse)
                    Stepper(value: $settings.unlockDelay, in: 0...10, step: 0.5) {
                        LabeledContent("Delay after reconnect", value: String(format: "%.1f s", settings.unlockDelay))
                    }
                    Stepper(value: $settings.unlockRetries, in: 1...10) {
                        LabeledContent("Retries", value: "\(settings.unlockRetries)")
                    }
                    Stepper(value: $settings.unlockRetryInterval, in: 1...10, step: 1) {
                        LabeledContent("Retry interval", value: "\(Int(settings.unlockRetryInterval)) s")
                    }
                    Picker("Poll lock state during a ride", selection: $settings.lockPollInterval) {
                        Text("Off").tag(0.0)
                        Text("Every 5 s").tag(5.0)
                        Text("Every 15 s").tag(15.0)
                        Text("Every 30 s").tag(30.0)
                    }
                    Toggle("Undo any lock during a ride", isOn: $settings.undoAnyLockDuringRide)
                    Toggle("Live dashboard", isOn: Binding(
                        get: { settings.liveDashboard },
                        set: { bike.setLiveDashboard($0) }))
                } header: {
                    Text("Mechanism")
                } footer: {
                    Text("Alternatives to try if the default does not re-unlock. Write type: Bronco writes with response, the nRF key fob without. Polling catches a bike that never notifies its lock state. \"Undo any lock\" also reverts locks at standstill, so lock the bike from this app instead of the official one while it is on. The live dashboard is what detects movement; turning it off saves a few background wake-ups per second while riding.")
                }

                Section {
                    Toggle("When the bike is re-unlocked", isOn: $settings.notifyOnReunlock)
                    Toggle("Every lock and unlock", isOn: $settings.notifyOnLockChange)
                    Toggle("Live Activity during rides", isOn: Binding(
                        get: { settings.liveActivity },
                        set: { bike.setLiveActivity($0) }))
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("The Live Activity shows lock state, battery and the last event on the Lock Screen and in the Dynamic Island while a ride is active. It is updated on bike events only.")
                }

                if settings.developerMode {
                    Section {
                        Toggle("Dry run", isOn: $settings.dryRun)
                        Button("Simulate a battery drop (reboot bike PCB)") { bike.sendUART(ModbusCommand.resetPCB, label: "Reset PCB") }
                            .disabled(bike.connection != .connected)
                        Button("Read auto-lock setting") { bike.sendUART(ModbusCommand.readAutoLock, label: "Read auto-lock") }
                            .disabled(bike.connection != .connected)
                        Button("Read auto-unlock setting") { bike.sendUART(ModbusCommand.readAutoUnlock, label: "Read auto-unlock") }
                            .disabled(bike.connection != .connected)
                    } header: {
                        Text("Testing")
                    } footer: {
                        Text("Dry run logs what the app would do without writing the unlock. The PCB reboot restarts the bike's communication board, which drops the Bluetooth link the same way a battery blip does; settings are kept. Expect the LEDs on the top tube to run back and forth.")
                    }
                }

                Section("Bike") {
                    LabeledContent("Identifier", value: settings.bikePeripheralID.isEmpty ? "—" : settings.bikePeripheralID)
                        .font(.caption)
                    if bike.demoBike {
                        Button("Leave demo bike") { bike.leaveDemo(); dismiss() }
                    } else {
                        Button("Forget bike", role: .destructive) { confirmForget = true }
                            .disabled(!bike.hasBike)
                    }
                }

                Section {
                    LabeledContent("Version", value: AppInfo.version)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: versionTapped)
                    if !AppInfo.supportEmail.isEmpty, let url = supportURL {
                        Button("Contact support") { openURL(url) }
                    }
                    Link("Source code", destination: URL(string: "https://github.com/mcosti/lasso")!)
                } header: {
                    Text("About")
                } footer: {
                    Text(AppInfo.disclaimer)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Forget this bike?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { bike.forgetBike(); dismiss() }
            }
            .sheet(isPresented: $showPaywall) { PaywallView(store: store) }
        }
        .preferredColorScheme(.dark)
    }

    private var purchaseStatus: String {
        switch store.access {
        case .lifetime: "Lifetime"
        case .trial(let endsAt): "Trial until \(endsAt.formatted(date: .abbreviated, time: .omitted))"
        case .expired: "Trial ended"
        case .none: "Free trial"
        case .open, .unknown: "…"
        }
    }

    private var supportURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.supportEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: "\(AppInfo.name) \(AppInfo.version)"),
            URLQueryItem(name: "body", value: "Please attach the log from the Log card's share button."),
        ]
        return c.url
    }

    /// Seven taps on Version toggle developer mode (the Testing section).
    private func versionTapped() {
        guard !Demo.isActive else { return }
        versionTaps += 1
        guard versionTaps >= 7 else { return }
        versionTaps = 0
        settings.developerMode.toggle()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        EventLog.shared.add(.info, "Developer mode \(settings.developerMode ? "on" : "off")")
    }
}
