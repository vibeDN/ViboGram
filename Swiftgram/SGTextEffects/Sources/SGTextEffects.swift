import Foundation
import UIKit

// MARK: ViboGram - Size/Dim/Rainbow text effects, ported from Margelet's
// approach (Android fork, github.com/narezany/Margelet,
// java/margelet/MargeletMarkup.java + MargeletSpans.java). No server-side
// entity exists for these, so the style rides along as invisible Unicode
// markers spliced directly into the plain message text -- harmless on any
// other client (Default_Ignorable_Code_Point), decoded back into visual
// attributes only by clients that know to look for them.
//
// MARK: ViboGram - real cross-client bug (on-device report): a ViboGram user
// sent Rainbow text and a Margelet user saw plain text, no formatting at
// all. Root cause: this file's *entire* encoding scheme was wrong from the
// start. It treated U+2062/2063/2064 as three fixed, literal kind-tags
// (dim/rainbow/big) -- but Margelet actually uses those same three
// codepoints as **ternary digits** (0/1/2) in a small positional-number
// system: OPEN, then 2 trits encoding a *kind* number, then 3 trits encoding
// a *value*, then content, then CLOSE. A single fixed marker character where
// Margelet expects 5 trits doesn't parse as anything valid on their end --
// their parser just skips the whole run as garbage. This also meant
// decoding Margelet-authored formatted messages here was wrong too (reading
// their first value-trit as if it were one of this file's old fixed kind
// markers). Rewritten to match their exact protocol instead of a
// lookalike -- verified against their actual source, not reconstructed from
// memory.
//
// This also fixes "why can't I combine effects" for free: Margelet supports
// combining by genuine nesting (OPEN..OPEN..CLOSE..CLOSE, stack-parsed,
// least-recently-opened-closes-first) rather than one wrap carrying multiple
// flags. This file's decoder now does the same, so composing simply nests a
// fresh single-kind wrap around whatever's already selected -- no special
// "detect and merge into an existing run" logic needed, and it's the same
// thing Margelet itself does, so a run nested by either app decodes
// correctly on both.
//
// Deliberately NOT porting Margelet's own self-promo watermark ("Message
// looks better with @margeletter") that they append to outgoing text when
// this kind of formatting is used -- that's their app's own marketing, not
// part of the actual formatting feature.
public enum SGTextEffectKind: Equatable {
    case dim
    case rainbow
    /// Step index into Margelet's own 14-step, 0.6x-2.0x size ratio scale
    /// (their DIGITS/SIZE_MIN/SIZE_MAX) -- not an absolute point size. The
    /// effect is multiplicative on top of whatever base size the *reading*
    /// client is using, same as Margelet's own behavior, so it stays
    /// sensible regardless of the reader's own font-size setting.
    case size(Int)
}

public enum SGTextEffects {
    public static let openMarker: Character = "\u{2060}"   // WORD JOINER
    public static let closeMarker: Character = "\u{2061}"  // FUNCTION APPLICATION

    // MARK: ViboGram - matches Margelet's TRIT/TRITS exactly: three
    // consecutive Default_Ignorable codepoints right after WORD JOINER /
    // FUNCTION APPLICATION, read as balanced base-3 digits (least
    // significant first), not as three unrelated fixed markers.
    private static let tritBase: UInt16 = 0x2062
    private static let tritCount = 3

    private static let kindTrits = 2
    private static let valueTrits = 3
    private static let markLen = 1 + kindTrits + valueTrits

    private static let kindSize = 0
    private static let kindDim = 1
    private static let kindRainbow = 2
    // MARK: ViboGram - Margelet also has KIND_BUTTON=3 and KIND_EMOJI=4
    // (variable-length payload after the value trits: a length prefix, then
    // that many bytes, each as its own 6-trit group) and KIND_OUTLINE=5.
    // None of those are implemented here (out of scope for this pass), but
    // BUTTON/EMOJI's payload still has to be *skipped correctly* on decode --
    // otherwise this would misread their payload trits as message content,
    // and could desync nesting for anything that comes after. Outline has no
    // payload, so it needs no special skip -- it just isn't rendered.
    private static let kindButton = 3
    private static let kindEmoji = 4
    private static let lenTrits = 5
    private static let byteTrits = 6

