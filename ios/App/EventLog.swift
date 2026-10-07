import Foundation
import os

/// A persisted, timestamped log of everything the app saw and did, so a ride
/// where the bike rebooted can be reconstructed afterwards.
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()

    struct Entry: Identifiable, Codable {
        enum Kind: String, Codable {
            case info, connection, lock, unlock, action, warning, error
        }
        var id = UUID()
        let date: Date
        let kind: Kind
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private let limit = 3000
    private let logger = Logger(subsystem: "com.mcosti.lasso", category: "bike")
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }()
    private var saveScheduled = false
    private var persist = true

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ kind: Entry.Kind, _ message: String) {
        logger.log("\(kind.rawValue, privacy: .public): \(message, privacy: .public)")
        entries.append(Entry(date: Date(), kind: kind, message: message))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        scheduleSave()
    }

    /// Swaps the whole log, optionally without touching the file on disk
    /// (demo mode in the Simulator).
    func replaceAll(with newEntries: [Entry], persist: Bool) {
        self.persist = persist
        entries = newEntries
        if persist { scheduleSave() }
    }

    /// Drops the in-memory entries and reloads what is on disk (leaving demo).
    func reload() {
        persist = true
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    /// Coalesces bursts (dashboard packets arrive several times a second).
    private func scheduleSave() {
        guard persist, !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            saveScheduled = false
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var exportText: String {
        entries.map { "\(Self.iso.string(from: $0.date)) [\($0.kind.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }

    /// Writes the whole log as a .txt in the temporary directory for sharing.
    func exportFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-log.txt")
        try? exportText.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
