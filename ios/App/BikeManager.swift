import ActivityKit
import CoreBluetooth
import Foundation
import UIKit
import UserNotifications

enum LockState: Equatable {
    case unknown, locked, unlocked

    init(_ data: Data?) {
        guard let byte = data?.first else { self = .unknown; return }
        self = byte == 1 ? .unlocked : .locked
    }
}

enum ConnectionState: Equatable {
    case bluetoothOff, unauthorized, noBike, scanning, waiting, connecting, connected

    var title: String {
        switch self {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .noBike: "No bike paired"
        case .scanning: "Looking for bikes…"
        case .waiting: "Waiting for the bike"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        }
    }
}

/// Last known dashboard values, merged from partial packets.
struct Dashboard {
    var tripId: Int32?
    var speed: Int32 = 0
    var power: Int32 = 0
    var battery: Int32?
    var batteryVoltage: Int32?
    var batteryTemp: Float?
    var distance: Int32 = 0
    var duration: Int32 = 0
    var activeDuration: Int32 = 0
    var movingDuration: Int32 = 0
    var assistance: Int32 = 0
    var pedalTorque: Int32 = 0
    var lights = false
    var unknown10: Int32 = 0
    var unknown12: Int32 = 0
    var unknown13: Int32 = 0
    var unknown14: Int32 = 0
    var updatedAt: Date?
    /// Lowest voltage seen while the motor was pushing (> 100 W) this ride,
    /// and the power at that moment: how much the battery sags under load.
    var minLoadedVoltage: Int32?
    var minLoadedVoltagePower: Int32 = 0

    var batteryTempCelsius: Double? { batteryTemp.map { Double($0) / 10 - 273.15 } }
}

/// Owns the Bluetooth connection to the bike and applies the auto-unlock policy.
///
/// Connection strategy: once the bike is known, `connect` is left pending
/// forever. iOS completes it whenever the bike is in range and advertising,
/// also in the background, and relaunches the app if it was evicted (state
/// restoration). Each time the link comes up, the lock state is read and the
/// policy in `AppSettings.mode` decides whether to send an unlock.
@MainActor
final class BikeManager: NSObject, ObservableObject {
    static let shared = BikeManager()

    @Published private(set) var connection: ConnectionState = .waiting
    @Published private(set) var lockState: LockState = .unknown
    @Published private(set) var dashboard = Dashboard()
    @Published private(set) var discovered: [CBPeripheral] = []
    @Published private(set) var connectedSince: Date?
    @Published private(set) var lastUnlockSentAt: Date?
    /// A fake bike is shown instead of Bluetooth (entered from the pairing screen).
    @Published private(set) var demoBike = false

    private var central: CBCentralManager!
    private var bike: CBPeripheral?
    private var lockCharacteristic: CBCharacteristic?
    private var dashboardCharacteristic: CBCharacteristic?
    private var uartRX: CBCharacteristic?
    private var pollTask: Task<Void, Never>?
    private var ready = false
    private var unlockAttempts = 0
    private var unlockRetryTask: Task<Void, Never>?

    private let settings = AppSettings.shared
    private let eventLog = EventLog.shared

    private var lastRSSI: Int?
    private var rssiTask: Task<Void, Never>?
    private var activity: Activity<RideActivityAttributes>?
    private var activityLastEvent = ""
    private var activityLastPush = Date.distantPast
    private var reunlocks = 0
    /// The "auto unlock skipped" warning was logged on this connection.
    private var gateWarned = false

    // MARK: - Live Activity

