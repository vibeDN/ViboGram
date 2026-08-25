import Foundation
import SGAppGroupIdentifier
import SGLogging

// MARK: ViboGram - local message archive (Tier 3). Backs both anti-delete
// (permanent local copy of a message the other side deleted) and edit
// history (previous text of an edited message), stored as plain JSON in the
// shared App Group container -- deliberately NOT relying on Postbox alone,
// so this data survives independently of Postbox's own database/cache
// lifecycle. Two separate files in the same folder, per the design: deleted
// messages never expire/get overwritten once archived; edit history appends
// a new version every time a message is edited.
public struct SGArchivedMessage: Codable {
    public let peerId: Int64
    public let messageId: Int32
    public let namespace: Int32
    public let authorId: Int64?
    public let text: String
    public let timestamp: Int32
    public let archivedAt: Int32

    public init(peerId: Int64, messageId: Int32, namespace: Int32, authorId: Int64?, text: String, timestamp: Int32, archivedAt: Int32) {
        self.peerId = peerId
        self.messageId = messageId
        self.namespace = namespace
        self.authorId = authorId
        self.text = text
        self.timestamp = timestamp
        self.archivedAt = archivedAt
    }
}

public struct SGMessageEditVersion: Codable {
    public let text: String
    public let editTimestamp: Int32

    public init(text: String, editTimestamp: Int32) {
        self.text = text
        self.editTimestamp = editTimestamp
    }
}

public enum SGMessageArchive {
    private static let queue = DispatchQueue(label: "org.vibogram.SGMessageArchive", qos: .utility)

    private static var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sgAppGroupIdentifier())?.appendingPathComponent("SGMessageArchive", isDirectory: true)
    }

    private static func ensureDirectory() -> URL? {
        guard let url = containerURL else {
            return nil
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var deletedFileURL: URL? {
        return ensureDirectory()?.appendingPathComponent("deleted.json")
    }

    private static var editHistoryFileURL: URL? {
        return ensureDirectory()?.appendingPathComponent("edit_history.json")
    }

    private static func key(peerId: Int64, messageId: Int32, namespace: Int32) -> String {
        return "\(peerId)_\(namespace)_\(messageId)"
    }

    private static func loadDict<T: Codable>(_ url: URL?) -> [String: T] {
        guard let url, let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: T].self, from: data)) ?? [:]
    }

    private static func saveDict<T: Codable>(_ dict: [String: T], to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(dict) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Deleted messages (anti-delete permanent local backup)

    public static func recordDeleted(peerId: Int64, messageId: Int32, namespace: Int32, authorId: Int64?, text: String, timestamp: Int32) {
        queue.async {
            var dict: [String: SGArchivedMessage] = loadDict(deletedFileURL)
            let entryKey = key(peerId: peerId, messageId: messageId, namespace: namespace)
            // Permanent once archived -- never overwritten, regardless of how
            // many further delete attempts arrive for the same message.
            if dict[entryKey] != nil {
                return
            }
            dict[entryKey] = SGArchivedMessage(peerId: peerId, messageId: messageId, namespace: namespace, authorId: authorId, text: text, timestamp: timestamp, archivedAt: Int32(Date().timeIntervalSince1970))
            saveDict(dict, to: deletedFileURL)
        }
    }

    public static func isDeleted(peerId: Int64, messageId: Int32, namespace: Int32) -> Bool {
        let dict: [String: SGArchivedMessage] = loadDict(deletedFileURL)
        return dict[key(peerId: peerId, messageId: messageId, namespace: namespace)] != nil
    }

    // MARK: - Edit history (previous versions of edited messages)

    public static func recordEditVersion(peerId: Int64, messageId: Int32, namespace: Int32, previousText: String, editTimestamp: Int32) {
        queue.async {
            var dict: [String: [SGMessageEditVersion]] = loadDict(editHistoryFileURL)
            let entryKey = key(peerId: peerId, messageId: messageId, namespace: namespace)
            var versions = dict[entryKey] ?? []
            versions.append(SGMessageEditVersion(text: previousText, editTimestamp: editTimestamp))
            dict[entryKey] = versions
            saveDict(dict, to: editHistoryFileURL)
        }
    }

    public static func editHistory(peerId: Int64, messageId: Int32, namespace: Int32) -> [SGMessageEditVersion] {
        let dict: [String: [SGMessageEditVersion]] = loadDict(editHistoryFileURL)
        return dict[key(peerId: peerId, messageId: messageId, namespace: namespace)] ?? []
    }
}
