//
//  TeleprompterLayout.swift
//  FunNotch
//
//  Lays a script out once, with CoreText, into lines with fixed positions, and
//  draws it in short horizontal slices ("chunks"). Both exist so that nothing
//  has to be recomputed while the text scrolls: the scrolling itself is one
//  Core Animation move of the layer that holds the slices, and only the slices
//  near the reading line are ever rasterised, so a long script costs a few
//  megabytes instead of one enormous bitmap.
//
//  The layout also knows which line every word sits on. The scroll duration
//  (words remaining) and voice following (jump to the line of a heard word)
//  both come from that table.
//
//  Coordinates: "from the top" values (`top`, `baseline`) measure down from the
//  first line; layers are y-up, so drawing converts once.
//

import AppKit
import CoreText

final class TeleprompterTextLayout {
    struct Line {
        /// nil for a blank line (paragraph gap).
        let text: CTLine?
        let top: CGFloat
        /// Baseline, measured down from the top of the text.
        let baseline: CGFloat
        let height: CGFloat
        /// Horizontal pen offset that centres the line.
        let x: CGFloat
        /// Index of the first word that starts on this line, or of the next word
        /// when the line holds none.
        let firstWord: Int
    }

    /// A run of consecutive lines drawn into one layer.
    struct Chunk {
        let firstLine: Int
        let lastLine: Int
        let top: CGFloat
        let height: CGFloat
    }

    let lines: [Line]
    let chunks: [Chunk]
    /// Normalised words (lowercase, no punctuation, no diacritics) in reading
    /// order; the same normalisation is applied to what the recogniser hears.
    let words: [String]
    /// Line index of every word.
    let wordLine: [Int]
    let width: CGFloat
    let height: CGFloat

    /// Slices stay well below the texture limit and small enough that a handful
    /// of them cover the area around the reading line.
    private static let chunkHeight: CGFloat = 340

    init(script: String, placeholder: String, fontSize: CGFloat, width: CGFloat) {
        let isPlaceholder = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = (isPlaceholder ? placeholder : script)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let ascent = ceil(font.ascender)
        let descent = ceil(-font.descender)
        let leading = ceil(font.leading)
        let spacing = (fontSize * 0.3).rounded()
        // One height for every line keeps the scroll even; a line that borrows
        // a taller fallback glyph is clipped a little rather than shifting.
        let lineHeight = ascent + descent + leading + spacing
        // Without a colour of its own Core Text draws black, whatever the
        // context's fill is; this makes the lines take the fill instead.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]

        var lines: [Line] = []
        var words: [String] = []
        var wordLine: [Int] = []
        var y: CGFloat = 0

        for paragraph in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(paragraph)
            let ns = text as NSString

            if text.allSatisfy(\.isWhitespace) {
                let gap = (lineHeight * 0.6).rounded()
                lines.append(Line(text: nil, top: y, baseline: y, height: gap, x: 0, firstWord: words.count))
                y += gap
                continue
            }

            // Words of this paragraph with the UTF-16 offset each one starts at,
            // so that a line break range can be turned into "which words".
            var tokens: [(location: Int, word: Int)] = []
            if !isPlaceholder {
                var location = 0
                let length = ns.length
                while location < length {
                    while location < length, Self.isSpace(ns.character(at: location)) { location += 1 }
                    let wordStart = location
                    while location < length, !Self.isSpace(ns.character(at: location)) { location += 1 }
                    guard location > wordStart else { continue }
                    let normalised = Self.normalise(ns.substring(with: NSRange(location: wordStart, length: location - wordStart)))
                    // A lone dash or bullet is drawn but is not a word anyone says.
                    guard !normalised.isEmpty else { continue }
                    tokens.append((wordStart, words.count))
                    words.append(normalised)
                    wordLine.append(0)
                }
            }

            let attributed = NSAttributedString(string: text, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
            var start = 0
            var next = 0
            while start < ns.length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                if count < 1 { count = 1 }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let end = start + count
                let index = lines.count
                let first = next < tokens.count ? tokens[next].word : words.count
                while next < tokens.count, tokens[next].location < end {
                    wordLine[tokens[next].word] = index
                    next += 1
                }
                let pen = CGFloat(CTLineGetPenOffsetForFlush(line, 0.5, Double(width)))
                lines.append(Line(
                    text: line, top: y, baseline: y + spacing / 2 + ascent,
                    height: lineHeight, x: pen, firstWord: first
                ))
                y += lineHeight
                start = end
            }
        }

        // Group lines into slices.
        var chunks: [Chunk] = []
        var firstLine = 0
        var chunkTop: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let bottom = line.top + line.height
            if bottom - chunkTop >= Self.chunkHeight || index == lines.count - 1 {
                chunks.append(Chunk(firstLine: firstLine, lastLine: index, top: chunkTop, height: bottom - chunkTop))
                firstLine = index + 1
                chunkTop = bottom
            }
        }

        self.lines = lines
        self.chunks = chunks
        self.words = words
        self.wordLine = wordLine
        self.width = width
        self.height = max(y, 1)
    }

    // MARK: - Lookups

    func mid(ofLine index: Int) -> CGFloat {
        let line = lines[min(max(index, 0), lines.count - 1)]
        return line.top + line.height / 2
    }

    /// Scroll offset (distance from the top of the text to the reading line)
    /// with the first line sitting on the reading line.
    var startOffset: CGFloat { mid(ofLine: 0) }

    /// Offset with the last line on the reading line.
    var endOffset: CGFloat { mid(ofLine: lines.count - 1) }

    /// The line the reading line points at for a given offset.
    func lineIndex(atOffset offset: CGFloat) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].top <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The first word on the line at the reading line (0 when there are no words).
    func wordIndex(atOffset offset: CGFloat) -> Int {
        guard !words.isEmpty else { return 0 }
        return min(lines[lineIndex(atOffset: offset)].firstWord, words.count - 1)
    }

    /// The offset that puts the line holding `word` on the reading line.
    func offset(forWord word: Int) -> CGFloat {
        guard !words.isEmpty else { return startOffset }
        return mid(ofLine: wordLine[min(max(word, 0), words.count - 1)])
    }

    // MARK: - Words

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Lowercase, no punctuation, no diacritics. "ł" has no decomposition, so
    /// it is folded by hand; both sides of a comparison go through here, so
    /// what matters is only that they agree.
    static func normalise(_ word: String) -> String {
        let folded = word.lowercased()
            .replacingOccurrences(of: "ł", with: "l")
            .folding(options: .diacriticInsensitive, locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
}

// MARK: - Drawing

/// One slice of the script. Plain white text on clear: dimming and fades are a
/// mask over the whole prompter, so drawing happens once per slice.
final class TeleprompterChunkLayer: CALayer {
    var layout: TeleprompterTextLayout?
    var chunk: TeleprompterTextLayout.Chunk?

    override func draw(in context: CGContext) {
        guard let layout, let chunk else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.textMatrix = .identity
        for index in chunk.firstLine ... chunk.lastLine {
            let line = layout.lines[index]
            guard let text = line.text else { continue }
            context.textPosition = CGPoint(x: line.x, y: chunk.height - (line.baseline - chunk.top))
            CTLineDraw(text, context)
        }
    }
}
