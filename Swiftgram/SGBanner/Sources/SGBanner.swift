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
    /// process has found or just created one. Needed so `clear()` doesn't
    /// have to re-search when it already knows.
    private static var ownMessageId: [PeerId: MessageId] = [:]

    /// The account's own banner photo, if it has one -- used to know which
    /// account-id → message-id pair to update on `set`/`clear`. Not a cache
    /// of *other* people's banners: rendering those goes through the normal
    /// find-then-fetch path each time a profile is opened, same as any other
    /// chat photo in this app.
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
        let previous = ownMessageId[accountPeerId]
        let _ = (standaloneUploadedImage(postbox: context.account.postbox, network: context.account.network, peerId: accountPeerId, text: "", source: .data(imageData), dimensions: dimensions)
        |> mapToSignal { event -> Signal<AnyMediaReference?, NoError> in
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
        |> mapToSignal { mediaReference -> Signal<MessageId?, NoError> in
            guard let mediaReference else {
                return .single(nil)
            }
            return SGCommunityGroup.post(context: context, text: SGCommunityGroup.tagBanner, mediaReference: mediaReference)
        }
        |> deliverOnMainQueue).start(next: { newMessageId in
            if let newMessageId {
                ownMessageId[accountPeerId] = newMessageId
            }
            if let previous {
                // MARK: ViboGram - remove the old banner only after the new
                // one has actually gone out, matching MargeletBanner.set's
                // own ordering: a failed send should never leave the account
                // with no banner at all when it didn't ask to remove one.
                Queue.mainQueue().after(4.0) {
                    SGCommunityGroup.remove(context: context, messageId: previous)
                }
            }
            completion?()
        })
    }

    /// Clear the account's own banner -- delete its message(s) from the
    /// group. Searches first if this process doesn't already know the
    /// message id (e.g. app was relaunched since the banner was set).
    public static func clear(context: AccountContext, completion: (() -> Void)? = nil) {
        let accountPeerId = context.account.peerId
        if let known = ownMessageId[accountPeerId] {
            SGCommunityGroup.remove(context: context, messageId: known)
            ownMessageId.removeValue(forKey: accountPeerId)
            completion?()
            return
        }
        let _ = (SGCommunityGroup.find(context: context, tag: SGCommunityGroup.tagBanner, fromId: accountPeerId)
        |> deliverOnMainQueue).start(next: { messages in
            for message in messages {
                SGCommunityGroup.remove(context: context, messageId: message.id)
            }
            completion?()
        })
    }
}
