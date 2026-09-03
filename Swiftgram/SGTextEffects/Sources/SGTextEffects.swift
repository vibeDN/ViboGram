import Foundation
import UIKit

// MARK: ViboGram - Size/Dim/Rainbow text effects, ported from Margelet's approach
// (Android fork). No server-side entity exists for these, so the style rides
// along as invisible Unicode formatting characters spliced directly into the
// plain message text -- harmless on any other client (they render as nothing,
// per Unicode's Default_Ignorable_Code_Point property), decoded back into
// visual attributes only by clients that know to look for them.
//
// Deliberately NOT porting Margelet's own self-promo watermark ("Message
// looks better with @margeletter") that they append to outgoing text when
// this kind of formatting is used -- that's their app's own marketing, not
// part of the actual formatting feature.
public enum SGTextEffectKind: Equatable {
    case dim
    case rainbow
    // MARK: ViboGram - fixed 1.3x multiplier, the original version of this
    // feature. Kept exactly as-is (still decodes the same way) so messages
    // already sent with it keep rendering correctly -- new composes use
    // `.size` instead, which carries an actual point size.
    case sizeBig
    // MARK: ViboGram - follow-up request: an actual size range (13...70)
    // rather than one fixed "big" toggle. See sizeCustomMarker/sizeUnitMarker
    // below for how the point size itself is encoded.
    case size(Int)
}

public enum SGTextEffects {
    public static let openMarker: Character = "\u{2060}"   // WORD JOINER
    public static let closeMarker: Character = "\u{2061}"  // FUNCTION APPLICATION

    private static let dimMarker: Character = "\u{2062}"      // INVISIBLE TIMES
    private static let rainbowMarker: Character = "\u{2063}"  // INVISIBLE SEPARATOR
    private static let sizeBigMarker: Character = "\u{2064}"  // INVISIBLE PLUS
    // MARK: ViboGram - bugfix (caught in review, never shipped): the first
    // version of this encoded the size as two Unicode "Tag" digit characters
    // (the block used for regional-flag emoji sequences, e.g. the England
    // flag). Those are correctly Default_Ignorable, but they live outside
    // the Basic Multilingual Plane -- each one is a UTF-16 *surrogate pair*,
    // not a single unit. Every index in this file (kindIndex, contentStart,
    // the NSRange(location:length: 1) reads) is an NSString/UTF-16 index
    // that assumes 1 marker = 1 unit, same as openMarker/closeMarker/dim/
    // rainbow/sizeBig all being ordinary BMP characters. Reading a Tag digit
    // with length:1 would slice a lone surrogate half out of the string,
    // which isn't valid UTF-16 on its own. Using two more BMP invisible
    // characters instead (still General Punctuation, still
    // Default_Ignorable, right after the ones already in use) keeps every
    // index a plain single-unit step, consistent with the rest of this file.
    // The size is encoded as a *count*, not digits: sizeCustomMarker starts
    // the run, then sizeUnitMarker repeats (size - sizeRange.lowerBound)
    // times before the actual content -- simple tally, decoded by counting
    // consecutive occurrences.
    private static let sizeCustomMarker: Character = "\u{206A}"  // INHIBIT SYMMETRIC SWAPPING (deprecated, still valid & zero-width)
    private static let sizeUnitMarker: Character = "\u{206B}"    // ACTIVATE SYMMETRIC SWAPPING (deprecated, still valid & zero-width)

    /// Valid range for `.size`; values outside this get clamped when encoding.
    public static let sizeRange: ClosedRange<Int> = 13...70

    /// The invisible open+kind(+payload) character sequence to insert before a
    /// run that should get `kind`'s effect; pair with `closeMarker` after the run.
    public static func openSequence(for kind: SGTextEffectKind) -> String {
        switch kind {
        case .dim:
            return String(openMarker) + String(dimMarker)
        case .rainbow:
            return String(openMarker) + String(rainbowMarker)
        case .sizeBig:
            return String(openMarker) + String(sizeBigMarker)
        case let .size(points):
            let clamped = min(max(points, sizeRange.lowerBound), sizeRange.upperBound)
            let tally = String(repeating: sizeUnitMarker, count: clamped - sizeRange.lowerBound)
            return String(openMarker) + String(sizeCustomMarker) + tally
        }
    }

