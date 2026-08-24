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
public enum SGTextEffectKind: CaseIterable {
    case dim
    case rainbow
    case sizeBig
}

public enum SGTextEffects {
    public static let openMarker: Character = "\u{2060}"   // WORD JOINER
    public static let closeMarker: Character = "\u{2061}"  // FUNCTION APPLICATION

    private static let kindMarkers: [Character: SGTextEffectKind] = [
        "\u{2062}": .dim,      // INVISIBLE TIMES
        "\u{2063}": .rainbow,  // INVISIBLE SEPARATOR
        "\u{2064}": .sizeBig,  // INVISIBLE PLUS
    ]

    private static let markerForKind: [SGTextEffectKind: Character] = [
        .dim: "\u{2062}",
        .rainbow: "\u{2063}",
        .sizeBig: "\u{2064}",
    ]

    /// The invisible open+kind character sequence to insert before a run that
    /// should get `kind`'s effect; pair with `closeMarker` after the run.
    public static func openSequence(for kind: SGTextEffectKind) -> String {
        guard let marker = markerForKind[kind] else {
            return ""
        }
        return String(openMarker) + String(marker)
    }

    /// Wraps `range` of `text` with the invisible markers for `kind`, so this run
    /// gets decoded and styled wherever `applyEffects` is later called on it.
    public static func wrap(_ text: String, range: Range<String.Index>, kind: SGTextEffectKind) -> String {
        guard let marker = markerForKind[kind] else {
            return text
        }
        var result = text
        result.insert(closeMarker, at: range.upperBound)
        result.insert(contentsOf: [openMarker, marker], at: range.lowerBound)
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
            let kindChar = nsString.substring(with: NSRange(location: kindIndex, length: 1)).first
            guard let kindChar, let kind = kindMarkers[kindChar] else {
                searchStart = kindIndex
                continue
            }
            let contentStart = kindIndex + 1
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
