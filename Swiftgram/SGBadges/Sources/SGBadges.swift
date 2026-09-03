import Foundation
import SGAppGroupIdentifier
import SGLogging

// MARK: ViboGram - user badges (Tier 3)
//
// Two sources, merged:
//  - "ours": published by CI from the VIBOGRAM_BADGES_JSON repo secret onto a
//    dedicated GitHub release asset (not a plain committed file, so it isn't
//    part of the repo's visible git history/file tree) -- see
//    .github/workflows/publish-badges.yml.
//  - Margelet's own public badges.json, for interop (their fork reads ours
//    the same way, once they wire it up on their end).
//
// Same fetch-then-cache design as Margelet's own MargeletRemote.java: an
// async background fetch updates a local cache; until it succeeds at least
// once, the last successfully cached value is used, and before that, an
// empty list (no built-in fallback badges -- unlike Margelet, we don't ship
// with anyone hardcoded).

public struct SGBadge: Codable, Equatable {
    /// User: positive id. Channel/group: negative id (same convention as Margelet).
    public let peer: Int64
    public let title: String
    public let about: String?
    /// Hex color, with or without a leading '#', with or without alpha.
    public let color: String
    /// Optional: where the "open" button in the tap dialog goes. nil = no button.
    public let url: String?
    /// Optional: custom badge image URL. nil = plain colored rounded square.
    public let imgUrl: String?

    enum CodingKeys: String, CodingKey {
        case peer, title, about, color, url
        case imgUrl = "img_url"
    }
}

public enum SGBadges {
    private static let ourBadgesURL = URL(string: "https://github.com/vibeDN/ViboGram/releases/download/data/badges.json")!
    private static let margeletBadgesURL = URL(string: "https://raw.githubusercontent.com/narezany/margelet/main/badges.json")!
    // MARK: ViboGram - which of a peer's (possibly several) "ours" badges to
    // show as primary, when that's not simply "whichever is first in
    // badges.json" -- see build-system/badge_sync.py's own doc comment for
    // why this needs to be a real server-side, git-committed file rather
    // than a local per-device setting: a choice that only changes what one
    // device shows isn't actually "equipping" anything, since every other
    // viewer would still see the plain first-match default.
    private static let equipURL = URL(string: "https://raw.githubusercontent.com/vibeDN/ViboGram/main/data/badge_equip.json")!

    private static let ourCacheKey = "SGBadges.ours.cache"
    private static let margeletCacheKey = "SGBadges.margelet.cache"
    private static let equipCacheKey = "SGBadges.equip.cache"

    private static var userDefaults: UserDefaults {
        return UserDefaults(suiteName: sgAppGroupIdentifier()) ?? .standard
    }

    private static var ourBadges: [SGBadge] = load(cacheKey: ourCacheKey)
    private static var margeletBadges: [SGBadge] = load(cacheKey: margeletCacheKey)
    // MARK: ViboGram - peer id (as a String, matching badge_sync.py's JSON
    // object keys -- JSON object keys are always strings) -> equipped badge
    // title.
    private static var equippedTitleByPeer: [String: String] = loadEquipMap()

    private static func load(cacheKey: String) -> [SGBadge] {
        guard let data = userDefaults.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([SGBadge].self, from: data)) ?? []
    }

    private static func store(_ badges: [SGBadge], cacheKey: String) {
        guard let data = try? JSONEncoder().encode(badges) else { return }
        userDefaults.set(data, forKey: cacheKey)
    }

    private static func loadEquipMap() -> [String: String] {
        guard let data = userDefaults.data(forKey: equipCacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func storeEquipMap(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        userDefaults.set(data, forKey: equipCacheKey)
    }

    /// Re-fetches both badge sources (and the equip map) in the background.
    /// Call on app start; safe to call repeatedly (e.g. on foreground) since
    /// it's cheap and only updates the in-memory/cached lists on success.
    public static func refresh() {
        fetch(url: ourBadgesURL, cacheKey: ourCacheKey) { badges in
            ourBadges = badges
        }
        fetch(url: margeletBadgesURL, cacheKey: margeletCacheKey) { badges in
            margeletBadges = badges
        }
        fetchEquipMap()
    }

    private static func fetch(url: URL, cacheKey: String, onSuccess: @escaping ([SGBadge]) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let badges = try? JSONDecoder().decode([SGBadge].self, from: data) else {
                if let error = error {
                    SGLogger.shared.log("SGBadges", "Failed to fetch \(url): \(error)")
                }
                return
            }
            store(badges, cacheKey: cacheKey)
            DispatchQueue.main.async {
                onSuccess(badges)
            }
        }.resume()
    }

    private static func fetchEquipMap() {
        var request = URLRequest(url: equipURL)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                if let error = error {
                    SGLogger.shared.log("SGBadges", "Failed to fetch \(equipURL): \(error)")
                }
                return
            }
            storeEquipMap(map)
            DispatchQueue.main.async {
                equippedTitleByPeer = map
            }
        }.resume()
    }

    // MARK: ViboGram - `ourBadges`/`margeletBadges`/`equippedTitleByPeer` are
    // mutated only via `DispatchQueue.main.async` in `fetch`/`fetchEquipMap`
    // above; these accessors have no synchronization of their own, so they
    // must only be called from the main thread (true of the current call
    // sites, PeerInfoHeaderNode's UI code and the new Badges screen -- if a
    // future caller needs a background thread, this needs a real lock
    // first, not just a comment).
    /// The single badge to show next to a name: the peer's own equipped
    /// choice if one is on record and still actually exists among "ours"
    /// for that peer (a stale equip pointing at a badge that's since been
    /// removed from badges.json falls back rather than showing nothing),
    /// otherwise the first match in "ours", then Margelet's, matching each
    /// source's own priority-by-order convention.
    public static func primaryBadge(for peerId: Int64) -> SGBadge? {
        if let equippedTitle = equippedTitleByPeer[String(peerId)],
           let equipped = ourBadges.first(where: { $0.peer == peerId && $0.title == equippedTitle }) {
            return equipped
        }
        return ourBadges.first(where: { $0.peer == peerId }) ?? margeletBadges.first(where: { $0.peer == peerId })
    }

    /// Every badge for this peer, ours first, for a profile's full badge list.
    public static func allBadges(for peerId: Int64) -> [SGBadge] {
        return ourBadges.filter { $0.peer == peerId } + margeletBadges.filter { $0.peer == peerId }
    }

    /// Peer id for a channel/group/forum, matching the peer-key convention
    /// (channels/groups are stored as the negative of their numeric id).
    public static func chatPeer(chatId: Int64) -> Int64 {
        return -chatId
    }

    /// A pre-filled GitHub Issue URL that requests `badgeTitle` become
    /// `peerId`'s equipped (primary) badge, processed by
    /// .github/workflows/badge-sync.yml -> build-system/badge_sync.py. Same
    /// "the app only ever opens a pre-filled issue, never writes anything
    /// itself" shape as card_pull.vibo/phone_pull.vibo's official actions.
    public static func equipIssueURL(peerId: Int64, badgeTitle: String) -> URL? {
        var components = URLComponents(string: "https://github.com/vibeDN/ViboGram/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[badge-equip] \(peerId)"),
            URLQueryItem(name: "body", value: "title=\(badgeTitle)"),
            URLQueryItem(name: "labels", value: "badge-equip"),
        ]
        return components?.url
    }
}
