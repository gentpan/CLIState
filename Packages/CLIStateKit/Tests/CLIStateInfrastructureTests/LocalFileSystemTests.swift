import CLIStateDomain
@testable import CLIStateInfrastructure
import Darwin
import Foundation
import Testing

@Suite struct LocalFileSystemTests {
    let fs = LocalFileSystem()
    let root: TemporaryDirectory

    init() throws {
        root = try TemporaryDirectory()
        let manager = FileManager.default
        try Data("hello world".utf8).write(to: root.url("file.txt"))
        try Data("#!/bin/sh\n".utf8).write(to: root.url("tool"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path("tool"))
        try Data("locked".utf8).write(to: root.url("readonly.txt"))
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.path("readonly.txt"))
        try manager.createDirectory(atPath: root.path("dir"), withIntermediateDirectories: false)
        try manager.createSymbolicLink(atPath: root.path("link-to-tool"), withDestinationPath: "tool")
        try manager.createSymbolicLink(atPath: root.path("absolute-link"), withDestinationPath: root.path("file.txt"))
        try manager.createSymbolicLink(atPath: root.path("broken"), withDestinationPath: "missing-target")
        try manager.createSymbolicLink(atPath: root.path("dir-link"), withDestinationPath: "dir")
    }

    @Test func attributesReportTheOwner() throws {
        #expect(fs.currentUserID == getuid())
        #expect(fs.attributes(atPath: root.path("file.txt"))?.ownerID == getuid())
        #expect(fs.attributes(atPath: "/usr/bin/true")?.ownerID == 0)
    }

