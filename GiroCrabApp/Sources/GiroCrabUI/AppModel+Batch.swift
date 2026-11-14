import Foundation
import SwiftUI
import GiroCrabCore

// MARK: - Sammelüberweisung (#240)

extension AppModel {
    /// FinTS accounts a batch transfer can be sent from (HKCCM; not bunq).
    var batchAccounts: [Account] {
        transferAccounts.filter { $0.connector != .bunq && bankingGate(forAccount: $0.id) == nil }
    }

    var canBatchTransfer: Bool { canTransfer && !batchAccounts.isEmpty }

    func openBatchTransfer() {
        guard canBatchTransfer else { return }
        let offered = batchAccounts
        if batchDraft.accountID == nil || !offered.contains(where: { $0.id == batchDraft.accountID }) {
            var selected: Int64?
            if case .account(let id) = sidebarSelection, offered.contains(where: { $0.id == id }) { selected = id }
            batchDraft.accountID = selected ?? offered.first?.id
        }
        transferError = nil
        showBatchSheet = true
    }

    /// Segmented control of the batch sheet: back to the single transfer form.
    func switchToSingleTransfer() {
        showBatchSheet = false
        transferError = nil
        Task { @MainActor in openTransfer() }
    }

    /// Segmented control of the single form: on to the batch sheet.
    func switchToBatchTransfer() {
        showTransferSheet = false
        Task { @MainActor in openBatchTransfer() }
    }

    func cancelBatchSheet() {
        showBatchSheet = false
        batchDraft.pin = ""
        transferError = nil
    }

    /// Replaces empty rows with the file's rows, else appends.
    func importBatchCSV(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            transferError = String(localized: "Die Datei konnte nicht gelesen werden.")
            return
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        let result = parseBatchCsv(text: text)
        if let problem = result.problems.first {
            transferError = problem
            return
        }
        transferError = nil
        let imported = result.rows.map(BatchRow.init(csv:))
        let blank = { (r: BatchRow) in r.name.isEmpty && r.iban.isEmpty && r.amountText.isEmpty && r.purpose.isEmpty }
        batchDraft.rows.removeAll(where: blank)
        batchDraft.rows.append(contentsOf: imported)
        let faulty = imported.filter { !$0.isValid }.count
        batchDraft.importNote = faulty == 0
            ? String(localized: "\(imported.count) Zahlungen aus „\(url.lastPathComponent)“ übernommen")
            : String(localized: "\(imported.count) Zahlungen aus „\(url.lastPathComponent)“ übernommen, \(faulty) fehlerhaft")
    }

    func startBatch() {
        withFreshBankingPolicy { [self] in
            if let gate = bankingGate(forAccount: batchDraft.accountID) {
                transferError = gate.message
                return
            }
            startBatchChecked()
        }
    }

    private func startBatchChecked() {
        guard let vault, let accID = batchDraft.accountID, canSendTransfer(from: accID),
              let account = allAccounts.first(where: { $0.id == accID }),
              let connection = connections.first(where: { $0.id == account.connectionId }) else { return }
        let stored = connectionStatus(connection.id)?.hasPin ?? false
        if !isDemo && !stored && batchDraft.pin.isEmpty {
            transferError = String(localized: "Bitte die Banking-PIN eingeben.")
            return
        }
        do {
            let payments = try batchDraft.rows.map { r -> BatchPaymentInput in
                let bic = r.bic.trimmingCharacters(in: .whitespaces)
                return BatchPaymentInput(
                    name: r.name, iban: r.iban, bic: bic.isEmpty ? nil : bic,
                    amountCents: try parseAmountToCents(text: r.amountText), purpose: r.purpose)
            }
            let request = BatchTransferRequest(
                accountId: accID, payments: payments, batchBooking: !batchDraft.singleBookings,
                executionDate: batchDraft.executionDateISO)
            let session = try vault.beginBatchTransfer(request: request, secret: isDemo ? "demo" : batchDraft.pin, demo: isDemo)
            transferError = nil
            transferBusy = true
            showBatchSheet = false
            activeTransferIsBatch = true
            activeTransfer = session
            Task {
                do {
                    self.handleTransfer(try await session.start(), connection: connection)
                } catch {
                    self.finishTransfer(error: error)
                }
            }
        } catch {
            transferError = describe(error)
        }
    }
}
