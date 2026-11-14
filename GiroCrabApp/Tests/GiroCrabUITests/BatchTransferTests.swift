import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Sammelüberweisung (#240): CSV import into the draft, row validation, undo.
@MainActor
final class BatchTransferTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func csvFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString).csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDemoAccountOffersBatchTransfer() {
        XCTAssertFalse(model.batchAccounts.isEmpty)
    }

    func testCSVImportReplacesBlankRowAndFlagsFaultyRows() throws {
        let url = try csvFile("""
        Name;IBAN;Betrag;Verwendungszweck
        Anna Becker;DE89 3704 0044 0532 0130 00;60,00;Beitrag
        Ben Koch;DE89370400440532013001;30,00;falsche Prüfsumme
        """)
        model.importBatchCSV(url)
        XCTAssertNil(model.transferError)
        XCTAssertEqual(model.batchDraft.rows.count, 2)
        XCTAssertTrue(model.batchDraft.rows[0].isValid)
        XCTAssertEqual(model.batchDraft.rows[0].cents, 6_000)
        XCTAssertFalse(model.batchDraft.rows[1].isValid)
        XCTAssertNotNil(model.batchDraft.importNote)
    }

    func testCSVWithoutIBANColumnReportsProblemAndKeepsRows() throws {
        model.importBatchCSV(try csvFile("Name;Betrag\nA;1,00\n"))
        XCTAssertNotNil(model.transferError)
        XCTAssertEqual(model.batchDraft.rows.count, 1) // the empty starting row
    }

    func testRemovedRowsComeBackWithUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.batchDraft.rows = BatchRow.samples(5)
        let ids = Set(model.batchDraft.rows[1...2].map(\.id))
        let names = model.batchDraft.rows.map(\.name)
        undo.beginUndoGrouping()
        model.batchDraft.remove(ids, undo: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(model.batchDraft.rows.count, 3)
        undo.undo()
        XCTAssertEqual(model.batchDraft.rows.map(\.name), names)
    }

    func testSampleRowsHaveTheTwoPlantedErrors() {
        let rows = BatchRow.samples(50)
        XCTAssertEqual(rows.filter { !$0.isValid }.count, 2)
    }
}
