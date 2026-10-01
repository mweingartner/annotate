import Foundation

extension URL {
    /// Whether writing here would replace `other` on disk: the same file reached by
    /// another path, a symbolic or hard link, or a name differing only in case on a
    /// case-insensitive volume. A destination that doesn't exist yet is never the source.
    func isSameFile(as other: URL?) -> Bool {
        guard let other else { return false }
        let mine = resolvingSymlinksInPath().standardizedFileURL, theirs = other.resolvingSymlinksInPath().standardizedFileURL
        if mine == theirs { return true }
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let a = try? mine.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let b = try? theirs.resourceValues(forKeys: [key]).fileResourceIdentifier else { return false }
        return a.isEqual(b)
    }
}
