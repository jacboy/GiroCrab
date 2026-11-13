import XCTest
@testable import GiroCrabUI

final class HelpViewTests: XCTestCase {
    func testAllTopicsHaveGermanAndEnglishText() {
        XCTAssertGreaterThanOrEqual(HelpCatalog.topics.count, 6)
        for t in HelpCatalog.topics {
            for lang in ["de", "en"] {
                XCTAssertFalse(t.title(lang).isEmpty, "\(t.id) \(lang) title")
                XCTAssertFalse(t.body(lang).isEmpty, "\(t.id) \(lang) body")
            }
        }
        XCTAssertEqual(Set(HelpCatalog.topics.map(\.id)).count, HelpCatalog.topics.count, "IDs unique")
    }

    func testEmptyQueryKeepsAllTopics() {
        XCTAssertEqual(HelpCatalog.filter(HelpCatalog.topics, query: "  ", language: "de").count,
                       HelpCatalog.topics.count)
    }

    func testSearchFindsTopicsByContent() {
        let ids = { (q: String, l: String) in HelpCatalog.filter(HelpCatalog.topics, query: q, language: l).map(\.id) }
        XCTAssertEqual(ids("C24", "de"), ["enable-banking"])
        XCTAssertTrue(ids("pem", "en").contains("enable-banking"))
        XCTAssertTrue(ids("startsaldo", "de").contains("start"))
        XCTAssertTrue(ids("ICLOUD", "en").contains("vault"))
        XCTAssertTrue(ids("amount", "en").contains("categories"))
    }

    func testSearchRequiresAllTermsAndIgnoresDiacritics() {
        let f = { (q: String) in HelpCatalog.filter(HelpCatalog.topics, query: q, language: "de").map(\.id) }
        XCTAssertTrue(f("verschlusselte tresor").contains("vault"))   // ü folds to u
        XCTAssertTrue(f("verschlüsselte TRESOR").contains("vault"))
        XCTAssertTrue(f("Datenschutz").contains("vault"))
        XCTAssertTrue(f("Tresor xyzunbekannt").isEmpty)
    }

    func testShortcutsAndLinks() {
        XCTAssertTrue(HelpCatalog.shortcuts.contains { $0.keys == "⌘R" })
        XCTAssertTrue(HelpCatalog.shortcuts.contains { $0.keys == "⌃⌘L" })
        XCTAssertEqual(HelpLinks.website.absoluteString, "https://girocrab.de")
        XCTAssertEqual(HelpLinks.issues.absoluteString, "https://github.com/GiroCrab/GiroCrab/issues")
        XCTAssertEqual(HelpLinks.discussions.absoluteString, "https://github.com/GiroCrab/GiroCrab/discussions")
    }
}
