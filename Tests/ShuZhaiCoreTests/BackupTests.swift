import XCTest
@testable import ShuZhaiCore

final class BackupTests: XCTestCase {
    func testPrefsAndroidFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("prefs.json")
        // Android 版匯出的格式
        try Data(#"{"night":{"t":"b","v":true},"pageMode":{"t":"i","v":1},"ttsRate":{"t":"f","v":1.25},"style":{"t":"s","v":"{\"fontSize\":24,\"dayTheme\":2,\"customBg\":-725800}"}}"#.utf8).write(to: f)
        let p = Prefs(file: f)
        XCTAssertTrue(p.bool("night"))
        XCTAssertEqual(p.int("pageMode"), 1)
        XCTAssertEqual(p.double("ttsRate"), 1.25)
        let st = try XCTUnwrap(ReadStyle.from(json: p.string("style")))
        XCTAssertEqual(st.fontSize, 24); XCTAssertEqual(st.dayTheme, 2); XCTAssertEqual(st.customBg, -725800)
        XCTAssertEqual(st.lineSpacing, 1.6)
        p.set("x", "y")
        XCTAssertEqual(Prefs(file: f).string("x"), "y")
        Groups.save(p, ["連載中", "已讀完"])
        XCTAssertEqual(Groups.all(Prefs(file: f)), ["連載中", "已讀完"])
    }

    func testBackupRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        let b = try store.importTxt(data: Data("第一章 甲\n\(String(repeating: "內容", count: 300))\n第二章 乙\n\(String(repeating: "文字", count: 300))".utf8), fileName: "書.txt")
        store.saveBookmarks(b.id, [Bookmark(chapter: 1, offset: 3, excerpt: "x", note: "n", time: 1)])
        Prefs(file: root.appendingPathComponent("prefs.json")).set("night", true)
        let zip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Backup.export(root: root, to: zip, bookCount: 1)

        let root2 = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root2, withIntermediateDirectories: true)
        XCTAssertEqual(try Backup.restore(from: zip, root: root2), 1)
        let s2 = LibraryStore(root: root2)
        XCTAssertEqual(s2.books.first?.id, b.id)
        XCTAssertEqual(s2.bookmarks(b.id).first?.n, "n")
        XCTAssertTrue(s2.readChapter(b.id, 1).hasPrefix("文字"))
        XCTAssertTrue(Prefs(file: root2.appendingPathComponent("prefs.json")).bool("night"))
        // 不是備份檔要拒絕
        XCTAssertThrowsError(try Backup.restore(from: root.appendingPathComponent("books.json"), root: root2))
    }
}
