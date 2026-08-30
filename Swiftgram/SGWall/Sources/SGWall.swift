import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGCommunityGroup

// MARK: ViboGram - profile wall (other people write about someone; the
// subject can't remove it), ported from Margelet's MargeletGroup.java
// (`tagWall`/`tagged`/`hideTags`/`onlyWall`, see FEATURES.md #44). Same
// shared group as SGBanner/SGGradient, by the same arrangement with
// Margelet's author.
//
// Data layer only, and more so than banner/gradient: this is
// necessarily-explicitly-decided territory (see the project's own README --
// people can write about you here and you cannot take it down, which is a
// deliberate design choice, not a limitation to fix), and even setting that
// aside, a wall is a live, multi-author, potentially-long message feed, not
// a single get/set/clear value -- actually presenting it (a dedicated
// screen, tap-through from a tagged message in the group itself, composer
// integration so writing "to" someone's wall auto-tags what's sent) is a
// real UI surface of its own, not attempted here.
//
// NOT ported: MargeletGroup.tagged()'s link-blocking check
// (`MargeletLinks.firstBad`) that refuses to post text containing certain
// links. Whatever "write to this wall" UI eventually gets built should
// decide its own anti-abuse policy for that surface rather than inheriting
// Margelet's unexamined -- this module only does the tagging/finding/
// display-stripping mechanics, not moderation policy.
public enum SGWall {
    // MARK: ViboGram - bugfix, caught by independent review: the Java
    // original disambiguates by the SIGN of the numeric id (negative =
    // group/channel, per the Bot API's own `-100...` convention), but in
    // THIS codebase `PeerId.id._internalGetInt64Value()` is the raw MTProto
    // id, which is non-negative for every peer type here -- the type is
    // carried entirely in the separate `namespace` field. Branching on sign
    // was dead code (always true) and, worse, meant a CloudUser and a
    // CloudGroup/CloudChannel that happen to share the same raw numeric id
    // (a real possibility -- these are independent server-side id spaces)
    // would silently collide on one wall. Keying the tag off the actual
    // namespace fixes this for real instead of by coincidence.
    private static func namespaceLetter(_ namespace: PeerId.Namespace) -> String {
        switch namespace {
        case Namespaces.Peer.CloudUser:
            return "u"
        case Namespaces.Peer.CloudGroup:
            return "g"
        case Namespaces.Peer.CloudChannel:
            return "c"
        case Namespaces.Peer.SecretChat:
            return "s"
        default:
            // Anything else this project doesn't expect as a wall subject --
            // still produces a valid, distinct tag rather than guessing wrong.
            // `.rawValue` is fileprivate to Postbox's own Peer.swift, so this
            // uses the public `description` instead, sanitized down to just
            // digits/letters (hashtags can't contain arbitrary punctuation).
            let sanitized = namespace.description.filter { $0.isLetter || $0.isNumber }
            return "n\(sanitized)_"
        }
    }

    /// The tag a given peer's wall entries carry, disambiguated by
    /// namespace (see the bugfix note above) rather than by sign.
    public static func tag(for peerId: PeerId) -> String {
        let raw = peerId.id._internalGetInt64Value()
        return "#margy_wall_\(namespaceLetter(peerId.namespace))\(raw)"
    }

    // MARK: ViboGram - bugfix, caught by independent review: unlike
    // SGBanner.find (re-checks for an actual photo) and SGGradient.find
    // (re-checks the text actually parses as a color pair), this used to
    // trust the server-side text search verbatim. That's a real gap on two
    // fronts: (1) if Telegram's search is ever prefix/substring-based rather
    // than exact-token, a search for "#margy_wall_u12" could also surface
    // "#margy_wall_u123"'s messages; (2) even if search is exact, `post()`
    // never sanitizes caller-supplied text, so anyone could embed a second
    // peer's literal tag string inside a message posted to a DIFFERENT
    // peer's wall, and it would have surfaced here as a genuine entry on
    // that other peer's wall too -- a real griefing vector against content
    // its own subject can't remove. Re-validate that the found tag actually
    // appears as its own anchored token before trusting a hit.
    private static func matchesTag(_ text: String, tag: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(pattern: "\(escaped)\\b") else {
            return text.contains(tag)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Every entry on this peer's wall, newest first, from any author --
    /// unlike banner/gradient there is no sender filter here, since the
    /// whole point is that other people write these.
    public static func entries(context: AccountContext, peerId: PeerId, limit: Int32 = 100) -> Signal<[Message], NoError> {
        let expectedTag = tag(for: peerId)
        return SGCommunityGroup.find(context: context, tag: expectedTag, fromId: nil, limit: limit)
        |> map { messages -> [Message] in
            return messages.filter { matchesTag($0.text, tag: expectedTag) }
        }
    }

    /// Write an entry on someone's wall. The tag is prepended automatically
    /// -- callers pass the plain text a person typed, same as
    /// MargeletGroup.tagged() does for its own composer integration.
    public static func post(context: AccountContext, peerId: PeerId, text: String) -> Signal<MessageId?, NoError> {
        let tagged = "\(tag(for: peerId))\n\(text)"
        return SGCommunityGroup.post(context: context, text: tagged)
    }

    /// The text a reader should actually see: the leading wall tag (and the
    /// newline/space right after it) stripped, same as
    /// MargeletGroup.hideTags(). The underlying message is never modified --
    /// only display strips it, so the tag is always there for `entries(_:)`
    /// to find later, no matter how many times this runs on the same text.
    public static func displayText(_ text: String) -> String {
        guard let range = text.range(of: #"^#margy_wall_[a-z]+\d+[ \t]*\n?"#, options: .regularExpression) else {
            return text
        }
        return String(text[range.upperBound...])
    }
}
