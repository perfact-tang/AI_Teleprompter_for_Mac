import Foundation

public struct Alignment: Equatable {
    public let characterOffset: Int
    public let confidence: Double
}

/// All offsets refer to extended grapheme clusters, so Japanese and emoji stay intact.
public struct ScriptAligner {
    private var characters: [Character] = []
    private var offsets: [Int] = []
    public private(set) var position = 0
    private var pending: Int?
    private var lastAcceptedQuery: [Character] = []

    public init(script: String = "") { load(script) }
    public mutating func load(_ script: String) {
        characters = []; offsets = []; position = 0; pending = nil; lastAcceptedQuery = []
        let normalized = Self.indexedNormalization(script)
        characters = normalized.characters; offsets = normalized.offsets
    }
    public static func normalize(_ text: String) -> [Character] {
        indexedNormalization(text).characters
    }
    private static func indexedNormalization(_ text: String) -> (characters: [Character], offsets: [Int]) {
        let digits: [Character: Int] = ["零":0, "〇":0, "一":1, "二":2, "两":2, "兩":2, "三":3, "四":4, "五":5, "六":6, "七":7, "八":8, "九":9]
        let units: [Character: Int] = ["十":10, "百":100, "千":1000]
        var raw: [Character] = [], sourceOffsets: [Int] = []
        var foldedCache: [Character: String] = [:]
        for (offset, symbol) in text.enumerated() {
            let foldedText: String
            if let cached = foldedCache[symbol] { foldedText = cached }
            else {
                let simplified = String(symbol).applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? String(symbol)
                foldedText = simplified.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                foldedCache[symbol] = foldedText
            }
            for folded in foldedText where folded.isLetter || folded.isNumber {
                raw.append(folded); sourceOffsets.append(offset + 1)
            }
        }
        func digit(_ c: Character) -> Int? { digits[c] ?? (c.isASCII ? c.wholeNumberValue : nil) }
        var result: [Character] = [], mapping: [Int] = [], index = 0
        while index < raw.count {
            guard digit(raw[index]) != nil || units[raw[index]] != nil else {
                result.append(raw[index]); mapping.append(sourceOffsets[index]); index += 1; continue
            }
            let start = index
            while index < raw.count && (digit(raw[index]) != nil || units[raw[index]] != nil) { index += 1 }
            let run = raw[start..<index]
            if run.contains(where: { units[$0] != nil }) && run.count <= 12 {
                var total = 0, current: Int? = nil
                for c in run {
                    if let unit = units[c] { total += (current ?? 1) * unit; current = nil }
                    else if let value = digit(c) { current = (current ?? 0) * 10 + value }
                }
                let converted = Array(String(total + (current ?? 0)))
                result += converted; mapping += Array(repeating: sourceOffsets[index - 1], count: converted.count)
            } else {
                for offset in start..<index {
                    result.append(digit(raw[offset]).flatMap { String($0).first } ?? raw[offset]); mapping.append(sourceOffsets[offset])
                }
            }
        }
        return (result, mapping)
    }
    public mutating func seek(characterOffset: Int) {
        position = offsets.firstIndex(where: { $0 > characterOffset }) ?? characters.count
        pending = nil
        lastAcceptedQuery = []
    }
    public mutating func consume(_ transcript: String) -> Alignment? {
        let query = Array(Self.normalize(transcript).suffix(48))
        guard query.count >= 4, !characters.isEmpty else { return nil }
        guard query != lastAcceptedQuery else { return nil }
        let lower = max(0, position - 28)
        let upper = min(characters.count, position + 140)
        var bestScore = 0.0
        var bestEnd = position
        for end in (lower + 1)...max(lower + 1, upper) where end <= characters.count && end > position {
            let minimum = max(4, query.count - 6)
            let maximum = min(query.count + 6, end - lower)
            guard minimum <= maximum else { continue }
            for length in minimum...maximum {
                let candidate = Array(characters[(end - length)..<end])
                let distance = Self.distance(query, candidate)
                let score = 1 - Double(distance) / Double(max(query.count, length))
                if score > bestScore + 0.001 {
                    bestScore = score; bestEnd = end
                }
            }
        }
        guard bestScore >= 0.72, bestEnd > position, bestEnd - position <= 80 else { pending = nil; return nil }
        // Larger jumps require a second overlapping observation.
        if bestEnd - position > 32 {
            guard let previous = pending, abs(previous - bestEnd) <= 24 else { pending = bestEnd; return nil }
        }
        position = bestEnd; pending = nil; lastAcceptedQuery = query
        return Alignment(characterOffset: offsets[position - 1], confidence: bestScore)
    }
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }
}

/// Shared A/V clock: both tracks subtract exactly the same accumulated pause.
public struct RecordingTimeline {
    public private(set) var pauseOffset: Double = 0
    private var pausedAt: Double?
    public init() {}
    public mutating func pause(at time: Double) { if pausedAt == nil { pausedAt = time } }
    public mutating func resume(at time: Double) {
        if let start = pausedAt { pauseOffset += max(0, time - start); pausedAt = nil }
    }
    public func adjusted(_ time: Double) -> Double { time - pauseOffset }
}
