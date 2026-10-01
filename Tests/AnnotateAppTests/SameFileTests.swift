import Foundation
import Testing
@testable import AnnotateApp

/// Exports must never replace the open original, however its path is spelled.
@Suite("Export destinations")
struct SameFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SameFile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test("The same file by symbolic link, hard link, letter case, or a roundabout path is the source")
    func aliasesAreTheSource() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "Report.pdf")
        try Data("%PDF".utf8).write(to: source)
        let symlink = dir.appending(path: "Alias.pdf"), hardlink = dir.appending(path: "Hard.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        #expect(symlink.isSameFile(as: source))
        #expect(hardlink.isSameFile(as: source))
        #expect(dir.appending(path: "sub/../Report.pdf").isSameFile(as: source))
        // The temporary volume is case-insensitive on a default macOS install.
        let other = dir.appending(path: "report.PDF")
        if FileManager.default.fileExists(atPath: other.path) { #expect(other.isSameFile(as: source)) }
    }

    @Test("A different or not-yet-existing file is not the source")
    func othersAreNot() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "Report.pdf"), copy = dir.appending(path: "Copy.pdf")
        try Data("%PDF".utf8).write(to: source)
        try Data("%PDF".utf8).write(to: copy)
        #expect(!copy.isSameFile(as: source))
        #expect(!dir.appending(path: "New.pdf").isSameFile(as: source))
        #expect(!copy.isSameFile(as: nil))
    }
}