    /// Margelet's own SIZE_MIN/SIZE_MAX/DIGITS: 14 discrete steps (0...13)
    /// spanning a 0.6x-2.0x multiplier of whatever size is already in effect.
    public static let sizeStepCount = 14
    private static let sizeMin: Double = 0.6
    private static let sizeMax: Double = 2.0
    // MARK: ViboGram - Margelet's own hard ceiling (`maxTextSize()`, dp(36)
    // there): repeatedly nested/stacked size effects multiply together
    // (each is relative to whatever size is already in effect by the time
    // it's applied), so without a cap a message could be crafted to blow
    // message-list layout up arbitrarily. Same idea here, in points.
    private static let maxRenderedFontSize: CGFloat = 36.0
    // MARK: ViboGram - Margelet's Dim always reduces alpha by a fixed
    // amount (their own Dim span doesn't expose a value dial in the UI
    // either, despite the format technically carrying one) -- picking the
    // same fixed value they use for their own middle-of-the-road case.
    private static let dimValue = 6
    private static let rainbowCycleMs: Double = 4200

    public static func sizeRatio(forStep step: Int) -> Double {
        let clamped = max(0, min(sizeStepCount - 1, step))
        return sizeMin + (sizeMax - sizeMin) * Double(clamped) / Double(sizeStepCount - 1)
    }

    private static func tritDigit(_ value: Int) -> UInt16 {
        return tritBase + UInt16(value)
    }

