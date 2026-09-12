import Foundation

/// Finding a project by name. A name that nearly matches one already there is a slip,
/// not a new project: "NightSleeper" next to "Sleeper Train", "Braindump" next to
/// "Out of Mind". (Director, 12 Sep 2026: two sessions made empty duplicates that way.)
public enum Projects {
    /// Letters and digits only, lowercased: "Sleeper Train" and "sleepertrain" agree.
    public static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The project whose name is the same as `name` in every way that matters.
    public static func exact(_ name: String, in all: [Project]) -> Project? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return all.first { key($0.name) == k }
    }

    /// A project whose name is close to `name`: one contains the other, they differ by
    /// a couple of characters, or they share a real word ("NightSleeper" and "Sleeper
    /// Train"). Nil when `name` is its own thing.
    public static func nearMiss(_ name: String, in all: [Project]) -> Project? {
        let k = key(name)
        guard k.count >= 3 else { return nil }
        let mine = words(name)
        return all.first { other in
            let o = key(other.name)
            guard o.count >= 3, o != k else { return false }
            if o.contains(k) || k.contains(o) { return true }
            if distance(o, k) <= (max(o.count, k.count) > 8 ? 2 : 1) { return true }
            let theirs = words(other.name)
            return mine.contains { w in theirs.contains { t in w == t || (w.count >= 5 && t.count >= 5 && distance(w, t) <= 1) } }
        }
    }

    /// The words in a name, lowercased, camel case split: "NightSleeper" is night and sleeper.
    static func words(_ name: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && previousWasLower && !current.isEmpty { out.append(current); current = "" }
                current.append(ch.lowercased())
                previousWasLower = ch.isLowercase
            } else {
                if !current.isEmpty { out.append(current); current = "" }
                previousWasLower = false
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { $0.count >= 4 }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
