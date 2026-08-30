import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext

// MARK: ViboGram - shared backend for Margelet-interop profile features
// (banner, gradient -- wall deferred, see docs/session-import.md-style
// design note once written). Ported from MargeletGroup.java's design and,
// by the project owner's explicit arrangement with Margelet's author, reuses
// Margelet's own live public group (@margy_underground) directly rather than
// standing up a separate one -- so a banner/gradient set from either fork is
// visible in both.
//
// The whole point of this design (from the original Java doc comment,
// translated): a normal public Telegram group works as a decentralized
// "database" with zero server of our own, because Telegram's own message
// delivery already answers "who sent this" authoritatively -- there is
// nothing to fake and nothing extra to verify. Setting your own banner/
// gradient is "send a tagged message here"; clearing it is "delete your own
// message" -- something a person can do by hand, in the group itself, with
// no dependency on this app at all.
public enum SGCommunityGroup {
    public static let username = "margy_underground"

    public static let tagBanner = "#margy_banner"
    public static let tagGradient = "#margy_gradient"

    // MARK: ViboGram - resolved once per process and cached: the group's
    // peer id is permanent, so re-resolving on every search/post would be a
    // pointless extra network+Postbox round trip every time.
    //
    // MARK: ViboGram - bugfix, caught by independent review: reads/writes of
    // `cachedPeerId` had no synchronization, and multiple call sites
    // (SGBanner/SGGradient/SGWall's find(), plus the debug smoke test
    // combining several of those in one `combineLatest`) can genuinely call
    // `resolveGroup` concurrently on first use. `PeerId` is a small value
    // type, so the realistic worst case was a few redundant
    // `resolvePeerByName` calls rather than a torn value, but it's still a
    // real data race by Swift's own rules -- guarded with a lock instead of
    // leaving it to chance.
    private static let cacheLock = NSLock()
    private static var cachedPeerId: PeerId?

    public static func resolveGroup(context: AccountContext) -> Signal<PeerId?, NoError> {
        cacheLock.lock()
        let existing = cachedPeerId
        cacheLock.unlock()
        if let existing {
            return .single(existing)
        }
        return context.engine.peers.resolvePeerByName(name: username, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(peer) = result else {
                return .complete()
            }
            return .single(peer)
        }
        |> map { peer -> PeerId? in
            guard let peer else {
                return nil
            }
            cacheLock.lock()
            cachedPeerId = peer.id
            cacheLock.unlock()
            return peer.id
        }
    }

    /// Every message this account can see in the group, sent by `fromId`,
    /// whose text contains `tag`. Newest first (Telegram's own search order).
    /// Callers apply whatever further filtering their feature needs (has a
    /// photo, matches a stricter pattern, etc.) -- this only does the
    /// tag half (and, when `fromId` is given, the sender half too).
    ///
    /// `fromId` is nil for the wall (many different authors write about one
    /// subject -- the subject's identity is encoded in the tag itself, e.g.
    /// `#margy_wall_123`, not the sender), and non-nil for banner/gradient
    /// (exactly one author: the subject posting about themselves).
    public static func find(context: AccountContext, tag: String, fromId: PeerId?, limit: Int32 = 20) -> Signal<[Message], NoError> {
        return resolveGroup(context: context)
        |> mapToSignal { groupPeerId -> Signal<[Message], NoError> in
            guard let groupPeerId else {
                return .single([])
            }
            return context.engine.messages.searchMessages(location: .peer(peerId: groupPeerId, fromId: fromId, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: tag, state: nil)
            |> take(1)
            |> map { result, _ -> [Message] in
                return result.messages
            }
        }
    }

    /// Post a message into the group -- text-only (gradient) or with an
    /// attached photo (banner). Returns the new message's id on success, nil
    /// if the group couldn't be resolved or the send never got queued.
    public static func post(context: AccountContext, text: String, mediaReference: AnyMediaReference? = nil) -> Signal<MessageId?, NoError> {
        return resolveGroup(context: context)
        |> mapToSignal { groupPeerId -> Signal<MessageId?, NoError> in
            guard let groupPeerId else {
                return .single(nil)
            }
            let message = EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: mediaReference, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            return enqueueMessages(account: context.account, peerId: groupPeerId, messages: [message])
            |> map { ids -> MessageId? in
                return ids.first.flatMap { $0 }
            }
        }
    }

    /// Remove one of our own messages from the group. A real for-everyone
    /// delete (not "for me") -- this is shared group state read by anyone
    /// with the tag/sender combination, so a "for me" delete would leave
    /// stale content visible to every other reader while looking removed
    /// locally, exactly backwards from what "clear my banner" should do.
    public static func remove(context: AccountContext, messageId: MessageId) {
        let _ = context.engine.messages.deleteMessagesInteractively(messageIds: [messageId], type: .forEveryone).start()
    }
}