    private static func numberTrits(_ value: Int, count: Int) -> String {
        var left = max(0, value)
        var scalars: [Unicode.Scalar] = []
        for _ in 0 ..< count {
            scalars.append(Unicode.Scalar(tritDigit(left % tritCount))!)
            left /= tritCount
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func allTrits(_ nsString: NSString, at: Int, count: Int) -> Bool {
        guard at >= 0, at + count <= nsString.length else {
            return false
        }
        for i in 0 ..< count {
            let unit = nsString.character(at: at + i)
            if unit < tritBase || unit >= tritBase + UInt16(tritCount) {
                return false
            }
        }
        return true
    }

    private static func parseTritNumber(_ nsString: NSString, at: Int, count: Int) -> Int {
        var value = 0
        var multiplier = 1
        for i in 0 ..< count {
            let unit = nsString.character(at: at + i)
            value += Int(unit - tritBase) * multiplier
            multiplier *= tritCount
        }
        return value
    }

    /// The invisible open+kind+value character sequence to insert before a
    /// run; pair with `closeMarker` after the run's content.
    public static func openSequence(for kind: SGTextEffectKind) -> String {
        let (wireKind, wireValue): (Int, Int)
        switch kind {
        case .dim:
            (wireKind, wireValue) = (kindDim, dimValue)
        case .rainbow:
            (wireKind, wireValue) = (kindRainbow, 0)
        case let .size(step):
            (wireKind, wireValue) = (kindSize, max(0, min(sizeStepCount - 1, step)))
        }
        return String(openMarker) + numberTrits(wireKind, count: kindTrits) + numberTrits(wireValue, count: valueTrits)
    }

    private struct ParsedRun {
        let kind: Int
        let value: Int
        let contentRange: NSRange
    }

    /// Parses every marker-wrapped run in `nsString`, nesting-aware (a stack,
    /// same as Margelet's own parser) -- returned innermost-closed-first,
    /// same order their own parse() produces.
    private static func parseRuns(in nsString: NSString) -> [ParsedRun] {
        let length = nsString.length
        guard length >= 4 else {
            return []
        }
        var runs: [ParsedRun] = []
        var openStack: [(kind: Int, value: Int, contentStart: Int)] = []
        var i = 0
        while i < length {
            let unit = nsString.character(at: i)
            if unit == UInt16(0x2060), i + markLen <= length, allTrits(nsString, at: i + 1, count: kindTrits + valueTrits) {
                let kind = parseTritNumber(nsString, at: i + 1, count: kindTrits)
                let value = parseTritNumber(nsString, at: i + 1 + kindTrits, count: valueTrits)
                var contentStart = i + markLen
                if kind == kindButton || kind == kindEmoji {
                    guard allTrits(nsString, at: contentStart, count: lenTrits) else {
                        i += 1
                        continue
                    }
                    let payloadLength = parseTritNumber(nsString, at: contentStart, count: lenTrits)
                    contentStart += lenTrits
                    let payloadTritsLength = payloadLength * byteTrits
                    guard allTrits(nsString, at: contentStart, count: payloadTritsLength) else {
                        i += 1
                        continue
                    }
                    contentStart += payloadTritsLength
                }
                openStack.append((kind, value, contentStart))
                i = contentStart
                continue
            } else if unit == UInt16(0x2061), !openStack.isEmpty {
                let top = openStack.removeLast()
                if i > top.contentStart {
                    runs.append(ParsedRun(kind: top.kind, value: top.value, contentRange: NSRange(location: top.contentStart, length: i - top.contentStart)))
                }
            }
            i += 1
        }
        return runs
    }

    /// Scans `attributedString`'s backing text for marker-wrapped runs and layers
    /// the corresponding visual attributes over them, in place. The marker
    /// characters themselves are left untouched -- they're zero-width formatting
    /// characters and render as nothing in any standard text renderer.
    public static func applyEffects(to attributedString: NSMutableAttributedString, baseFont: UIFont) {
        let nsString = attributedString.string as NSString
        for run in parseRuns(in: nsString) {
            apply(kind: run.kind, value: run.value, range: run.contentRange, to: attributedString, baseFont: baseFont)
        }
    }

    /// True if `text` contains at least one marker-wrapped run.
    public static func hasEffects(_ text: String) -> Bool {
        return text.contains(openMarker)
    }

    private static func apply(kind: Int, value: Int, range: NSRange, to attributedString: NSMutableAttributedString, baseFont: UIFont) {
        switch kind {
        case kindSize:
            // MARK: ViboGram - multiplicative on top of whatever font is
            // already in effect at this position (which, for a nested run,
            // may already carry an earlier size/attribute change), same as
            // Margelet's own `resize()` reading `paint.getTextSize()` live
            // rather than a fixed original -- and same reason for the hard
            // cap: nested/stacked size runs multiply together, so without a
            // ceiling a crafted message could grow without bound.
            let currentFont = (attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? baseFont
            let ratio = sizeRatio(forStep: value)
            let wantSize = currentFont.pointSize * CGFloat(ratio)
            attributedString.addAttribute(.font, value: currentFont.withSize(min(wantSize, maxRenderedFontSize)), range: range)
        case kindDim:
            // MARK: ViboGram - Margelet dims by multiplying the *existing*
            // paint alpha, not by overwriting to a fixed gray -- so Dim
            // wrapped around an already-colored run (e.g. nested inside
            // Rainbow) mutes that color rather than replacing it outright.
            let keep = max(0.2, 0.75 - 0.04 * Double(max(0, min(13, value))))
            let existingColor = (attributedString.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? UIColor.label
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            existingColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            attributedString.addAttribute(.foregroundColor, value: UIColor(red: r, green: g, blue: b, alpha: a * CGFloat(keep)), range: range)
        case kindRainbow:
            // MARK: ViboGram - real Margelet animates this continuously (a
            // single hue cycling every 4.2s across the whole run, not a
            // static per-character gradient -- an earlier draft here did a
            // static rainbow gradient, which was never what Margelet
            // actually sends or renders). Matching the live animation would
            // need a redraw-loop hooked into message text rendering, which
            // this app doesn't have for this yet. Renders the current
            // instant's position in the same cycle instead -- a still
            // snapshot, not a moving color, but it uses the same formula and
            // will look different across separate redraws (scrolling,
            // reopening the chat) rather than being permanently frozen on
            // one color.
            let nowMs = Date().timeIntervalSince1970 * 1000
            let hueDegrees = nowMs.truncatingRemainder(dividingBy: rainbowCycleMs) * 360 / rainbowCycleMs
            let color = UIColor(hue: CGFloat(hueDegrees / 360.0), saturation: 0.85, brightness: 0.95, alpha: 1.0)
            attributedString.addAttribute(.foregroundColor, value: color, range: range)
        default:
            // KIND_BUTTON / KIND_EMOJI / KIND_OUTLINE, or anything unknown:
            // not rendered specially here yet -- left as plain text.
            break
        }
    }
}
