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
    /// The tag a given peer's wall entries carry. Groups/channels (negative
    /// ids) get a "c" prefix since hashtags can't contain "-" -- without it,
    /// a channel and a person sharing the same numeric id would collide on
    /// one wall.
    public static func tag(for peerId: PeerId) -> String {
        let raw = peerId.id._internalGetInt64Value()
        return raw >= 0 ? "#margy_wall_\(raw)" : "#margy_wall_c\(-raw)"
    }

    /// Every entry on this peer's wall, newest first, from any author --
    /// unlike banner/gradient there is no sender filter here, since the
    /// whole point is that other people write these.
    public static func entries(context: AccountContext, peerId: PeerId, limit: Int32 = 100) -> Signal<[Message], NoError> {
        return SGCommunityGroup.find(context: context, tag: tag(for: peerId), fromId: nil, limit: limit)
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
        guard let range = text.range(of: #"^#margy_wall_c?\d+[ \t]*\n?"#, options: .regularExpression) else {
            return text
        }
        return String(text[range.upperBound...])
    }
}
