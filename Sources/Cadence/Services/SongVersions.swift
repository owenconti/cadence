import Foundation

/// Other versions of one song, for its Other Versions page.
struct SongVersions {
    /// The same song with the other rating: clean when it's explicit,
    /// explicit when it isn't. Closest match first.
    var counterparts: [TrackItem] = []
    /// Live, acoustic, remixed, re-recorded or otherwise different takes by
    /// the same artist.
    var others: [TrackItem] = []

    var isEmpty: Bool { counterparts.isEmpty && others.isEmpty }
}

/// Decides which catalog songs are versions of a song. Two songs are the same
/// song when their titles match once what tells versions apart is taken out
/// ("(Live)", "- Radio Edit", "[feat. Someone]") and they share a lead
/// artist. Covers by other artists don't count.
enum SongMatch {
    /// A song's title in parts: what's left once version notes are taken out,
    /// for comparing (folded) and for searching (as written), and the notes.
    struct Title: Equatable {
        var base: String
        var searchable: String
        var notes: Set<String>
    }

    static func title(_ raw: String) -> Title {
        // Bracketed parts are notes: "Song (Live)", "Song [Clean]".
        var outside = "", inside = "", notes: [String] = []
        var depth = 0
        for character in raw {
            if character == "(" || character == "[" {
                if depth == 0 { inside = "" } else { inside.append(character) }
                depth += 1
            } else if (character == ")" || character == "]") && depth > 0 {
                depth -= 1
                if depth == 0 { notes.append(inside) } else { inside.append(character) }
            } else if depth == 0 {
                outside.append(character)
            } else {
                inside.append(character)
            }
        }
        // As is a " - " suffix: "Song - Radio Edit", "Song - Remastered 2011".
        if let dash = outside.range(of: " - ") {
            notes.append(String(outside[dash.upperBound...]))
            outside = String(outside[..<dash.lowerBound])
        }
        // And featured artists written into the title.
        let folded = fold(outside)
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = folded.range(of: marker) {
                let cut = folded.distance(from: folded.startIndex, to: range.lowerBound)
                notes.append("feat")
                outside = String(outside.prefix(cut))
                break
            }
        }
        let searchable = outside.trimmingCharacters(in: .whitespaces)
        var base = words(searchable).joined(separator: " ")
        if base.isEmpty { base = words(raw).joined(separator: " ") }
        return Title(base: base, searchable: searchable.isEmpty ? raw : searchable,
                     notes: Set(notes.flatMap(words)))
    }

    /// Notes that make a different take of the song, rather than the same
    /// recording edited, remastered or re-released.
    static let variantWords: Set<String> = [
        "live", "acoustic", "remix", "remixed", "mix", "instrumental", "sped", "slowed", "demo", "karaoke",
        "acapella", "cappella", "unplugged", "reprise", "cover", "extended", "rework", "reworked", "remake",
        "piano", "orchestral", "stripped", "session", "sessions", "vip", "dub", "nightcore", "reverb",
        "rerecorded", "recorded", "taylor's", "symphonic", "lofi", "edm", "club", "bootleg", "flip",
    ]

    static func isVariant(_ title: Title) -> Bool { !title.notes.isDisjoint(with: variantWords) }

    /// A minute or two of the song inside a DJ's set ("Song (Mixed)" on a
    /// "(DJ Mix)" album). The catalog has hundreds of them for a hit, and
    /// nobody's after one.
    static func isDJMixExcerpt(_ candidate: Candidate) -> Bool {
        title(candidate.track.title).notes.contains("mixed") || fold(candidate.track.albumTitle).contains("dj mix")
    }

    /// Talk about the song rather than the song: "Song (Commentary)".
    static func isTalk(_ title: Title) -> Bool { !title.notes.isDisjoint(with: ["commentary", "interview", "spoken"]) }

    /// The artists credited in an artist line, folded: "A & B feat. C" is A, B and C.
    static func artists(_ line: String) -> [String] {
        var parts = [" " + fold(line) + " "]
        for separator in [",", "&", "+", " x ", " and ", " with ", " feat. ", " feat ", " ft. ", " featuring ", " vs. ", " vs "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }.map { " \($0) " }
        }
        return parts.map { words($0).joined(separator: " ") }.filter { !$0.isEmpty }
    }

    /// Whether two artist lines share a lead artist: either one's first
    /// artist is credited on the other.
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let left = artists(a), right = artists(b)
        guard let first = left.first, let other = right.first else { return false }
        return right.contains(first) || left.contains(other)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Letters and numbers, folded, split into words.
    static func words(_ s: String) -> [String] {
        fold(s).components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// A catalog song considered as a version of another.
    struct Candidate {
        var track: TrackItem
        /// Apple Music marks edited versions of explicit songs clean.
        var isClean: Bool
        var isrc: String?
    }

    /// Sorts candidates into the song's versions. `source` is the song as the
    /// catalog has it; candidates come in the order they were found, most
    /// trusted first.
    static func versions(of source: Candidate, among candidates: [Candidate]) -> SongVersions {
        let sourceTitle = title(source.track.title)
        var kept: [Candidate] = [source]
        var result = SongVersions()
        for candidate in candidates {
            let track = candidate.track
            guard track.id != source.track.id, sameArtist(track.artistName, source.track.artistName) else { continue }
            let candidateTitle = title(track.title)
            guard candidateTitle.base == sourceTitle.base, !isDJMixExcerpt(candidate), !isTalk(candidateTitle) else { continue }
            // The same recording again (on a single, a compilation) isn't
            // another version, nor a copy of one already listed.
            let duplicate = kept.contains { seen in
                if let isrc = candidate.isrc, isrc == seen.isrc { return true }
                return fold(seen.track.title) == fold(track.title) && seen.track.isExplicit == track.isExplicit
                    && abs(seen.track.duration - track.duration) <= 2
            }
            guard !duplicate else { continue }
            kept.append(candidate)

            let otherRating = source.track.isExplicit ? candidate.isClean : track.isExplicit
            // An edit for the radio can be a little shorter; anything else
            // that's much longer or shorter is likely a different take.
            let close = abs(track.duration - source.track.duration) <= 20
                || !candidateTitle.notes.isDisjoint(with: ["radio", "edit", "edited"])
            if otherRating, !isVariant(candidateTitle), close {
                result.counterparts.append(track)
            } else {
                result.others.append(track)
            }
        }
        // Closest to the song first: no notes, then nearest in length.
        result.counterparts = result.counterparts.enumerated().sorted { a, b in
            let aPlain = title(a.element.title).notes.isEmpty, bPlain = title(b.element.title).notes.isEmpty
            if aPlain != bPlain { return aPlain }
            let aGap = abs(a.element.duration - source.track.duration), bGap = abs(b.element.duration - source.track.duration)
            return aGap != bGap ? aGap < bGap : a.offset < b.offset
        }.map(\.element)
        result.others = Array(result.others.prefix(24))
        return result
    }
}
