import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import SGCommunityGroup

// MARK: ViboGram - profile gradient (two colors instead of Telegram's own
// profile-header treatment), ported from Margelet's MargeletGradient.java.
// Data + color-math layer only, deliberately UIKit-free -- colors are plain
// packed 0xRRGGBB values here, matching the hex-string convention SGBadges
// already uses (decode to UIColor at the point of use, not in the data
// layer). Actually painting a gradient backdrop / rewiring the profile
// screen's theme-color lookups (Margelet's `Palette`/`Backdrop` classes) is
// a separate, later UI pass -- this only gets the two colors safely from
// "found in the shared group" to "usable by whatever draws them".
//
// Storage: same shared group as SGBanner (see SGCommunityGroup). Two colors
// as plain text, not a photo -- `#margy_gradient RRGGBB-RRGGBB` -- so it's a
// few bytes, found instantly by search, and readable by anyone who wanders
// into the group not knowing what it means.
public enum SGGradient {
    public struct Pair: Equatable {
        public let from: UInt32   // 0xRRGGBB
        public let to: UInt32     // 0xRRGGBB

        public init(from: UInt32, to: UInt32) {
            self.from = from & 0xFFFFFF
            self.to = to & 0xFFFFFF
        }
    }

    // MARK: ViboGram - main-thread-only contract, same as SGBanner's
    // identical cache (see its fuller comment).
    private static var ownMessageId: [PeerId: MessageId] = [:]

    // MARK: ViboGram - same generation-token guard as SGBanner, and for the
    // identical two reasons (caught by independent review): don't delete a
    // still-good old gradient when the new post silently failed, and don't
    // let a slow set() resurrect a gradient a since-completed clear() just
    // removed. See SGBanner.swift's fuller comment on this. Lock-protected
    // (unlike ownMessageId) since this is written synchronously before any
    // thread-hopping, so it can't rely on an assumed main-thread caller the
    // way the rest of this file's state does.
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

    private static let pattern = try! NSRegularExpression(pattern: "#margy_gradient\\s+([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})\\b")

    public static func describe(_ pair: Pair) -> String {
        return String(format: "\(SGCommunityGroup.tagGradient) %06X-%06X", pair.from, pair.to)
    }

