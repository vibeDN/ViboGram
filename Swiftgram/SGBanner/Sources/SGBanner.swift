import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGCommunityGroup

// MARK: ViboGram - profile banner (a picture behind the avatar), ported
// from Margelet's MargeletBanner.java. Data layer only, per this project's
// usual pattern (see SGBadges) -- turning the returned media reference into
// actual pixels on screen is a separate, later UI pass, using this app's
// own existing chat-photo image pipeline (chatMessagePhoto/TransformImageNode)
// rather than reimplementing bitmap decode/caching by hand the way the
// Android original does (MediaBox already caches fetched resources; no
// point duplicating that here).
//
// Storage: same shared group as SGGradient (see SGCommunityGroup), one
// photo message per user tagged #margy_banner. Setting a new banner sends a
// new tagged photo, then removes the old one after a delay (send first, so
// a failed send never leaves the account banner-less); clearing is deleting
// that message, which a person can also do by hand in the group itself,
// without this app at all.
public enum SGBanner {
    /// The message id of the account's own current banner post, if this
    /// process has found or just created one. Not a cache of *other*
    /// people's banners: rendering those goes through the normal
    /// find-then-fetch path each time a profile is opened, same as any other
    /// chat photo in this app.
    ///
    /// MARK: ViboGram - like SGBadges' own in-memory cache, this has no
    /// synchronization of its own and must only be read/written from the
    /// main thread -- true of `set`/`clear`'s current call pattern (`start`
    /// callbacks run via `deliverOnMainQueue`, and both are meant to be
    /// called from UI actions) but not enforced by the type system. `generation`
    /// (below) is the one piece that genuinely needs to be thread-safe
    /// regardless, since it's *written* synchronously at the top of
    /// `set`/`clear` before any thread-hopping happens.
    private static var ownMessageId: [PeerId: MessageId] = [:]

    // MARK: ViboGram - bugfix, caught by independent review: guards against
    // two problems a slow network can cause with no coordination between
    // overlapping calls otherwise --
    // (1) set() failing to post (post() can legitimately return nil) must
    //     NOT delete the still-good old banner it was trying to replace, or
    //     a failed upload leaves the account with no banner at all, exactly
    //     backwards from the "send first" ordering's whole purpose;
    // (2) a set() started before a clear() but completing after it must not
    //     resurrect a banner the user explicitly just removed.
    // Every set()/clear() call captures the current generation for that
    // peer before doing anything async, and only applies its own result
    // (recording a new message id, scheduling an old one's removal) if that
    // generation is still current when the async work finishes -- i.e. no
    // newer set()/clear() call for the same peer started in the meantime.
    private static let stateLock = NSLock()
    private static var generation: [PeerId: Int] = [:]

