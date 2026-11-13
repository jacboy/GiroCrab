import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Print dialog (GitHub #53, part 2)

/// Options on the left, the bookings to print (with checkboxes) on the right.
/// "Drucken …" hands the HTML report to the system print panel, which also
/// offers "Als PDF sichern".
struct PrintSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = PrintOptions.load()
    @State private var report: PrintReport?
    @State private var selected: Set<Int64> = []
    #if os(macOS)
    /// Paper of the page setup, shown in the dialog and refreshed after „Papierformat …“.
    @State private var paper = HTMLPrinter.currentPaper
    #endif

    private var visibleRows: [PrintRow] {
        PrintReportBuilder.rows(report?.rows ?? [], options: options)
    }

    private var selectedRows: [PrintRow] {
        visibleRows.filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Drucken")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Drucken …") { print() }
                            .disabled(selectedRows.isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 880, idealWidth: 960, minHeight: 520, idealHeight: 640)
        #endif
        .onAppear {
            report = model.printSource()
            selected = Set(report?.rows.map(\.id) ?? [])
        }
        .onChange(of: options) { _, o in o.save() }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            optionsForm.frame(width: 360)
            Divider()
            bookingList
        }
        #else
        Form {
            optionSections
            Section {
                selectionHeader
                ForEach(visibleRows) { row($0) }
            } header: {
                Text("Buchungen")
            }
        }
        #endif
    }

    // MARK: Options

    private var optionsForm: some View {
        Form { optionSections }
            .formStyle(.grouped)
    }

    @ViewBuilder
    private var optionSections: some View {
        #if os(macOS)
        // Paper and orientation are part of the layout (pages are broken before the
        // print panel opens), so they are chosen here – not again in the panel.
        Section("Papier") {
            LabeledContent("Format", value: paper.label)
            Button("Papierformat …") { PageSetup.run { paper = HTMLPrinter.currentPaper } }
        }
        #endif
        Section("Auswahl") {
            Picker("Buchungen", selection: $options.direction) {
                ForEach(PrintDirection.allCases) { Text($0.title).tag($0) }
            }
            Picker("Reihenfolge", selection: $options.newestFirst) {
                Text("Neueste zuerst").tag(true)
                Text("Älteste zuerst").tag(false)
            }
            LabeledContent("Zeitraum", value: model.periodTitle)
        }
        Section {
            Toggle("Kategorie", isOn: $options.showCategory)
            Toggle("Notizen", isOn: $options.showNote)
            Toggle("Nur erste Zeile des Verwendungszwecks", isOn: $options.firstLineOnly)
            Toggle("Summe der Ein- und Ausgänge", isOn: $options.showTotals)
            Toggle("Nach Konto gruppieren", isOn: $options.groupByAccount)
            Toggle("Aktueller Kontostand", isOn: $options.showCurrentBalance)
            Toggle("Tagessaldo", isOn: $options.showDailyBalance)
            if PrintLogoImage.available {
                Picker("GiroCrab-Logo", selection: $options.logo) {
                    ForEach(PrintLogo.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Inhalt")
        } footer: {
            if options.showDailyBalance {
                Text("Der Tagessaldo ist der Kontostand am Ende des Tages, unabhängig von der Auswahl.")
                    .leadingFooter()
            }
        }
    }

    // MARK: Bookings

    private var bookingList: some View {
        VStack(spacing: 0) {
            selectionHeader
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if visibleRows.isEmpty {
                ContentUnavailableView("Keine Buchungen", systemImage: "doc.text",
                                       description: Text("Im gewählten Zeitraum und Filter gibt es nichts zu drucken."))
            } else {
                List(visibleRows) { row($0) }
                    .listStyle(.inset)
            }
        }
    }

    private var selectionHeader: some View {
        let totals = PrintReportBuilder.totals(selectedRows)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedRows.count) von \(visibleRows.count) ausgewählt")
                    .font(.headline)
                Text("Einnahmen \(Money.format(totals.incomeCents)) · Ausgaben \(Money.format(totals.expenseCents))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Alle auswählen") { selected.formUnion(visibleRows.map(\.id)) }
                .disabled(selectedRows.count == visibleRows.count)
            Button("Auswahl aufheben") { selected.subtract(visibleRows.map(\.id)) }
                .disabled(selectedRows.isEmpty)
        }
    }

    private func row(_ r: PrintRow) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(r.id) },
            set: { on in if on { selected.insert(r.id) } else { selected.remove(r.id) } }
        )) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.counterparty).lineLimit(1)
                    Text("\(DateText.medium(r.date)) · \(r.accountName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Money.format(r.amountCents, currency: r.currency))
                    .monospacedDigit()
                    .foregroundStyle(r.amountCents > 0 ? Theme.inflow : .primary)
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }

    // MARK: Output

    private func print() {
        guard var r = report else { return }
        r.rows = selectedRows
        r.generatedAt = Date()
        r.logoDataURI = options.logo == .off ? nil : PrintLogoImage.dataURI
        if options.showDailyBalance, let earliest = r.rows.map(\.date).min() {
            let ids = Array(Set(r.rows.map(\.accountId))).sorted()
            r.dailyBalances = model.printDailyBalances(accountIds: ids, from: earliest)
        }
        let jobName = "GiroCrab – \(r.title) – \(r.periodLabel)"
        #if os(macOS)
        let paper = HTMLPrinter.currentPaper
        let html = PrintReportBuilder.html(r, options: options, paper: paper)
        // The print panel opens as a sheet on the main window; close ours first.
        dismiss()
        DispatchQueue.main.async { HTMLPrinter.shared.print(html: html, jobName: jobName, paper: paper) }
        #else
        let html = PrintReportBuilder.html(r, options: options)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true)
        #endif
    }
}