    /// Parse a message's text back into a color pair, or nil if it isn't
    /// one (or isn't well-formed -- a stray "#margy_gradient" mention with
    /// no valid hex pair after it is not treated as a match, same as the
    /// Java original: the regex requires an exact well-formed pair).
    public static func parse(_ text: String) -> Pair? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let fromRange = Range(match.range(at: 1), in: text),
              let toRange = Range(match.range(at: 2), in: text),
              let from = UInt32(text[fromRange], radix: 16),
              let to = UInt32(text[toRange], radix: 16) else {
            return nil
        }
        return Pair(from: from, to: to)
    }

    /// The first message (newest first) whose text actually parses as a
    /// well-formed gradient -- shared by `find()` and `set()`'s
    /// find-the-old-one-to-clean-up fallback, so both agree on exactly
    /// which message counts as "the" current gradient.
    private static func findMessage(context: AccountContext, peerId: PeerId) -> Signal<Message?, NoError> {
        return SGCommunityGroup.find(context: context, tag: SGCommunityGroup.tagGradient, fromId: peerId)
        |> map { messages -> Message? in
            return messages.first(where: { parse($0.text) != nil })
        }
    }

    public static func find(context: AccountContext, peerId: PeerId) -> Signal<Pair?, NoError> {
        return findMessage(context: context, peerId: peerId)
        |> map { message -> Pair? in
            return message.flatMap { parse($0.text) }
        }
    }

    public static func set(context: AccountContext, pair: Pair, completion: (() -> Void)? = nil) {
        let accountPeerId = context.account.peerId
        let token = nextGeneration(for: accountPeerId)

        // MARK: ViboGram - bugfix, caught by independent review: same
        // "find the real old one on a fresh process" fallback as SGBanner.
        let previousSignal: Signal<MessageId?, NoError>
        if let known = ownMessageId[accountPeerId] {
            previousSignal = .single(known)
        } else {
            previousSignal = findMessage(context: context, peerId: accountPeerId) |> map { $0?.id }
        }

        let _ = (combineLatest(previousSignal, SGCommunityGroup.post(context: context, text: describe(pair)))
        |> deliverOnMainQueue).start(next: { previous, newMessageId in
            guard isCurrent(token, for: accountPeerId) else {
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
            completion?()
        })
    }

    public static func clear(context: AccountContext, completion: (() -> Void)? = nil) {
        let accountPeerId = context.account.peerId
        let token = nextGeneration(for: accountPeerId)
        if let known = ownMessageId[accountPeerId] {
            SGCommunityGroup.remove(context: context, messageId: known)
            ownMessageId.removeValue(forKey: accountPeerId)
            completion?()
            return
        }
        let _ = (SGCommunityGroup.find(context: context, tag: SGCommunityGroup.tagGradient, fromId: accountPeerId)
        |> deliverOnMainQueue).start(next: { messages in
            guard isCurrent(token, for: accountPeerId) else {
                completion?()
                return
            }
            for message in messages where parse(message.text) != nil {
                SGCommunityGroup.remove(context: context, messageId: message.id)
            }
            completion?()
        })
    }

    // MARK: - Color math, ported directly from MargeletGradient.java.
    //
    // Perceived brightness uses Rec. 709 weights deliberately matching
    // Theme's own `computePerceivedBrightness` threshold (0.721) rather than
    // the more commonly-seen 0.299/0.587/0.114 weights -- so a color choice
    // made here lands on the same side of "light or dark" that this app's
    // own button-label-color logic would independently conclude, instead of
    // disagreeing right at the boundary where it matters most.

    /// Our own threshold for gradient text/ink color: lighter → black text,
    /// darker → white text.
    public static let inkThreshold: Double = 0.62

    /// The threshold this app's own Theme code uses to decide whether a
    /// color counts as "light" for button-label purposes. Recorded here
    /// because the gradient's own button-tint color must land on the same
    /// side of it as `ink(_:)`'s choice, or a dark gradient could produce a
    /// dark button with a black label.
    public static let themeLightThreshold: Double = 0.721

    public static func brightness(_ color: UInt32) -> Double {
        let r = Double((color >> 16) & 0xFF)
        let g = Double((color >> 8) & 0xFF)
        let b = Double(color & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
    }

    public static func mix(_ from: UInt32, _ to: UInt32, _ part: Double) -> UInt32 {
        let part = max(0, min(1, part))
        func channel(_ shift: Int) -> UInt32 {
            let f = Double((from >> shift) & 0xFF)
            let t = Double((to >> shift) & 0xFF)
            return UInt32(f + (t - f) * part) << shift
        }
        return (channel(16) & 0xFF0000) | (channel(8) & 0xFF00) | (channel(0) & 0xFF)
    }

    /// Move a color's brightness toward `target`, blending with white (to
    /// get lighter) or black (to get darker) as needed.
    public static func toBrightness(_ color: UInt32, _ target: Double) -> UInt32 {
        let now = brightness(color)
        if target > now {
            if now >= 1 {
                return color
            }
            return mix(color, 0xFFFFFF, (target - now) / (1 - now))
        }
        if now <= 0 {
            return color
        }
        return mix(color, 0x000000, 1 - target / now)
    }

    /// Text/ink color to write over this gradient: pure black or pure white,
    /// 0x000000 / 0xFFFFFF, chosen by the midpoint's perceived brightness.
    public static func ink(_ pair: Pair) -> UInt32 {
        return brightness(mix(pair.from, pair.to, 0.5)) > inkThreshold ? 0x000000 : 0xFFFFFF
    }

    /// Button tint color over this gradient: the gradient's own midpoint,
    /// nudged in brightness so it stays legible and lands on the theme's own
    /// light/dark side consistent with `ink(_:)`'s choice.
    public static func buttons(_ pair: Pair) -> UInt32 {
        let middle = mix(pair.from, pair.to, 0.5)
        let now = brightness(middle)
        let target = ink(pair) == 0x000000
            ? max(now - 0.06, themeLightThreshold + 0.08)
            : min(now + 0.10, themeLightThreshold - 0.14)
        return toBrightness(middle, target)
    }

    /// Profile-card background color over this gradient: the midpoint,
    /// darkened -- theme-independent by design (see the header comment on
    /// the future `Palette`-equivalent this feeds).
    public static func card(_ pair: Pair) -> UInt32 {
        let middle = mix(pair.from, pair.to, 0.5)
        return toBrightness(middle, brightness(middle) * 0.86)
    }
}