    private static func nextGeneration(for peerId: PeerId) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = (generation[peerId] ?? 0) + 1
        generation[peerId] = next
        return next
    }

    private static func isCurrent(_ generationToken: Int, for peerId: PeerId) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation[peerId] == generationToken
    }

    public static func find(context: AccountContext, peerId: PeerId) -> Signal<Message?, NoError> {
        return SGCommunityGroup.find(context: context, tag: SGCommunityGroup.tagBanner, fromId: peerId)
        |> map { messages -> Message? in
            // Newest first; the first message that's actually a photo (not
            // some unrelated text mentioning the tag) is the current banner.
            return messages.first(where: { message in
                return message.media.contains(where: { $0 is TelegramMediaImage })
            })
        }
    }

    /// Set the account's own banner from already-available image data.
    /// Picking the image (photo library / camera) is left to the caller --
    /// this module only knows how to get bytes into the shared group.
    public static func set(context: AccountContext, imageData: Data, dimensions: PixelDimensions, completion: (() -> Void)? = nil) {
        let accountPeerId = context.account.peerId
        let token = nextGeneration(for: accountPeerId)

        // MARK: ViboGram - bugfix, caught by independent review: without
        // this, a fresh process (ownMessageId empty) that calls set() has no
        // way to find and eventually clean up a real, still-live old banner
        // from a previous session -- it would silently accumulate orphaned
        // messages in the shared group forever. clear() already had this
        // fallback; set() needs the same one.
        let previousSignal: Signal<MessageId?, NoError>
        if let known = ownMessageId[accountPeerId] {
            previousSignal = .single(known)
        } else {
            previousSignal = find(context: context, peerId: accountPeerId) |> map { $0?.id }
        }

        // MARK: ViboGram - bugfix, caught by the first real CI build to get
        // past the SwiftSignalKitFramework race: standaloneUploadedImage's
        // error type is StandaloneUploadMediaError, not NoError -- the
        // mapToSignal closure has to keep that same error type (it can't
        // just declare a different one), so the conversion down to NoError
        // (needed to combineLatest this with the NoError-typed
        // previousSignal below) happens afterward via `catch`, treating any
        // upload/send failure the same way post() returning nil already
        // does elsewhere in this function -- as "no media reference", not a
        // hard failure.
        let uploadSignal: Signal<AnyMediaReference?, NoError> = standaloneUploadedImage(postbox: context.account.postbox, network: context.account.network, peerId: accountPeerId, text: "", source: .data(imageData), dimensions: dimensions)
        |> mapToSignal { event -> Signal<AnyMediaReference?, StandaloneUploadMediaError> in
            switch event {
            case .progress:
                return .complete()
            case let .result(result):
                switch result {
                case let .media(mediaReference):
                    return .single(mediaReference)
                }
            }
        }
        |> take(1)
        |> `catch` { _ -> Signal<AnyMediaReference?, NoError> in
            return .single(nil)
        }

        let _ = (combineLatest(previousSignal, uploadSignal)
        |> mapToSignal { previous, mediaReference -> Signal<(MessageId?, MessageId?), NoError> in
            guard let mediaReference else {
                return .single((previous, nil))
            }
            return SGCommunityGroup.post(context: context, text: SGCommunityGroup.tagBanner, mediaReference: mediaReference)
            |> map { newMessageId -> (MessageId?, MessageId?) in
                return (previous, newMessageId)
            }
        }
        |> deliverOnMainQueue).start(next: { previous, newMessageId in
            guard isCurrent(token, for: accountPeerId) else {
                // A newer set()/clear() call for this peer has already
                // started -- applying this stale result now (recording an
                // id, deleting something) could undo work that call already
                // did or is about to do.
                completion?()
                return
            }
            if let newMessageId {
                ownMessageId[accountPeerId] = newMessageId
                if let previous {
                    // MARK: ViboGram - only reachable when the new post
                    // actually succeeded -- see the bugfix note above.
                    Queue.mainQueue().after(4.0) {
                        guard isCurrent(token, for: accountPeerId) else {
                            return
                        }
                        SGCommunityGroup.remove(context: context, messageId: previous)
                    }
                }
            }
            // newMessageId == nil means the upload/post failed: leave
            // `previous` (and ownMessageId) exactly as they were, so the
            // account keeps whatever banner it already had.
            completion?()
        })
    }

    /// Clear the account's own banner -- delete its message(s) from the
    /// group. Searches first if this process doesn't already know the
    /// message id (e.g. app was relaunched since the banner was set).
    public static func clear(context: AccountContext, completion: (() -> Void)? = nil) {
        let accountPeerId = context.account.peerId
        let token = nextGeneration(for: accountPeerId)
        if let known = ownMessageId[accountPeerId] {
            SGCommunityGroup.remove(context: context, messageId: known)
            ownMessageId.removeValue(forKey: accountPeerId)
            completion?()
            return
        }
        let _ = (SGCommunityGroup.find(context: context, tag: SGCommunityGroup.tagBanner, fromId: accountPeerId)
        |> deliverOnMainQueue).start(next: { messages in
            guard isCurrent(token, for: accountPeerId) else {
                completion?()
                return
            }
            for message in messages {
                SGCommunityGroup.remove(context: context, messageId: message.id)
            }
            completion?()
        })
    }
}
