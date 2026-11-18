import XCTest
@testable import IOSLocalLLM

final class CodeBlockFileTests: XCTestCase {
    func testPreviewIsOfferedOnlyForHTML() {
        XCTAssertTrue(CodeBlockFile.isHTML(language: "html", code: "<p>hi</p>"))
        XCTAssertTrue(CodeBlockFile.isHTML(language: "HTML title=index.html", code: ""))
        XCTAssertTrue(CodeBlockFile.isHTML(language: "", code: "\n<!DOCTYPE html>\n<html></html>"))
        XCTAssertFalse(CodeBlockFile.isHTML(language: "swift", code: "let page = \"<html>\""))
        XCTAssertFalse(CodeBlockFile.isHTML(language: "", code: "let x = 1"))
    }

    func testSavedFileNameFollowsTheFenceTag() {
        XCTAssertEqual(CodeBlockFile.filename(language: "python", code: ""), "code.py")
        XCTAssertEqual(CodeBlockFile.filename(language: "Swift", code: ""), "code.swift")
        XCTAssertEqual(CodeBlockFile.filename(language: "", code: "<html></html>"), "code.html")
        XCTAssertEqual(CodeBlockFile.filename(language: "", code: "plain"), "code.txt")
        // A model-written tag must never steer the path.
        XCTAssertEqual(CodeBlockFile.filename(language: "../../etc/passwd", code: ""), "code.txt")
    }
}