    private var activityState: RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            connected: bike?.state == .connected,
            locked: lockState != .unlocked,
            battery: dashboard.battery.map(Int.init),
            voltage: dashboard.batteryVoltage.map { Double($0) / 1000 },
            speed: Int(dashboard.speed),
            distance: Int(dashboard.distance),
            reunlocks: reunlocks,
            lastEvent: activityLastEvent,
            updatedAt: Date())
    }

    /// Starts the activity when a ride begins, ends it when the ride ends,
    /// and otherwise pushes the latest state. Dashboard-driven updates are
    /// throttled to one every 20 s; events go through immediately.
    private func syncActivity(event: String? = nil, force: Bool = false) {
        guard !Demo.isActive else { return }
        guard settings.liveActivity else { endActivity(); return }
        if let event { activityLastEvent = event }
        // Shown while the bike is connected or a ride is going on.
        if settings.rideActive || bike?.state == .connected {
            if activity == nil {
                // iOS only lets an app start a Live Activity from the
                // foreground, so this happens when the app is opened; it then
                // keeps updating from the background.
                guard ActivityAuthorizationInfo().areActivitiesEnabled,
                      UIApplication.shared.applicationState == .active else { return }
                do {
                    activity = try Activity.request(attributes: RideActivityAttributes(startedAt: Date()),
                                                    content: .init(state: activityState, staleDate: nil))
                    activityLastPush = Date()
                    log(.info, "Live Activity started")
                } catch {
                    log(.warning, "Live Activity failed: \(error.localizedDescription)")
                }
            } else if force || Date().timeIntervalSince(activityLastPush) > 20 {
                activityLastPush = Date()
                let state = activityState
                Task { await activity?.update(.init(state: state, staleDate: nil)) }
            }
        } else {
            endActivity()
        }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let state = activityState
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 300)) }
        log(.info, "Live Activity ended")
    }

    func setLiveActivity(_ on: Bool) {
        settings.liveActivity = on
        syncActivity(force: true)
    }

    /// The app came to the foreground: a chance to start the Live Activity.
    func appBecameActive() {
        syncActivity(force: true)
    }

    private func log(_ kind: EventLog.Entry.Kind, _ message: String) {
        eventLog.add(kind, message)
        switch kind {
        case .connection, .lock, .unlock, .error, .warning:
            // Short version for the Lock Screen: drop the context dump.
            let short = message.components(separatedBy: " lock=").first ?? message
            syncActivity(event: short, force: true)
        default:
            break
        }
    }

    /// Everything worth knowing when a connection event happens, in one line.
    private var context: String {
        var parts: [String] = []
        parts.append("lock=\(lockState)")
        if let b = dashboard.battery { parts.append("batt=\(b)%") }
        if let mv = dashboard.batteryVoltage { parts.append(String(format: "%.2fV", Double(mv) / 1000)) }
        if let t = dashboard.batteryTempCelsius { parts.append(String(format: "%.0f°C", t)) }
        if let updated = dashboard.updatedAt {
            parts.append(String(format: "dash %.0fs ago", Date().timeIntervalSince(updated)))
        }
        parts.append("speed=\(dashboard.speed)")
        if let trip = dashboard.tripId { parts.append("trip=\(trip)") }
        if let rssi = lastRSSI { parts.append("rssi=\(rssi)") }
        parts.append("ride=\(settings.rideActive ? "on" : "off")")
        parts.append("app=\(appState)")
        if ProcessInfo.processInfo.isLowPowerModeEnabled { parts.append("lowpower") }
        return parts.joined(separator: " ")
    }

    private var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "fg"
        case .inactive: "inactive"
        case .background: "bg"
        @unknown default: "?"
        }
    }

    /// Reads the signal strength every minute while connected, so the log can
    /// show whether a drop was preceded by a weak link. One tiny request per
    /// minute, negligible for the phone's battery.
    private func startRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let bike = self.bike, bike.state == .connected else { return }
                bike.readRSSI()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    var hasBike: Bool { settings.bikeID != nil }
    var rideActive: Bool { settings.rideActive }

    private override init() {
        super.init()
        guard !Demo.isActive else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.mcosti.lasso.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    func start() {
        if Demo.isActive { applyDemoState(); return }
        activity = Activity<RideActivityAttributes>.activities.first
        if !settings.rideActive { endActivity() }
        log(.info, "App started")
    }

    /// Simulator only: a connected, unlocked bike mid-ride with a log that
    /// shows a real battery drop being fixed. See `Demo`.
    private struct SavedSettings {
        let bikeID: String, dryRun: Bool, developerMode: Bool, rideActive: Bool
    }
    private var beforeDemo: SavedSettings?

    /// Shows the fake bike without Bluetooth. App Review has no Cowboy to test
    /// with, and a visible demo is required (hidden features are not allowed).
    func enterDemo() {
        guard !Demo.isActive else { return }
        beforeDemo = SavedSettings(bikeID: settings.bikePeripheralID, dryRun: settings.dryRun,
                                   developerMode: settings.developerMode, rideActive: settings.rideActive)
        Demo.runtime = true
        demoBike = true
        central.delegate = nil
        if let bike { central.cancelPeripheralConnection(bike) }
        bike = nil
        unlockRetryTask?.cancel()
        pollTask?.cancel()
        rssiTask?.cancel()
        eventLog.add(.info, "Demo bike on")
        applyDemoState()
    }

    /// Back to the real world: previous settings and log, reconnect if a bike is known.
    func leaveDemo() {
        guard Demo.runtime else { return }
        Demo.runtime = false
        demoBike = false
        if let s = beforeDemo {
            settings.bikePeripheralID = s.bikeID
            settings.dryRun = s.dryRun
            settings.developerMode = s.developerMode
            settings.rideActive = s.rideActive
        }
        beforeDemo = nil
        lockState = .unknown
        dashboard = Dashboard()
        connectedSince = nil
        lastRSSI = nil
        reunlocks = 0
        eventLog.reload()
        central.delegate = self
        connection = central.state == .poweredOn ? (hasBike ? .waiting : .noBike) : .bluetoothOff
        log(.info, "Demo bike off")
        if hasBike { connectToKnownBike() }
    }

    private func applyDemoState() {
        settings.bikePeripheralID = "0C0B0A00-18EB-499D-B266-2F2910744274"
        settings.mode = .ride
        settings.dryRun = false
        settings.developerMode = false
        settings.rideActive = true
        settings.apply(MechanismPreset.all[0])
        connection = .connected
        lockState = .unlocked
        dashboard = Demo.dashboard
        connectedSince = Demo.connectedSince
        lastRSSI = -87
        reunlocks = Demo.reunlocks
        eventLog.replaceAll(with: Demo.logEntries(), persist: false)
    }

    // MARK: - Pairing

    private var seenDuringScan: [String: Int] = [:]
    private var scanSummaryTask: Task<Void, Never>?

    func startScan() {
        guard let central, central.state == .poweredOn else { return }
        discovered = []
        seenDuringScan = [:]
        connection = .scanning
        // A bike that the Cowboy app already has linked does not advertise,
        // so a scan never sees it. iOS can hand over peripherals that are
        // connected to the system by any app and expose the bike's services.
        let linked = central.retrieveConnectedPeripherals(withServices: [CowboyBLE.cowboyService, CowboyBLE.uartService])
        for p in linked {
            discovered.append(p)
            log(.info, "Already linked by another app: \(p.name ?? "unnamed") \(p.identifier.uuidString)")
        }
        // Otherwise scan for everything and match on name or service UUID.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log(.info, "Scanning for bikes (\(linked.count) already linked)")
        scanSummaryTask?.cancel()
        scanSummaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.central.isScanning else { return }
            let names = self.seenDuringScan.sorted { $0.value > $1.value }.prefix(15)
                .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            self.log(.info, "Scan after 10 s: \(self.seenDuringScan.values.reduce(0, +)) advertisements from \(self.seenDuringScan.count) devices: \(names)")
        }
    }

    func stopScan() {
        scanSummaryTask?.cancel()
        guard central.isScanning else { return }
        central.stopScan()
        if connection == .scanning { connection = hasBike ? .waiting : .noBike }
    }

    func pair(_ peripheral: CBPeripheral) {
        stopScan()
        settings.bikeID = peripheral.identifier
        log(.info, "Paired with \(peripheral.name ?? "bike") \(peripheral.identifier.uuidString)")
        connect(to: peripheral)
    }

    func forgetBike() {
        if let bike { central.cancelPeripheralConnection(bike) }
        bike = nil
        settings.bikeID = nil
        settings.rideActive = false
        connection = .noBike
        lockState = .unknown
        dashboard = Dashboard()
        log(.info, "Forgot bike")
    }

    // MARK: - Connection

    private func connectToKnownBike() {
        guard let id = settings.bikeID else { connection = .noBike; return }
        if let bike, bike.identifier == id {
            connect(to: bike)
            return
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(to: peripheral)
        } else {
            log(.warning, "iOS no longer knows peripheral \(id.uuidString); pair again")
            settings.bikeID = nil
            connection = .noBike
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        bike = peripheral
        peripheral.delegate = self
        ready = false
        lockCharacteristic = nil
        dashboardCharacteristic = nil
        uartRX = nil
        switch peripheral.state {
        case .connected:
            connection = .connected
            peripheral.discoverServices([CowboyBLE.cowboyService, CowboyBLE.uartService])
        case .connecting:
            connection = .connecting
        default:
            connection = .waiting
            // No timeout: iOS keeps this pending until the bike shows up.
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        }
    }

    // MARK: - Commands

    func unlock(reason: String) {
        guard let bike, let lockCharacteristic, bike.state == .connected else {
            log(.warning, "Cannot unlock: not connected")
            return
        }
        if settings.dryRun {
            log(.unlock, "DRY RUN, would unlock now: \(reason)")
            return
        }
        unlockAttempts += 1
        lastUnlockSentAt = Date()
        log(.unlock, "Sending unlock (attempt \(unlockAttempts)): \(reason)")
        write(CowboyBLE.unlock, to: lockCharacteristic, on: bike)

        // The bike confirms via a notification on the lock characteristic.
        // If that does not come, read back and try again a couple of times.
        unlockRetryTask?.cancel()
        unlockRetryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(1, self.settings.unlockRetryInterval)))
            guard !Task.isCancelled else { return }
            if self.lockState != .unlocked, let bike = self.bike, bike.state == .connected {
                bike.readValue(for: lockCharacteristic)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.lockState != .unlocked else { return }
                if self.unlockAttempts < self.settings.unlockRetries {
                    self.unlock(reason: "retry, still \(self.lockState)")
                } else {
                    self.log(.error, "Bike still locked after \(self.unlockAttempts) attempts")
                    self.unlockAttempts = 0
                }
            }
        }
    }

    /// Policy unlocks go through here; the manual button calls `unlock`
    /// directly and is never gated. Logs once per connection when skipped.
    private func autoUnlockAllowed() -> Bool {
        let store = Store.shared
        guard !store.canAutoUnlock else { return true }
        if !gateWarned {
            gateWarned = true
            log(.warning, store.access == .none
                ? "Auto unlock skipped: start the free trial in Settings"
                : "Auto unlock skipped: trial ended, buy Lifetime in Settings")
        }
        return false
    }

    /// Unlock after the configured settle time, unless the bike unlocked or
    /// dropped meanwhile.
    private func unlockAfterDelay(reason: String) {
        guard autoUnlockAllowed() else { return }
        let delay = settings.unlockDelay
        guard delay > 0 else { unlock(reason: reason); return }
        log(.info, String(format: "Unlocking in %.1f s", delay))
        unlockRetryTask?.cancel()
        unlockRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.lockState == .locked else { return }
            self.unlock(reason: reason)
        }
    }

    func lock() {
        guard let bike, let lockCharacteristic, bike.state == .connected else { return }
        unlockRetryTask?.cancel()
        settings.rideActive = false
        log(.action, "Sending lock (manual)")
        write(CowboyBLE.lock, to: lockCharacteristic, on: bike)
    }

    func setLiveDashboard(_ on: Bool) {
        settings.liveDashboard = on
        if let bike, let dashboardCharacteristic, bike.state == .connected {
            bike.setNotifyValue(on, for: dashboardCharacteristic)
            log(.info, "Dashboard updates \(on ? "on" : "off")")
        }
    }

    /// Optional safety net: read the lock state every N seconds during a ride.
    private func startLockPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let bike = self.bike, bike.state == .connected else { return }
                let interval = self.settings.lockPollInterval
                try? await Task.sleep(for: .seconds(max(interval, 5)))
                guard !Task.isCancelled, interval > 0, self.settings.rideActive,
                      let c = self.lockCharacteristic, bike.state == .connected else { continue }
                bike.readValue(for: c)
            }
        }
    }

    func setLights(on: Bool) {
        guard let bike, let uartRX, bike.state == .connected else { return }
        log(.action, "Lights \(on ? "on" : "off")")
        write(ModbusCommand.lights(on: on), to: uartRX, on: bike)
    }

    func sendUART(_ frame: Data, label: String) {
        guard let bike, let uartRX, bike.state == .connected else { return }
        log(.action, "\(label): \(frame.hex)")
        write(frame, to: uartRX, on: bike)
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        // The UART RX characteristic wants write-without-response ("command"
        // in nRF Connect); the lock characteristic accepts either, and a
        // response gives us an error if the bond is missing.
        let type: CBCharacteristicWriteType
        if characteristic.uuid == CowboyBLE.uartRX, characteristic.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else if characteristic.properties.contains(.write),
                  settings.unlockWithResponse || !characteristic.properties.contains(.writeWithoutResponse) {
            type = .withResponse
        } else {
            type = .withoutResponse
        }
        if characteristic.uuid == CowboyBLE.lockCharacteristic {
            log(.info, "Write \(data.hex) \(type == .withResponse ? "with" : "without") response")
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    // MARK: - Policy

    /// Called with the first lock state after every (re)connect.
    private func handleInitialLockState(_ state: LockState) {
        let sinceDisconnect = Date().timeIntervalSince1970 - settings.lastDisconnectAt
        let gapText = settings.lastDisconnectAt > 0 ? String(format: "%.0f s after disconnect", sinceDisconnect) : "first connection"
        log(.lock, "Bike is \(state == .locked ? "locked" : "unlocked") on connect (\(gapText)) \(context)")

        switch state {
        case .unlocked:
            settings.rideActive = true
        case .locked:
            switch settings.mode {
            case .always:
                unlockAfterDelay(reason: "connected, mode Always")
            case .ride:
                if settings.rideActive, sinceDisconnect <= settings.reconnectWindow {
                    unlockAfterDelay(reason: String(format: "reconnected %.0f s after an unexpected disconnect mid-ride", sinceDisconnect))
                } else {
                    if settings.rideActive {
                        log(.info, String(format: "Ride ended: away for %.0f s (window %.0f s)", sinceDisconnect, settings.reconnectWindow))
                    }
                    settings.rideActive = false
                }
            case .off:
                settings.rideActive = false
            }
        case .unknown:
            break
        }
        syncActivity(force: true)
    }

    /// Called when the lock characteristic notifies a change while connected.
    private func handleLockChange(from old: LockState, to new: LockState) {
        guard old != new else { return }
        log(.lock, "Bike \(new == .locked ? "locked" : "unlocked") \(context)")
        switch new {
        case .unlocked:
            unlockAttempts = 0
            unlockRetryTask?.cancel()
            settings.rideActive = true
            if lastUnlockSentAt.map({ Date().timeIntervalSince($0) < 10 }) == true {
                reunlocks += 1
                notify(title: "Bike unlocked again", body: "\(AppInfo.name) re-unlocked your bike.", onlyIf: settings.notifyOnReunlock)
            } else {
                notify(title: "Bike unlocked", body: "", onlyIf: settings.notifyOnLockChange)
            }
        case .locked:
            let sinceMoving = Date().timeIntervalSince1970 - settings.lastMovingAt
            if settings.mode != .off, settings.rideActive, sinceMoving <= settings.movingGrace {
                // Locked while riding: nobody does that on purpose.
                guard autoUnlockAllowed() else { break }
                unlock(reason: String(format: "locked %.0f s after last movement", sinceMoving))
            } else if settings.mode != .off, settings.rideActive, settings.undoAnyLockDuringRide {
                guard autoUnlockAllowed() else { break }
                unlock(reason: "locked during a ride (undo-any-lock is on)")
            } else {
                settings.rideActive = false
                log(.info, "Treating this as an intentional lock, ride ended")
                notify(title: "Bike locked", body: "", onlyIf: settings.notifyOnLockChange)
            }
        case .unknown:
            break
        }
        syncActivity(force: true)
    }

    private func handleDashboard(_ packet: DashboardPacket) {
        var d = dashboard
        if let v = packet.tripId, v != d.tripId {
            if d.tripId != nil { log(.info, "New trip id \(v)") }
            d.tripId = v
            d.minLoadedVoltage = nil
            d.minLoadedVoltagePower = 0
        }
        if let v = packet.speed { d.speed = v }
        if let v = packet.power { d.power = v }
        if let v = packet.battery, v > 0 { d.battery = v }
        if let v = packet.batteryVoltage, v > 0 {
            d.batteryVoltage = v
            if d.power > 100, v < (d.minLoadedVoltage ?? .max) {
                d.minLoadedVoltage = v
                d.minLoadedVoltagePower = d.power
            }
        }
        if let v = packet.batteryTemp, v > 0 { d.batteryTemp = v }
        if let v = packet.distance { d.distance = v }
        if let v = packet.duration { d.duration = v }
        if let v = packet.lights { d.lights = v == 1 }
        if let v = packet.activeDuration { d.activeDuration = v }
        if let v = packet.movingDuration { d.movingDuration = v }
        if let v = packet.assistance { d.assistance = v }
        if let v = packet.pedalTorque { d.pedalTorque = v }
        if let v = packet.unknown10 { d.unknown10 = v }
        if let v = packet.unknown12 { d.unknown12 = v }
        if let v = packet.unknown13 { d.unknown13 = v }
        if let v = packet.unknown14 { d.unknown14 = v }
        d.updatedAt = Date()
        if d.speed > 0 || d.power > 0 { settings.lastMovingAt = Date().timeIntervalSince1970 }
        dashboard = d
        syncActivity()
        // A dashboard packet means the bike is running, whatever the lock
        // characteristic said; keep the ride alive.
        if lockState == .unlocked { settings.rideActive = true }
    }

    private func notify(title: String, body: String, onlyIf enabled: Bool) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Delegate plumbing (CoreBluetooth calls back on the main queue)

    fileprivate func didUpdateState() {
        switch central.state {
        case .poweredOn:
            log(.info, "Bluetooth on")
            connectToKnownBike()
            if !hasBike, UIApplication.shared.applicationState == .active { startScan() }
        case .poweredOff:
            connection = .bluetoothOff
            log(.warning, "Bluetooth off")
        case .unauthorized:
            connection = .unauthorized
            log(.error, "Bluetooth unauthorized")
        default:
            break
        }
    }

    fileprivate func willRestore(_ peripherals: [CBPeripheral]) {
        let states = peripherals.map { "\($0.identifier.uuidString.prefix(8)) state=\($0.state.rawValue)" }.joined(separator: ", ")
        log(.info, "Relaunched by iOS in the background for a Bluetooth event: \(states)")
        if let p = peripherals.first(where: { $0.identifier == settings.bikeID }) {
            bike = p
            p.delegate = self
        }
    }

    fileprivate func didDiscover(_ peripheral: CBPeripheral, name: String?, services: [CBUUID], rssi: NSNumber) {
        let advertisedName = name ?? peripheral.name ?? ""
        seenDuringScan[advertisedName.isEmpty ? "(no name)" : advertisedName, default: 0] += 1
        let byName = advertisedName.uppercased().contains(CowboyBLE.deviceName)
        let byService = services.contains(CowboyBLE.cowboyService) || services.contains(CowboyBLE.uartService)
        guard byName || byService else { return }
        if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
            discovered.append(peripheral)
            log(.info, "Found \(advertisedName.isEmpty ? "unnamed bike" : advertisedName) \(peripheral.identifier.uuidString) RSSI \(rssi) services \(services.map(\.uuidString))")
        }
    }

    fileprivate func didConnect(_ peripheral: CBPeripheral) {
        connection = .connected
        connectedSince = Date()
        unlockAttempts = 0
        gateWarned = false
        lockState = .unknown
        lastRSSI = nil
        let gap = settings.lastDisconnectAt > 0
            ? String(format: "%.1f s after last disconnect", Date().timeIntervalSince1970 - settings.lastDisconnectAt)
            : "first connection since launch"
        log(.connection, "Connected (\(gap)) \(context)")
        peripheral.delegate = self
        peripheral.discoverServices([CowboyBLE.cowboyService, CowboyBLE.uartService])
        startRSSIPolling()
        startLockPolling()
    }

    fileprivate func didFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        log(.error, "Connect failed: \(describe(error)) \(context)")
        connect(to: peripheral)
    }

    fileprivate func didDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        rssiTask?.cancel()
        pollTask?.cancel()
        unlockRetryTask?.cancel()
        let uptime = connectedSince.map { String(format: "after %.1f s", Date().timeIntervalSince($0)) } ?? "while connecting"
        let before = context
        connectedSince = nil
        lockState = .unknown
        dashboard.speed = 0
        dashboard.power = 0
        settings.lastDisconnectAt = Date().timeIntervalSince1970
        log(.connection, "Disconnected \(uptime): \(describe(error)) | \(before)")
        if settings.rideActive {
            log(.info, "Drop mid-ride; will re-unlock if the bike is back within \(Int(settings.reconnectWindow)) s")
        }
        connect(to: peripheral)
        syncActivity(force: true)
    }

    fileprivate func didReadRSSI(_ rssi: NSNumber, error: Error?) {
        guard error == nil else { return }
        let value = rssi.intValue
        if let last = lastRSSI, abs(last - value) >= 10 {
            log(.info, "Signal changed \(last) → \(value) dBm")
        }
        lastRSSI = value
    }

    private func describe(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("R") }
        if p.contains(.write) { out.append("W") }
        if p.contains(.writeWithoutResponse) { out.append("w") }
        if p.contains(.notify) { out.append("N") }
        if p.contains(.indicate) { out.append("I") }
        if p.contains(.notifyEncryptionRequired) || p.contains(.indicateEncryptionRequired) { out.append("enc") }
        return out.joined()
    }

    /// Decodes the common Modbus reply shapes; mostly the Cowboy app's own
    /// traffic, which we overhear because iOS shares the link.
    private func describeModbus(_ d: Data) -> String {
        let b = [UInt8](d)
        guard b.count >= 4 else { return d.hex }
        let slave: String
        switch b[0] {
        case 0x01: slave = "motor"
        case 0x04: slave = "battery"
        case 0x0A: slave = "pcb"
        default: slave = String(format: "slave %02x", b[0])
        }
        if b[1] == 0x03, b.count >= 5 + Int(b[2]) {
            let value = Int(b[3]) << 8 | Int(b[4])
            return "\(d.hex) (\(slave) read → \(value))"
        }
        if b[1] == 0x10, b.count >= 6 {
            let reg = Int(b[2]) << 8 | Int(b[3])
            return "\(d.hex) (\(slave) write ack reg \(reg))"
        }
        return d.hex
    }

    /// "no error" or "CBErrorDomain 7: The specified device has disconnected from us."
    private func describe(_ error: Error?) -> String {
        guard let error else { return "no error reported (clean disconnect)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    fileprivate func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error { log(.error, "Service discovery failed: \(error.localizedDescription)"); return }
        let names = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
        log(.info, "Services: \(names)")
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case CowboyBLE.cowboyService:
                peripheral.discoverCharacteristics([CowboyBLE.lockCharacteristic, CowboyBLE.dashboardCharacteristic], for: service)
            case CowboyBLE.uartService:
                peripheral.discoverCharacteristics([CowboyBLE.uartRX, CowboyBLE.uartTX], for: service)
            default:
                break
            }
        }
        if peripheral.services?.isEmpty ?? true {
            log(.error, "Bike exposes no known services")
        }
    }

    fileprivate func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error { log(.error, "Characteristic discovery failed: \(error.localizedDescription)"); return }
        let dump = (service.characteristics ?? []).map { "\($0.uuid.uuidString.prefix(8)) [\(describe($0.properties))]" }
            .joined(separator: ", ")
        log(.info, "Service \(service.uuid.uuidString.prefix(8)): \(dump)")
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case CowboyBLE.lockCharacteristic:
                lockCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                // Triggers the pairing prompt if the phone is not bonded yet.
                peripheral.readValue(for: c)
            case CowboyBLE.dashboardCharacteristic:
                dashboardCharacteristic = c
                peripheral.setNotifyValue(settings.liveDashboard, for: c)
            case CowboyBLE.uartRX:
                uartRX = c
            case CowboyBLE.uartTX:
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    fileprivate func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log(.error, "Read \(characteristic.uuid) failed: \(error.localizedDescription)")
            if (error as NSError).domain == CBATTErrorDomain {
                log(.warning, "The bike refused: the phone is probably not bonded. Open the official Cowboy app once, or accept the pairing prompt.")
            }
            return
        }
        switch characteristic.uuid {
        case CowboyBLE.lockCharacteristic:
            let new = LockState(characteristic.value)
            let old = lockState
            lockState = new
            if !ready {
                ready = true
                handleInitialLockState(new)
            } else {
                handleLockChange(from: old, to: new)
            }
        case CowboyBLE.dashboardCharacteristic:
            if let value = characteristic.value, let packet = DashboardPacket(value) {
                handleDashboard(packet)
            }
        case CowboyBLE.uartTX:
            log(.info, "UART reply \(describeModbus(characteristic.value ?? Data()))")
        default:
            break
        }
    }

    fileprivate func didWrite(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log(.error, "Write to \(characteristic.uuid) failed: \(error.localizedDescription)")
        } else if characteristic.uuid == CowboyBLE.lockCharacteristic {
            log(.info, "Bike acknowledged lock write")
        }
    }

    fileprivate func didUpdateNotificationState(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log(.error, "Notify \(characteristic.uuid) failed: \(error.localizedDescription)")
        }
    }
}

// CoreBluetooth is created with queue: nil, so every callback already runs on
// the main thread; `assumeIsolated` keeps event order intact (a Task hop could
// reorder a lock notification and a disconnect).
extension BikeManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { didUpdateState() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated { willRestore(peripherals) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        MainActor.assumeIsolated { didDiscover(peripheral, name: name, services: services, rssi: RSSI) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { didFailToConnect(peripheral, error: error) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { didDisconnect(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { didDiscoverServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { didUpdateValue(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { didWrite(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { didUpdateNotificationState(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated { didReadRSSI(RSSI, error: error) }
    }
}
