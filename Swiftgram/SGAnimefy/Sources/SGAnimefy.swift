import Foundation

// MARK: ViboGram - "Anime-ify" outgoing text. Idea and mechanism ported from
// Margelet's own equivalent plugin (deterministic per-message/per-word
// pseudo-random rolls gating a word-swap dictionary, first-word stutter,
// trailing particle, kaomoji insertion, and a heart tail; links/mentions/
// commands are skipped entirely; a length safety cutoff falls back to the
// untouched text). The word/kaomoji/particle lists below are our own --
// deliberately not the same content as the source plugin, only the same
// class of technique.

public enum SGAnimefyIntensity: String, CaseIterable {
    case mild
    case normal
    case max
}

public struct SGAnimefyOptions {
    public var wordSwaps: Bool
    public var stutter: Bool
    public var particles: Bool
    public var kaomoji: Bool
    public var hearts: Bool

    public init(wordSwaps: Bool, stutter: Bool, particles: Bool, kaomoji: Bool, hearts: Bool) {
        self.wordSwaps = wordSwaps
        self.stutter = stutter
        self.particles = particles
        self.kaomoji = kaomoji
        self.hearts = hearts
    }
}

public enum SGAnimefy {
    // Small, generic set -- intentionally not a large/creative word list.
    private static let wordSwaps: [String: String] = [
        "привет": "приветик",
        "пока": "покеда",
        "да": "агась",
        "нет": "не-а",
        "спасибо": "спасибки",
        "круто": "класнó",
        "хорошо": "чудненько",
        "ладно": "лады",
    ]
    private static let kaomoji = ["(๑˃ᴗ˂)ﻭ", "(¬‿¬)", "(´｡• ᵕ •｡`)", "ヽ(°〇°)ﾉ", "(＾▽＾)"]
    private static let particles = ["нья", "десу", "кун", "тян"]
    private static let hearts = ["💕", "✨", "🌸", "⭐️"]
    private static let lengthCeiling = 4096

    private static func seed(for text: String, salt: Int) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in text.unicodeScalars {
            hash = (hash &* 131 &+ UInt64(scalar.value)) & 0xFFFFFFF
        }
        return (hash &+ UInt64(bitPattern: Int64(salt)) &* 7919) & 0xFFFFFFF
    }

    private static func roll(_ text: String, _ wordIndex: Int, _ axis: Int) -> Double {
        let s = seed(for: text, salt: wordIndex &* 10 &+ axis)
        return Double(s % 1000) / 1000.0
    }

    private struct Thresholds {
        let swap: Double
        let stutter: Double
        let particle: Double
        let kaomoji: Double
        let heartCount: Int
    }

    private static func thresholds(for intensity: SGAnimefyIntensity) -> Thresholds {
        switch intensity {
        case .mild:
            return Thresholds(swap: 0.15, stutter: 0.08, particle: 0.06, kaomoji: 0.06, heartCount: 1)
        case .normal:
            return Thresholds(swap: 0.3, stutter: 0.18, particle: 0.15, kaomoji: 0.15, heartCount: 2)
        case .max:
            return Thresholds(swap: 0.55, stutter: 0.35, particle: 0.3, kaomoji: 0.3, heartCount: 3)
        }
    }

    private static func isUntouchable(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard let first = lower.first else {
            return true
        }
        if first == "@" || first == "#" || first == "/" {
            return true
        }
        for marker in ["://", "t.me/", "www.", ".com", ".ru", ".org", ".рф"] {
            if lower.contains(marker) {
                return true
            }
        }
        return false
    }

    // ("«привет!»" -> "«", "привет", "!»")
    private static func splitPunctuation(_ word: String) -> (String, String, String) {
        var start = word.startIndex
        var end = word.endIndex
        while start < end, !word[start].isLetter, !word[start].isNumber {
            start = word.index(after: start)
        }
        while end > start, !word[word.index(before: end)].isLetter, !word[word.index(before: end)].isNumber {
            end = word.index(before: end)
        }
        return (String(word[word.startIndex..<start]), String(word[start..<end]), String(word[end..<word.endIndex]))
    }

    private static func matchCase(_ original: String, _ replacement: String) -> String {
        if original.count > 1, original == original.uppercased() {
            return replacement.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private static func stutter(_ word: String) -> String {
        guard let first = word.first, first.isLetter else {
            return word
        }
        return "\(first)-\(word)"
    }

    public static func transform(_ text: String, intensity: SGAnimefyIntensity, options: SGAnimefyOptions) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        if let firstNonSpace = text.first(where: { !$0.isWhitespace }), firstNonSpace == "/" {
            // Command -- don't touch, matches the send-path convention elsewhere.
            return text
        }

        let bar = thresholds(for: intensity)
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var wordIndex = 0
        var isFirstWord = true

        for word in words {
            if word.isEmpty {
                out.append(word)
                continue
            }
            wordIndex += 1
            if isUntouchable(word) {
                out.append(word)
                isFirstWord = false
                continue
            }
            let (lead, core, trail) = splitPunctuation(word)
            var newCore = core
            if !core.isEmpty {
                let lower = core.lowercased()
                if options.wordSwaps, let swap = wordSwaps[lower], roll(text, wordIndex, 1) < bar.swap {
                    newCore = matchCase(core, swap)
                }
                if options.stutter, isFirstWord, roll(text, wordIndex, 2) < bar.stutter {
                    newCore = stutter(newCore)
                }
                if options.particles, roll(text, wordIndex, 3) < bar.particle {
                    let pick = particles[Int(roll(text, wordIndex, 4) * Double(particles.count)) % particles.count]
                    newCore = "\(newCore)-\(pick)"
                }
            }
            out.append(lead + newCore + trail)
            isFirstWord = false
            if options.kaomoji, roll(text, wordIndex, 5) < bar.kaomoji {
                let pick = kaomoji[Int(roll(text, wordIndex, 6) * Double(kaomoji.count)) % kaomoji.count]
                out.append(pick)
            }
        }

        var result = out.joined(separator: " ")
        if options.hearts, bar.heartCount > 0 {
            var tail: [String] = []
            for i in 0..<bar.heartCount {
                let pick = hearts[Int(roll(text, 100 + i, 8) * Double(hearts.count)) % hearts.count]
                tail.append(pick)
            }
            result += " " + tail.joined()
        }

        // Better to send the untouched original than a truncated decoration.
        if result.count > lengthCeiling {
            return text
        }
        return result
    }
}
