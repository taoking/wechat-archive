import CryptoKit
import Foundation
import XCTest
@testable import WeChatArchiveCore

final class FileAttachmentTests: XCTestCase {
    private func fixture(title: String, data: Data, md5: String? = nil) -> [String: ArchivedSQLiteValue] {
        let digest = md5 ?? Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let xml = "<msg><appmsg><type>6</type><title>\(title)</title><md5>\(digest)</md5><appattach><totallen>\(data.count)</totallen><fileext>txt</fileext></appattach></appmsg></msg>"
        return ["local_type": .integer(49), "create_time": .integer(1_700_000_000), "message_content": .text(xml)]
    }

    func testPlainXMLAndUTF8BlobAreParsedWithoutZstd() {
        let values = fixture(title: "synthetic.txt", data: Data("fixture".utf8))
        XCTAssertEqual(WeChatCompressedTextMessageAdapter().textContent(from: values, rawType: 49), "[文件] synthetic.txt")
        var blob = values
        if case let .text(xml)? = values["message_content"] { blob["message_content"] = .blob(Data(xml.utf8)) }
        XCTAssertEqual(WeChatCompressedTextMessageAdapter().textContent(from: blob, rawType: 49), "[文件] synthetic.txt")
    }

    func testFileRequiresMatchingSizeAndContentMD5AndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FileAttachmentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let month = root.appending(path: "msg/file/2023-11")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let bytes = Data("synthetic attachment bytes".utf8)
        try bytes.write(to: month.appending(path: "synthetic.txt"))
        let adapter = WeChatFileMessageAdapter()
        let input = try adapter.attachment(values: fixture(title: "synthetic.txt", data: bytes), accountRoot: root)
        XCTAssertEqual(input.status, .rawArchived)
        XCTAssertEqual(input.mediaType, .file)
        XCTAssertEqual(input.rawFileURL?.resolvingSymlinksInPath(), month.appending(path: "synthetic.txt").resolvingSymlinksInPath())
        let invalid = try adapter.attachment(values: fixture(title: "synthetic.txt", data: bytes, md5: String(repeating: "0", count: 32)), accountRoot: root)
        XCTAssertNil(invalid.rawFileURL)
        let traversal = try adapter.attachment(values: fixture(title: "../synthetic.txt", data: bytes), accountRoot: root)
        XCTAssertNil(traversal.rawFileURL)
        try FileManager.default.removeItem(at: month.appending(path: "synthetic.txt"))
        try FileManager.default.createSymbolicLink(at: month.appending(path: "synthetic.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(try adapter.attachment(values: fixture(title: "synthetic.txt", data: bytes), accountRoot: root).rawFileURL)
    }

    func testFileMediaStoreCopiesReadOnlySourceAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FileMediaTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.txt")
        let bytes = Data("synthetic read-only file".utf8)
        try bytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path())
        let store = try WeChatArchiveV1MediaStore(root: root)
        let first = try store.storeRawFile(source, mediaType: .file, variant: .raw, sourceFormat: "txt", assetID: "one")
        let second = try store.storeRawFile(source, mediaType: .file, variant: .raw, sourceFormat: "txt", assetID: "two")
        XCTAssertEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: first.relativePath)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