    /// Wraps `range` of `text` with the invisible markers for `kind`, so this run
    /// gets decoded and styled wherever `applyEffects` is later called on it.
    public static func wrap(_ text: String, range: Range<String.Index>, kind: SGTextEffectKind) -> String {
        var result = text
        result.insert(closeMarker, at: range.upperBound)
        result.insert(contentsOf: openSequence(for: kind), at: range.lowerBound)
        return result
    }

    /// Scans `attributedString`'s backing text for marker-wrapped runs and layers
    /// the corresponding visual attributes over them, in place. The marker
    /// characters themselves are left untouched -- they're zero-width formatting
    /// characters and render as nothing in any standard text renderer.
    public static func applyEffects(to attributedString: NSMutableAttributedString, baseFont: UIFont) {
        let nsString = attributedString.string as NSString
        let fullLength = nsString.length
        var searchStart = 0

        while searchStart < fullLength {
            let openRange = nsString.range(of: String(openMarker), range: NSRange(location: searchStart, length: fullLength - searchStart))
            if openRange.location == NSNotFound {
                break
            }
            let kindIndex = openRange.location + openRange.length
            guard kindIndex < fullLength else {
                break
            }
            guard let kindChar = nsString.substring(with: NSRange(location: kindIndex, length: 1)).first else {
                break
            }

            var contentStart = kindIndex + 1
            let kind: SGTextEffectKind
            switch kindChar {
            case dimMarker:
                kind = .dim
            case rainbowMarker:
                kind = .rainbow
            case sizeBigMarker:
                kind = .sizeBig
            case sizeCustomMarker:
                var tally = 0
                let sizeUnitMarkerString = String(sizeUnitMarker)
                while contentStart < fullLength, nsString.substring(with: NSRange(location: contentStart, length: 1)) == sizeUnitMarkerString {
                    tally += 1
                    contentStart += 1
                }
                kind = .size(min(sizeRange.upperBound, sizeRange.lowerBound + tally))
            default:
                searchStart = kindIndex
                continue
            }

            guard contentStart <= fullLength else {
                break
            }
            let closeRange = nsString.range(of: String(closeMarker), range: NSRange(location: contentStart, length: fullLength - contentStart))
            if closeRange.location == NSNotFound {
                break
            }
            let contentRange = NSRange(location: contentStart, length: closeRange.location - contentStart)
            if contentRange.length > 0 {
                apply(kind: kind, range: contentRange, to: attributedString, baseFont: baseFont)
            }
            searchStart = closeRange.location + closeRange.length
        }
    }

    /// True if `text` contains at least one marker-wrapped run.
    public static func hasEffects(_ text: String) -> Bool {
        return text.contains(openMarker)
    }

    private static func apply(kind: SGTextEffectKind, range: NSRange, to attributedString: NSMutableAttributedString, baseFont: UIFont) {
        switch kind {
        case .dim:
            attributedString.addAttribute(.foregroundColor, value: UIColor.gray.withAlphaComponent(0.6), range: range)
        case .sizeBig:
            attributedString.addAttribute(.font, value: baseFont.withSize(baseFont.pointSize * 1.3), range: range)
        case let .size(points):
            attributedString.addAttribute(.font, value: baseFont.withSize(CGFloat(points)), range: range)
        case .rainbow:
            // Moderate saturation/brightness (not raw HSB 1.0/1.0) so it stays
            // readable against both light and dark chat backgrounds, per request.
            let nsString = attributedString.string as NSString
            let total = max(1, range.length)
            var i = range.location
            var step = 0
            while i < range.location + range.length {
                let charRange = nsString.rangeOfComposedCharacterSequence(at: i)
                let hue = CGFloat(step) / CGFloat(total)
                let color = UIColor(hue: hue, saturation: 0.65, brightness: 0.75, alpha: 1.0)
                attributedString.addAttribute(.foregroundColor, value: color, range: charRange)
                i = charRange.location + charRange.length
                step += 1
            }
        }
    }
}
