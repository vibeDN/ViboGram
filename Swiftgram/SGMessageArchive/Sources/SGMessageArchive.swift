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

    // MARK: ViboGram - bugfix: this file lives in the shared App Group
    // container, which the Notification Service Extension's own
    // `standaloneStateManager` also reads/writes from a *separate OS
    // process* (see AccountStateManagementUtils.swift's callers). The
    // previous load-mutate-save cycle was only serialized by this process's
    // own private DispatchQueue, which provides zero protection against a
    // second process doing the same read-modify-write concurrently -- two
    // processes could each load the same pre-update snapshot and each write
    // back their own version, silently dropping whichever entry lost the
    // race. NSFileCoordinator is the standard mechanism for exactly this
    // (coordinating access to a file shared between an app and its
    // extensions); the whole load-mutate-save cycle happens inside a single
    // coordinated accessor so no other coordinated reader/writer (in either
    // process) can interleave with it.
    private static func withCoordinatedReadWrite<T: Codable>(_ url: URL?, _ mutate: (inout [String: T]) -> Void) {
        guard let url else { return }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            var dict: [String: T] = loadDict(coordinatedURL)
            mutate(&dict)
            saveDict(dict, to: coordinatedURL)
        }
        if let coordinationError {
            SGLogger.shared.log("SGMessageArchive", "NSFileCoordinator write failed: \(coordinationError)")
        }
    }

    private static func withCoordinatedRead<T: Codable>(_ url: URL?) -> [String: T] {
        guard let url else { return [:] }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: [String: T] = [:]
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = loadDict(coordinatedURL)
        }
        if let coordinationError {
            SGLogger.shared.log("SGMessageArchive", "NSFileCoordinator read failed: \(coordinationError)")
        }
        return result
    }

    // MARK: - Deleted messages (anti-delete permanent local backup)

    // MARK: ViboGram - bugfix: this used to be `queue.async` (fire-and-forget).
    // The caller (AccountStateManagementUtils.swift) calls this BEFORE setting
    // the permanent `.SGAntiDeleted` local tag that gates all future archive
    // attempts for this message -- if the process was killed after the async
    // write was merely *queued* but before it actually executed, the tag
    // still ended up set (via the caller's own, separate Postbox transaction),
    // permanently preventing any retry, and the archive entry -- the entire
    // point of this feature -- was silently never written. Synchronous here
    // means the caller's existing call order (this, then set the tag) is
    // already correct -- no call-site changes needed, and JSON-encoding a
    // small dict is
    // cheap enough that blocking on it is a non-issue for an infrequent event
    // like a message deletion.
    public static func recordDeleted(peerId: Int64, messageId: Int32, namespace: Int32, authorId: Int64?, text: String, timestamp: Int32) {
        queue.sync {
            let entryKey = key(peerId: peerId, messageId: messageId, namespace: namespace)
            withCoordinatedReadWrite(deletedFileURL) { (dict: inout [String: SGArchivedMessage]) in
                // Permanent once archived -- never overwritten, regardless of
                // how many further delete attempts arrive for the same message.
                if dict[entryKey] != nil {
                    return
                }
                dict[entryKey] = SGArchivedMessage(peerId: peerId, messageId: messageId, namespace: namespace, authorId: authorId, text: text, timestamp: timestamp, archivedAt: Int32(Date().timeIntervalSince1970))
            }
        }
    }

    public static func isDeleted(peerId: Int64, messageId: Int32, namespace: Int32) -> Bool {
        let dict: [String: SGArchivedMessage] = withCoordinatedRead(deletedFileURL)
        return dict[key(peerId: peerId, messageId: messageId, namespace: namespace)] != nil
    }

    // MARK: - Edit history (previous versions of edited messages)

    // MARK: ViboGram - synchronous for the same reason as recordDeleted above
    // -- avoids a similar lost-write-on-process-death window, and consistent
    // with it rather than having one archive path be async and the other not.
    public static func recordEditVersion(peerId: Int64, messageId: Int32, namespace: Int32, previousText: String, editTimestamp: Int32) {
        queue.sync {
            let entryKey = key(peerId: peerId, messageId: messageId, namespace: namespace)
            withCoordinatedReadWrite(editHistoryFileURL) { (dict: inout [String: [SGMessageEditVersion]]) in
                var versions = dict[entryKey] ?? []
                versions.append(SGMessageEditVersion(text: previousText, editTimestamp: editTimestamp))
                dict[entryKey] = versions
            }
        }
    }

    public static func editHistory(peerId: Int64, messageId: Int32, namespace: Int32) -> [SGMessageEditVersion] {
        let dict: [String: [SGMessageEditVersion]] = withCoordinatedRead(editHistoryFileURL)
        return dict[key(peerId: peerId, messageId: messageId, namespace: namespace)] ?? []
    }
}
