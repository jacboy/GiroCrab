import SwiftUI
import Charts
import GiroCrabCore

/// Securities positions of a depot account (from the last sync).
struct HoldingsCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var holdings: [Holding] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !holdings.isEmpty {
                Text("Positionen").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
            ForEach(holdings.indices, id: \.self) { i in
                let h = holdings[i]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.name.isEmpty ? (h.isin.isEmpty ? h.wkn : h.isin) : h.name).lineLimit(1)
                        Text("\(h.quantity.formatted(.number.precision(.fractionLength(0...4)))) × \(Money.format(h.currentPriceCents)) · \(h.isin.isEmpty ? h.wkn : h.isin)")
                            .font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Money.format(h.valueCents)).monospacedDigit()
                }
                .font(.callout)
                .contextMenu {
                    Button("Position kopieren", systemImage: "doc.on.doc") { copyToPasteboard(Self.line(h)) }
                    Button("Alle Positionen kopieren", systemImage: "doc.on.doc.fill") {
                        copyToPasteboard(holdings.map(Self.line).joined(separator: "\n"))
                    }
                }
            }
        }
        .task(id: "\(account.id)-\(account.balanceCents)-\(account.balanceDate)") {
            holdings = model.holdings(for: account.id)
        }
    }
}

extension HoldingsCard {
    /// One position as plain text: name, ISIN/WKN, quantity, price, value.
    static func line(_ h: Holding) -> String {
        let id = h.isin.isEmpty ? h.wkn : h.isin
        let qty = h.quantity.formatted(.number.precision(.fractionLength(0...4)))
        return [h.name, id, "\(qty) × \(Money.format(h.currentPriceCents))", Money.format(h.valueCents)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Right-click / long-press menu on the header's account info: copies bank details,
/// IBAN or balance as plain text.
struct AccountCopyMenu: View {
    let account: Account

    var body: some View {
        // From the Bundesbank BLZ list (German IBANs only); looked up once per menu.
        let bic = bicForIban(iban: account.iban)
        Section("In Zwischenablage kopieren") {
            if !account.iban.isEmpty {
                Button("Bankverbindung") { copyToPasteboard(bankDetails(bic: bic)) }
                Button("IBAN") { copyToPasteboard(account.iban) }
            }
            if let bic {
                Button("BIC") { copyToPasteboard(bic) }
            }
            Button("Kontostand") { copyToPasteboard(Money.clipboard(account.balanceCents)) }
        }
    }

    func bankDetails(bic: String?) -> String {
        let bank: String
        switch (bic, account.bankName.isEmpty) {
        case (let b?, false): bank = "BIC: \(b) (\(account.bankName))"
        case (let b?, true): bank = "BIC: \(b)"
        case (nil, false): bank = "Bank: \(account.bankName)"
        case (nil, true): bank = ""
        }
        return [
            account.owner.isEmpty ? "" : "Name: \(account.owner)",
            "IBAN: \(formatIBAN(account.iban))",
            bank,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Header card of the stream: title, balance, calm balance chart and the
/// monthly KPIs (consumption is always shown without ETF plans / perks).
struct StreamHeaderCard: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showDocuments = false
    @AppStorage(ViewLayout.statisticsKey) private var showStatistics: Bool = true

    private var account: Account? {
        if case .account(let id) = model.sidebarSelection { return model.account(for: id) }
        return nil
    }

    /// Depots show positions; bookings (buys, sells) live on the clearing account.
    private var isDepot: Bool {
        guard let a = account else { return false }
        return a.kind == .brokerage || a.name.localizedCaseInsensitiveContains("depot")
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Group {
                        if let a = account {
                            Text([a.bankName, a.iban.isEmpty ? "" : formatIBAN(a.iban)].filter { !$0.isEmpty }.joined(separator: " · "))
                        } else {
                            Text(model.lastSyncText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                }
                .contextMenu {
                    if let a = account { AccountCopyMenu(account: a) }
                }
                #if os(iOS)
                // long-press is invisible on iPhone/iPad: show an explicit entry too
                if let a = account {
                    Menu { AccountCopyMenu(account: a) } label: {
                        Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .accessibilityLabel("In Zwischenablage kopieren")
                }
                #endif
                Spacer()
                if let hb = model.headerBalance {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.format(hb.cents))
                            .font(.largeTitle.weight(.semibold).monospacedDigit())
                            .foregroundStyle(account?.kind == .loan ? Theme.loan : Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(hb.label).font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .contextMenu {
                        Button("\(hb.label) kopieren", systemImage: "doc.on.doc") { copyToPasteboard(Money.clipboard(hb.cents)) }
                    }
                }
            }

            if let a = account, a.kind == .loan {
                LoanProgressCard(account: a, compact: true)
            }

            if let a = account, isDepot {
                HoldingsCard(account: a)
            }

            if isDepot {
                depotRow
            } else {
                if showStatistics && model.scope != .investments {
                    // iOS: 44 pt = HIG minimum hit region (the chart is tappable);
                    // macOS: room for the min/max/0 axis labels (GitHub #203).
                    #if os(iOS)
                    BalanceChart(points: model.history) { model.jumpToDay($0) }
                        .frame(height: 44)
                    #else
                    BalanceChart(points: model.history) { model.jumpToDay($0) }
                        .frame(height: 72)
                    #endif
                }

                #if os(iOS)
                HStack(spacing: 10) {
                    Text("Konsum \(kpiValue(-model.consumptionThisMonth))").foregroundStyle(Theme.outflow)
                    Text("Einnahmen \(kpiValue(model.incomeThisMonth))").foregroundStyle(Theme.inflow)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                #else
                HStack(spacing: 10) { kpis }
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                #endif

                filterRow
            }
        }
        .card()
    }

    /// Depot: no cash-flow KPIs, chart or period filters – only documents and a hint.
    @ViewBuilder
    private var depotRow: some View {
        HStack(spacing: 12) {
            if let a = account {
                Button { showDocuments = true } label: {
                    Label("Dokumente", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .sheet(isPresented: $showDocuments) { AccountDocumentsSheet(account: a) }
            }
            Spacer()
            Text("Depot: Positionen statt Buchungen")
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
    }

    /// The tiles belong to the selection: no stale sums while it loads.
    private func kpiValue(_ cents: Int64) -> String {
        model.isLoadingSelection ? "–" : Money.format(cents)
    }

    @ViewBuilder
    private var kpis: some View {
        KPI(title: "Konsumausgaben", subtitle: LocalizedStringKey(model.periodSubtitle), value: kpiValue(-model.consumptionThisMonth), tint: Theme.outflow)
        KPI(title: "Investiert", subtitle: "Sparpläne & Perks", value: kpiValue(model.investedThisMonth), tint: Theme.invest)
        KPI(title: "Einnahmen", subtitle: LocalizedStringKey(model.periodSubtitle), value: kpiValue(model.incomeThisMonth), tint: Theme.inflow)
        fixedCostsKPI
    }

    /// Recurring expenses still due this month (GitHub #35); opens the overview.
    @ViewBuilder
    private var fixedCostsKPI: some View {
        let open = model.recurringMonth?.items.filter { !$0.booked && $0.amountCents < 0 }.count ?? 0
        Button { model.showRecurringSheet = true } label: {
            KPI(title: "Fixkosten offen", subtitle: "Diesen Monat · \(open) offen",
                value: Money.format(-(model.recurringMonth?.openExpenseCents ?? 0)), tint: Theme.outflow,
                disclosure: true)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Wiederkehrende Buchungen anzeigen")
        .accessibilityHint("Öffnet die Übersicht der wiederkehrenden Buchungen")
    }

    @ViewBuilder
    private var filterRow: some View {
        @Bindable var model = model
        // Never let the fixed-size filter controls widen the header card:
        // fits -> normal row (count right-aligned); too narrow -> scrolls.
        ViewThatFits(in: .horizontal) {
            filterContent
            ScrollView(.horizontal, showsIndicators: false) {
                filterContent.fixedSize(horizontal: true, vertical: false)
            }
        }
        // Outside ViewThatFits: its candidates must not each carry the popover.
        .popover(isPresented: $model.showCustomPeriod, arrowEdge: .bottom) {
            CustomPeriodForm()
        }
    }

    @ViewBuilder
    private var filterContent: some View {
        @Bindable var model = model
        let account = self.account
        HStack(spacing: 12) {
                Menu {
                    Picker("Zeitraum", selection: $model.interactivePeriod) {
                        ForEach(Period.presets) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    // A Toggle gives the native menu checkmark while the custom range is active;
                    // choosing it always opens the date dialog.
                    Toggle(isOn: Binding(get: { model.period == .custom }, set: { _ in model.showCustomPeriod = true })) {
                        if model.period == .custom {
                            Text("Benutzerdefiniert: \(model.periodTitle) …")
                        } else {
                            Text("Benutzerdefiniert …")
                        }
                    }
                } label: {
                    // Single period control (GitHub #102): the menu is the only selector,
                    // so it always shows the active range.
                    Label(model.periodTitle, systemImage: "calendar")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // One filter menu (status + income/expenses) keeps the row narrow.
                Menu {
                    // Inline pickers show no title in a menu: name each group with a section header.
                    Section("Status") {
                        Picker("Status", selection: $model.statusFilter) {
                            ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("Buchungsart") {
                        Picker("Buchungsart", selection: $model.directionFilter) {
                            ForEach(BookingDirection.ordered) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } label: {
                    #if os(iOS)
                    if sizeClass == .compact {
                        // icon only: the period menu label takes most of the width
                        Image(systemName: model.filterSymbol)
                            .accessibilityLabel(model.filterTitle)
                    } else {
                        Label(model.filterTitle, systemImage: model.filterSymbol)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                    #else
                    Label(model.filterTitle, systemImage: model.filterSymbol)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    #endif
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Nach Status oder nach Einnahmen und Ausgaben filtern")
                if let a = account {
                    Button { showDocuments = true } label: {
                        Label("Dokumente", systemImage: "doc.text")
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            #if os(iOS)
                            .labelStyle(.iconOnly)
                            #endif
                    }
                    .buttonStyle(.borderless)
                    .sheet(isPresented: $showDocuments) { AccountDocumentsSheet(account: a) }
                }
                Spacer()
                #if os(iOS)
                if sizeClass != .compact {
                    Text("\(model.bookingCountLabel) Buchungen")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                #else
                Text("\(model.bookingCountLabel) Buchungen")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                #endif
            }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
    }
}

struct KPI: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let value: String
    let tint: Color
    /// Tile opens a detail view: shows a chevron next to the title.
    var disclosure = false

    var body: some View {
        // Title and amount sit at a fixed distance and the title keeps to one line, so the
        // amounts of all tiles line up (HIG: align elements, consistent spacing).
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold)).imageScale(.small)
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            Text(subtitle).font(.caption2).foregroundStyle(Theme.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct BalanceChart: View {
    @Environment(AppModel.self) private var model
    let points: [DailyBalance]
    /// Click on a day (jump to its bookings).
    var onSelect: ((Date) -> Void)? = nil
    /// Day under the mouse pointer (hover readout: date + balance).
    @State private var hovered: Point?
    /// Bar under the mouse pointer (bar style: month/day + average balance).
    @State private var hoveredBar: BalanceBucket?
    @AppStorage(BalanceChartStyle.defaultsKey) private var style: BalanceChartStyle = .line
    @AppStorage(BalanceBarUnit.defaultsKey) private var barUnit: BalanceBarUnit = .automatic

    /// Width of the chart: the x-axis spaces its labels by it (no overlapping years).
    @State private var chartWidth: CGFloat = 600

    private struct Point: Identifiable, Equatable {
        let id: Int
        let date: Date
        let cents: Int64
        var euros: Double { Double(cents) / 100 } // display only; data stays in cents
    }

    /// The chart's first render compiles Metal shaders (gradient + mask, ~1 s on a cold start),
    /// so it is mounted one run-loop tick + a short delay after the list and cards are shown.
    /// Only the first time: a chart rebuilt later (e.g. depot -> giro) shows at once.
    @State private var mounted = BalanceChart.shadersWarm
    @MainActor private static var shadersWarm = false

    var body: some View {
        Group {
            if mounted { chartBody } else { Color.clear }
        }
        .task {
            guard !mounted else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            StartupClock.mark("BalanceChart mounting")
            mounted = true
            Self.shadersWarm = true
        }
    }

    private var pts: [Point] {
        points.enumerated().compactMap { i, p in
            DateText.date(p.date).map { Point(id: i, date: $0, cents: p.balanceCents) }
        }
    }

    private var buckets: [BalanceBucket] { BalanceBuckets.make(points, unit: barUnit) }

    private var resolvedBarUnit: BalanceBarUnit { barUnit.resolved(dayCount: points.count) }

    /// Keyboard: ←/→ walk the days (bars: the months), the hover readout follows; Return jumps
    /// to the bookings, Esc ends. VoiceOver: summary, adjustable by day / bar.
    @FocusState private var chartFocused: Bool

    private func step(_ delta: Int) {
        if style == .bars {
            let all = buckets
            guard !all.isEmpty else { return }
            let current = hoveredBar.map(\.id) ?? (delta > 0 ? -1 : all.count)
            hoveredBar = all[min(max(current + delta, 0), all.count - 1)]
            return
        }
        let all = pts
        guard !all.isEmpty else { return }
        let current = hovered.flatMap { h in all.firstIndex { $0.id == h.id } } ?? (delta > 0 ? -1 : all.count)
        hovered = all[min(max(current + delta, 0), all.count - 1)]
    }

    private var summary: String {
        let all = pts
        guard let first = all.first, let last = all.last,
              let low = all.min(by: { $0.cents < $1.cents }), let high = all.max(by: { $0.cents < $1.cents }) else {
            return String(localized: "Keine Daten")
        }
        let d = Date.FormatStyle.dateTime.day().month(.wide)
        return String(localized: "Von \(Money.format(first.cents)) am \(first.date.formatted(d)) auf \(Money.format(last.cents)) am \(last.date.formatted(d)). Tiefststand \(Money.format(low.cents)) am \(low.date.formatted(d)), Höchststand \(Money.format(high.cents)) am \(high.date.formatted(d)).")
    }

    private var currentValue: String {
        if style == .bars, let b = hoveredBar {
            return String(localized: "\(barTitle(b)): Ø \(Money.format(b.averageCents)), Ende \(Money.format(b.closingCents))")
        }
        guard let h = hovered else { return summary }
        return "\(h.date.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(Money.format(h.cents))"
    }

    private func barTitle(_ b: BalanceBucket) -> String {
        switch resolvedBarUnit {
        case .year: b.start.formatted(.dateTime.year())
        case .month: b.start.formatted(.dateTime.month(.wide).year())
        case .day, .automatic: b.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
    }

    /// Long histories label years, otherwise months; the year separators mark each January 1st.
    private func spanDays(_ first: Date?, _ last: Date?) -> Double {
        guard let first, let last else { return 0 }
        return last.timeIntervalSince(first) / 86_400
    }

    private func clearHover() { hovered = nil; hoveredBar = nil }

    /// Jumps to the bookings of the hovered day / bar; false if nothing is hovered.
    @discardableResult private func selectHovered() -> Bool {
        guard let onSelect else { return false }
        switch style {
        case .bars:
            guard let b = hoveredBar else { return false }
            onSelect(b.last)
        case .line:
            guard let h = hovered else { return false }
            onSelect(h.date)
        }
        return true
    }

    @ViewBuilder private var chartBody: some View {
        interactiveChart
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saldoverlauf")
            .accessibilityValue(currentValue)
            .accessibilityHint(onSelect == nil ? "" : String(localized: "Pfeiltasten wählen einen Tag, Eingabe zeigt seine Buchungen."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Buchungen dieses Tages zeigen") { selectHovered() }
            .accessibilityChartDescriptor(BalanceChartDescriptor(points: pts.map { ($0.date, $0.euros) }))
    }

    @ViewBuilder private var interactiveChart: some View {
        Group {
            switch style {
            case .line: lineChart
            case .bars: barChart
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
        .onChange(of: points.first?.date) { _, _ in clearHover() }
        .onChange(of: points.count) { _, _ in clearHover() }
        .onChange(of: style) { _, _ in clearHover() }
        .onChange(of: barUnit) { _, _ in hoveredBar = nil }
        .contextMenu { styleMenu }
        #if os(macOS)
        .focusable(interactions: .edit)
        .focused($chartFocused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.return) { selectHovered() ? .handled : .ignored }
        .onKeyPress(.escape) {
            guard hovered != nil || hoveredBar != nil else { return .ignored }
            clearHover()
            return .handled
        }
        .onChange(of: chartFocused) { _, focused in
            if !focused { clearHover() }
            model.chartHasKeyboardFocus = focused
        }
        #endif
    }

    /// Right click (long press on iOS): switch between line and bars right at the chart.
    @ViewBuilder private var styleMenu: some View {
        Picker("Darstellung", selection: $style) {
            ForEach(BalanceChartStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        if style == .bars {
            Picker("Balken je", selection: $barUnit) {
                ForEach(BalanceBarUnit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    // MARK: line

    @ViewBuilder private var lineChart: some View {
        let pts = self.pts
        let minV = pts.map(\.euros).min() ?? 0
        let maxV = pts.map(\.euros).max() ?? 1
        let pad = max((maxV - minV) * 0.15, 1)
        let years = pts.first.flatMap { f in pts.last.map { BalanceBuckets.yearStarts(from: f.date, to: $0.date) } } ?? []
        Chart {
            ForEach(years, id: \.self) { y in
                RuleMark(x: .value("Jahr", y))
                    .foregroundStyle(Theme.tertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(pts) { p in
                AreaMark(x: .value("Tag", p.date, unit: .day), yStart: .value("Min", minV - pad), yEnd: .value("Saldo", p.euros))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Tag", p.date, unit: .day), y: .value("Saldo", p.euros))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let h = hovered {
                PointMark(x: .value("Tag", h.date, unit: .day), y: .value("Saldo", h.euros))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(36)
                RuleMark(x: .value("Tag", h.date, unit: .day))
                    .foregroundStyle(Theme.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: h.id * 2 > pts.count ? .topLeading : .topTrailing, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(h.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()), cents: h.cents)
                    }
            }
        }
        .chartYScale(domain: (minV - pad)...(maxV + pad))
        .chartYAxis { yAxis(min: minV, max: maxV, domain: (minV - pad)...(maxV + pad)) }
        .chartXAxis { xAxis(span: spanDays(pts.first?.date, pts.last?.date)) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            let nearest = pts.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            if nearest != hovered { hovered = nearest }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let onSelect, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x),
                              let nearest = pts.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
                        else { return }
                        onSelect(nearest.date)
                    }
            }
        }
    }

    // MARK: bars

    @ViewBuilder private var barChart: some View {
        let bars = self.buckets
        let barUnit = resolvedBarUnit
        let unit = barUnit.calendarComponent
        let xLabel: LocalizedStringKey = switch barUnit {
        case .year: "Jahr"
        case .month: "Monat"
        case .day, .automatic: "Tag"
        }
        let lo = min(0, bars.map(\.euros).min() ?? 0)
        let hi = max(0, bars.map(\.euros).max() ?? 1)
        let pad = max((hi - lo) * 0.08, 1)
        // yearly bars: every gap is already a turn of the year
        let years = barUnit == .year ? []
            : bars.first.flatMap { f in bars.last.map { BalanceBuckets.yearStarts(from: f.start, to: $0.last) } } ?? []
        Chart {
            ForEach(bars) { b in
                BarMark(x: .value(xLabel, b.start, unit: unit), y: .value("Ø Saldo", b.euros))
                    .foregroundStyle(b.averageCents < 0 ? Theme.outflow : Theme.accent)
                    .opacity(hoveredBar == nil || hoveredBar?.id == b.id ? 0.85 : 0.35)
                    .cornerRadius(1.5)
            }
            // Plain date (no unit): the rule sits on the boundary between December and January.
            ForEach(years, id: \.self) { y in
                RuleMark(x: .value("Jahr", y))
                    .foregroundStyle(Theme.tertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let h = hoveredBar {
                RuleMark(x: .value(xLabel, h.start, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: h.id * 2 > bars.count ? .topLeading : .topTrailing, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(barTitle(h), prefix: "Ø ", cents: h.averageCents)
                    }
            }
        }
        .chartYScale(domain: (lo - (lo < 0 ? pad : 0))...(hi + pad))
        .chartYAxis {
            yAxis(min: bars.map(\.euros).min() ?? 0, max: bars.map(\.euros).max() ?? 0,
                  domain: (lo - (lo < 0 ? pad : 0))...(hi + pad))
        }
        .chartXAxis { xAxis(span: spanDays(bars.first?.start, bars.last?.last), centered: barUnit != .day) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame,
                                  let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return }
                            let hit = bar(at: date, in: bars, unit: unit)
                            if hit != hoveredBar { hoveredBar = hit }
                        case .ended:
                            hoveredBar = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let onSelect, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x),
                              let hit = bar(at: date, in: bars, unit: unit)
                        else { return }
                        onSelect(hit.last)
                    }
            }
        }
    }

    /// The bar whose month (or day) contains `date`, else the nearest one.
    private func bar(at date: Date, in bars: [BalanceBucket], unit: Calendar.Component) -> BalanceBucket? {
        let cal = Calendar.current
        if let exact = bars.first(where: { cal.isDate($0.start, equalTo: date, toGranularity: unit) }) { return exact }
        return bars.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    // MARK: shared

    /// Minimum, maximum and zero on a slim trailing axis (zero only if it lies in the shown
    /// range). Labels closer than a fifth of the height to one already placed are left out,
    /// so the 56 pt chart never stacks two labels on top of each other.
    @AxisContentBuilder private func yAxis(min lo: Double, max hi: Double, domain: ClosedRange<Double>) -> some AxisContent {
        let values = Self.axisValues(min: lo, max: hi, domain: domain)
        AxisMarks(position: .trailing, values: values) { v in
            let isZero = v.as(Double.self) == 0
            AxisGridLine(stroke: StrokeStyle(lineWidth: isZero ? 0.75 : 0.5, dash: isZero ? [] : [2, 3]))
                .foregroundStyle(Theme.tertiary.opacity(isZero ? 0.7 : 0.45))
            AxisValueLabel {
                if let d = v.as(Double.self) {
                    // fixed minimum width: changing values never shift the plot sideways
                    Text(verbatim: Self.compactEuros(d))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .frame(minWidth: axisLabelWidth, alignment: .leading)
                }
            }
        }
    }

    /// Fits "-88.800 €" in Caption 2; longer labels (millions) widen it only then.
    @ScaledMetric(relativeTo: .caption2) private var axisLabelWidth: CGFloat = 50

    /// Zero first (the reference), then max and min, each only if it keeps its distance.
    static func axisValues(min lo: Double, max hi: Double, domain: ClosedRange<Double>) -> [Double] {
        let gap = (domain.upperBound - domain.lowerBound) * 0.2
        var out: [Double] = []
        for v in [0, hi, lo] where domain.contains(v) && out.allSatisfy({ abs($0 - v) >= gap }) {
            out.append(v)
        }
        return out
    }

    /// "4.820 €", "-850 €", "0 €", "1,2 Mio. €": three significant digits, short enough for the
    /// slim axis. German compact notation only abbreviates from millions on (and then drops
    /// the thousands separator below), so smaller amounts use the grouped number style.
    static func compactEuros(_ euros: Double) -> String {
        let digits = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3))
        // compact currency notation needs macOS 15; the compact number style is older
        let text = abs(euros) < 1_000_000 ? euros.formatted(digits) : euros.formatted(digits.notation(.compactName))
        return text + " €"
    }

    /// Every how many units (years, months, days) the x-axis gets a label: the smallest
    /// of `steps` for which all labels fit into `width` (each needs `labelWidth`).
    static func axisStride(units: Double, width: CGFloat, labelWidth: CGFloat, steps: [Int]) -> Int {
        let fit = max(Double(width / labelWidth), 1)
        return steps.first { units / Double($0) <= fit } ?? steps.last ?? 1
    }

    /// `centered`: bar mode puts a year/month label under the middle of its bar, not its start.
    @AxisContentBuilder private func xAxis(span: Double, centered: Bool = false) -> some AxisContent {
        if span > 400 {
            // long periods: years, every 1/2/5/10 so the labels never crowd
            let years = Self.axisStride(units: span / 365.25, width: chartWidth, labelWidth: 64, steps: [1, 2, 5, 10, 20])
            AxisMarks(values: .stride(by: .year, count: years)) { _ in
                // centred = midway to the next label: only right if that is the next year
                AxisValueLabel(format: .dateTime.year(), centered: centered && years == 1)
                    .foregroundStyle(Theme.tertiary)
            }
        } else if span < 62 {
            // short periods (this/last month): weekly day labels
            let days = Self.axisStride(units: span, width: chartWidth, labelWidth: 64, steps: [7, 14, 28])
            AxisMarks(values: .stride(by: .day, count: days)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(Theme.tertiary)
            }
        } else {
            let months = Self.axisStride(units: span / 30.44, width: chartWidth, labelWidth: 44, steps: [1, 2, 3, 6])
            AxisMarks(values: .stride(by: .month, count: months)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: centered && months == 1)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func readout(_ title: String, prefix: String = "", cents: Int64) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
            Text(verbatim: prefix + Money.format(cents))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(cents < 0 ? Theme.outflow : Theme.text)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Audio Graph / VoiceOver chart description of the balance history.
private struct BalanceChartDescriptor: AXChartDescriptorRepresentable {
    let points: [(Date, Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map(\.0)
        let values = points.map(\.1)
        let lo = dates.first?.timeIntervalSince1970 ?? 0
        let hi = dates.last?.timeIntervalSince1970 ?? 1
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "Datum"), range: lo...max(hi, lo + 1), gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
        let y = AXNumericDataAxisDescriptor(
            title: String(localized: "Saldo"), range: (values.min() ?? 0)...max(values.max() ?? 1, (values.min() ?? 0) + 1), gridlinePositions: []
        ) { Money.format(Int64(($0 * 100).rounded())) }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Saldo"), isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) }
        )
        return AXChartDescriptor(title: String(localized: "Saldoverlauf"), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
