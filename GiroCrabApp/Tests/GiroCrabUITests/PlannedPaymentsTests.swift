import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// „Geplant“ (#240): the page loads through the core and reacts to its filters.
@MainActor
final class PlannedPaymentsTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    /// The demo vault has four scheduled transfers on its Giro account.
    func testDemoVaultLoadsScheduledTransfers() async throws {
        model.sidebarSelection = .planned
        model.plannedHorizon = .all
        await model.reloadPlanned()
        XCTAssertEqual(model.plannedPayments.count, 4)
        XCTAssertEqual(model.plannedTotals.count, 4)
        XCTAssertEqual(model.plannedTotals.outgoingCents, -(85_000 + 8_500 + 62_000 + 15_000))
        XCTAssertEqual(model.plannedTotals.incomingCents, 0)
        XCTAssertEqual(model.plannedPayments.map(\.date), model.plannedPayments.map(\.date).sorted())
        XCTAssertEqual(model.title, String(localized: "Geplant"))
    }

    func testAccountFilterAndHorizon() async throws {
        model.plannedHorizon = .all
        let other = try XCTUnwrap(model.allAccounts.first { a in
            !model.plannedPayments.contains { $0.accountId == a.id } && a.name != "Musterbank Girokonto"
        })
        model.plannedAccountFilter = other.id
        await model.reloadPlanned()
        XCTAssertTrue(model.plannedPayments.isEmpty)

        model.plannedAccountFilter = nil
        model.plannedHorizon = .days30 // the transfers in 41 days fall out
        await model.reloadPlanned()
        XCTAssertEqual(model.plannedPayments.count, 3)
    }

    func testHorizonEndDates() {
        XCTAssertNil(PlannedHorizon.all.endISO)
        let end = PlannedHorizon.days30.endISO
        XCTAssertEqual(end?.count, 10)
        XCTAssertGreaterThan(end ?? "", DateText.iso(Date()))
    }
}