    @Test func attributesReportTimesInodeAndLinks() throws {
        try FileManager.default.linkItem(atPath: root.path("file.txt"), toPath: root.path("hard-link.txt"))
        let accessed = Date(timeIntervalSince1970: 1_789_000_000)
        try FileManager.default.setAttributes([.modificationDate: accessed.addingTimeInterval(-3600)], ofItemAtPath: root.path("tool"))
        var times = [timespec(tv_sec: Int(accessed.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(accessed.timeIntervalSince1970) - 3600, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, root.path("tool"), &times, 0) == 0)

        let file = try #require(fs.attributes(atPath: root.path("file.txt")))
        let link = try #require(fs.attributes(atPath: root.path("hard-link.txt")))
        #expect(file.linkCount == 2)
        #expect(file.inode != nil && file.inode == link.inode)
        #expect(file.statusChangedAt != nil)

        let tool = try #require(fs.attributes(atPath: root.path("tool")))
        #expect(tool.accessedAt == accessed)
        #expect(tool.modifiedAt == accessed.addingTimeInterval(-3600))
        #expect(tool.linkCount == 1)
    }

    @Test func attributesUseLstat() throws {
        let file = try #require(fs.attributes(atPath: root.path("file.txt")))
        #expect(file.kind == .file)
        #expect(file.size == 11)
        #expect(file.modifiedAt != nil)
        #expect(!file.isExecutable)

        #expect(fs.attributes(atPath: root.path("tool"))?.isExecutable == true)
        #expect(fs.attributes(atPath: root.path("dir"))?.kind == .directory)

        let link = try #require(fs.attributes(atPath: root.path("link-to-tool")))
        #expect(link.kind == .symlink)
        #expect(!link.isExecutable)

        #expect(fs.attributes(atPath: root.path("broken"))?.kind == .symlink)
        #expect(fs.attributes(atPath: root.path("missing")) == nil)
        #expect(fs.attributes(atPath: "/dev/null")?.kind == .other)
    }

    @Test func symlinkDestinationIsRaw() throws {
        #expect(try fs.destinationOfSymbolicLink(atPath: root.path("link-to-tool")) == "tool")
        #expect(try fs.destinationOfSymbolicLink(atPath: root.path("broken")) == "missing-target")
        #expect(try fs.destinationOfSymbolicLink(atPath: root.path("absolute-link")) == root.path("file.txt"))
        #expect(throws: (any Error).self) { try fs.destinationOfSymbolicLink(atPath: root.path("file.txt")) }
    }

    @Test func resolvingSymlinksMatchesRealpath() {
        #expect(fs.resolvingSymlinks(atPath: root.path("link-to-tool")) == root.path("tool"))
        #expect(fs.resolvingSymlinks(atPath: root.path("dir-link")) == root.path("dir"))
        #expect(fs.resolvingSymlinks(atPath: root.path("dir-link/../file.txt")) == root.path("file.txt"))
        #expect(fs.resolvingSymlinks(atPath: root.path("broken")) == nil)
        #expect(fs.resolvingSymlinks(atPath: root.path("missing")) == nil)
    }

    @Test func executableFileFollowsSymlinks() {
        #expect(fs.isExecutableFile(atPath: root.path("tool")))
        #expect(fs.isExecutableFile(atPath: root.path("link-to-tool")))
        #expect(!fs.isExecutableFile(atPath: root.path("broken")))
        #expect(!fs.isExecutableFile(atPath: root.path("dir")))
        #expect(!fs.isExecutableFile(atPath: root.path("file.txt")))
    }

    @Test func writabilityUsesAccess() {
        #expect(fs.isWritable(atPath: root.path("file.txt")))
        #expect(fs.isWritable(atPath: root.path("dir")))
        #expect(!fs.isWritable(atPath: root.path("missing")))
        if getuid() != 0 {
            #expect(!fs.isWritable(atPath: root.path("readonly.txt")))
        }
    }

    @Test func directoryContentsAreNamesWithoutDotEntries() throws {
        let names = Set(try fs.contentsOfDirectory(atPath: root.path))
        #expect(names == ["file.txt", "tool", "readonly.txt", "dir", "link-to-tool", "absolute-link", "broken", "dir-link"])
        #expect(try fs.contentsOfDirectory(atPath: root.path("dir-link")).isEmpty)
        #expect(throws: (any Error).self) { try fs.contentsOfDirectory(atPath: root.path("file.txt")) }
        #expect(throws: (any Error).self) { try fs.contentsOfDirectory(atPath: root.path("missing")) }
    }

    @Test func readDataHonoursLimitAndFollowsLinks() throws {
        #expect(try fs.readData(atPath: root.path("file.txt"), maxBytes: 5) == Data("hello".utf8))
        #expect(try fs.readData(atPath: root.path("file.txt"), maxBytes: nil) == Data("hello world".utf8))
        #expect(try fs.readData(atPath: root.path("file.txt"), maxBytes: 0).isEmpty)
        #expect(try fs.readData(atPath: root.path("absolute-link"), maxBytes: 100) == Data("hello world".utf8))
        #expect(throws: (any Error).self) { try fs.readData(atPath: root.path("dir"), maxBytes: nil) }
        #expect(throws: (any Error).self) { try fs.readData(atPath: root.path("broken"), maxBytes: nil) }
        #expect(throws: (any Error).self) { try fs.readData(atPath: "/dev/zero", maxBytes: nil) }
    }

    @Test func protocolExtensionsWorkAgainstRealDisk() {
        #expect(fs.exists(atPath: root.path("broken")))
        #expect(fs.isDirectory(atPath: root.path("dir-link")))
        #expect(!fs.isDirectory(atPath: root.path("link-to-tool")))
        #expect(fs.homeDirectory.hasPrefix("/"))
        #expect(LocalFileSystem(homeDirectory: "/Users/tester").abbreviatingHome("/Users/tester/.local/bin") == "~/.local/bin")
    }
}

@Suite struct LocalTrashTests {
    @Test func missingOrRelativePathThrows() {
        let trash = LocalTrash()
        #expect(throws: (any Error).self) { try trash.moveToTrash(atPath: "/nonexistent-\(UUID().uuidString)") }
        #expect(throws: (any Error).self) { try trash.moveToTrash(atPath: "relative/path") }
    }

    /// Touches the real ~/.Trash, so it only runs on request. The item is moved
    /// back out afterwards; nothing is deleted from the Trash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENABLE_LIVE_TRASH_TESTS"] == "1"))
    func movesBrokenSymlinkItselfToTrash() throws {
        let directory = try TemporaryDirectory()
        let link = directory.path("broken-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "missing-target")

        let trashed = try LocalTrash().moveToTrash(atPath: link)
        defer { try? FileManager.default.moveItem(atPath: trashed.path, toPath: directory.path("restored")) }

        #expect(LocalFileSystem().attributes(atPath: link) == nil)
        #expect(LocalFileSystem().attributes(atPath: trashed.path)?.kind == .symlink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: trashed.path) == "missing-target")
    }
}