/// The app icon as an embeddable PNG for the printout (macOS only for now:
/// iOS cannot read its own app icon at runtime).
enum PrintLogoImage {
    #if os(macOS)
    static var available: Bool { true }
    @MainActor static let dataURI: String? = {
        let icon = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        guard let icon else { return nil }
        let side = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()
    #else
    static var available: Bool { false }
    static let dataURI: String? = nil
    #endif
}

#if os(macOS)
/// File ▸ Papierformat … (⇧⌘P): the paper the printout is laid out for.
@MainActor
enum PageSetup {
    static func run(_ done: @escaping () -> Void = {}) {
        let layout = NSPageLayout()
        let info = NSPrintInfo.shared
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            layout.beginSheet(using: info, on: window) { _ in done() }
        } else {
            layout.runModal(with: info)
            done()
        }
    }
}

/// Loads the report into an off-screen WKWebView and runs the system print panel.
@MainActor
final class HTMLPrinter: NSObject, WKNavigationDelegate {
    static let shared = HTMLPrinter()
    private var webView: WKWebView?
    private var jobName = ""
    private var paperSize = NSSize(width: 595, height: 842)

    /// Paper of the user's page setup in its orientation (landscape = wider than
    /// high), used to lay out the report pages.
    static var currentPaper: PrintReportBuilder.Paper {
        let size = NSPrintInfo.shared.paperSize
        let short = min(size.width, size.height) * 25.4 / 72, long = max(size.width, size.height) * 25.4 / 72
        guard short > 50 && long > 50 else { return .a4 }
        return NSPrintInfo.shared.orientation == .landscape
            ? .init(widthMM: long, heightMM: short)
            : .init(widthMM: short, heightMM: long)
    }

    func print(html: String, jobName: String, paper: PrintReportBuilder.Paper) {
        self.jobName = jobName
        self.paperSize = NSSize(width: paper.widthMM * 72 / 25.4, height: paper.heightMM * 72 / 25.4)
        // One page wide in CSS pixels (96 per inch), so the laid-out pages are not reflowed.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: paper.widthMM * 96 / 25.4, height: paper.heightMM * 96 / 25.4))
        web.navigationDelegate = self
        webView = web
        web.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { runPrint(webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { self.webView = nil }
    }

    private func runPrint(_ web: WKWebView) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = paperSize
        info.orientation = paperSize.width > paperSize.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0 // CSS @page margins
        let op = web.printOperation(with: info)
        op.jobTitle = jobName
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        // Pages are laid out for the Page Setup paper and orientation, so both are
        // chosen in the print dialog / "Papierformat …", not again in the print panel.
        op.printPanel.options.formUnion([.showsScaling, .showsPreview])
        op.printPanel.options.subtract([.showsPaperSize, .showsOrientation])
        // WKWebView's print view needs a frame, or the output is blank.
        op.view?.frame = web.bounds
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            op.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            op.run()
            webView = nil
        }
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        webView = nil
    }
}
#endif
