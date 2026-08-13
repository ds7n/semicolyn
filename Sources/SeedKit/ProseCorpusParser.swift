// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Tokenizes prose running text into per-sentence token sequences for the seed
/// builder. Sentence boundaries are `.!?` and newlines; tokens are lowercased,
/// stripped of surrounding punctuation, and dropped if they contain no letter.
public enum ProseCorpusParser {
    public static func sentences(fromText text: String) -> [[String]] {
        let boundaries = CharacterSet(charactersIn: ".!?\n")
        let rawSentences = text.components(separatedBy: boundaries)
        var result: [[String]] = []
        for raw in rawSentences {
            let tokens = raw
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
                .map { token -> String in
                    token.trimmingCharacters(in: .punctuationCharacters).lowercased()
                }
                .filter { tok in
                    !tok.isEmpty && tok.contains(where: { $0.isLetter })
                }
            if !tokens.isEmpty { result.append(tokens) }
        }
        return result
    }
}
