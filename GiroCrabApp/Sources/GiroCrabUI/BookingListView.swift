import SwiftUI
import GiroCrabCore

/// Column 2: calm booking stream. Fills the space between sidebar and
/// inspector, bookings grouped into white day cards
/// with the daily sum in the card header.
struct BookingStreamView: View {

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @AppStorage("showAccountAnalytics") private var showAnalytics: Bool = false
    /// View › "Auswertungen anzeigen" (GitHub #233): hides the charts and analysis cards.
    @AppStorage(ViewLayout.statisticsKey) private var showStatistics: Bool = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showCashflowIOS = false
    #endif

    /// Depots show positions; bookings (buys, sells) live on the clearing account.
    private var isDepot: Bool {
        if case .account(let id)? = model.sidebarSelection, let a = model.account(for: id) {
            return a.kind == .brokerage || a.name.localizedCaseInsensitiveContains("depot")
        }
        return false
    }

    var body: some View {
        @Bindable var model = model
        let isOverview: Bool = { if case .allAccounts? = model.sidebarSelection { return true }; return false }()
        let emptyVault = !model.demoActive && model.allAccounts.isEmpty
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Security lock: first, above everything else (stays visible).
                BankingPolicyBanner()
                AnnouncementBanner()
                #if !os(iOS)
                header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                #endif
                ScrollView {
                    // Spacing 0: the stream below is one flat run of day headers and
                    // rows that form the day cards; everything above it is one block.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 14) {
                        #if os(iOS)
                        // iPhone: header scrolls away so bookings get the screen.
                        header(isOverview: isOverview, emptyVault: emptyVault, scope: $model.scope)
                        #endif
                        Color.clear.frame(height: 0).id(Self.topID)
                        if emptyVault {
                            EmptyVaultCard()
                        }
                        if !emptyVault && model.scope != .investments {
                            MerchantLogoTipView()
                        }
                        if model.scope == .investments {
                            InvestmentDashboardView()
                        } else if showStatistics, !model.allAccounts.isEmpty, isOverview || showAnalytics {
                            // Overview: always; single account: only when toggled on.
                            #if os(iOS)
                            DisclosureGroup("Cashflow-Analyse", isExpanded: $showCashflowIOS) {
                                VStack(spacing: 14) {
                                    CashflowCard()
                                    BudgetProgressCard()
                                }
                                .padding(.top, 8)
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                            #else
                            CashflowCard().transition(Motion.slide(.top))
                            BudgetProgressCard().transition(Motion.slide(.top))
                            #endif
                        }
                        if model.isLoadingSelection {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if model.dayGroups.isEmpty && isDepot && model.searchText.isEmpty {
                            ContentUnavailableView(
                                "Keine Buchungen im Depot",
                                systemImage: "chart.line.uptrend.xyaxis",
                                description: Text("Ein Depot zeigt seine Positionen oben. Käufe, Verkäufe und Sparpläne stehen als Buchungen im Verrechnungskonto.")
                            )
                            .frame(maxWidth: .infinity)
                            // fill the visible scroll area so the placeholder sits in its middle
                            .containerRelativeFrame(.vertical, alignment: .center)
                        } else if model.dayGroups.isEmpty && !(model.allAccounts.isEmpty && !model.demoActive) {
                            ContentUnavailableView(
                                model.searchText.isEmpty ? "Keine Buchungen" : "Keine Treffer",
                                systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                                description: Text(model.searchText.isEmpty ? "Konto abrufen oder anderen Zeitraum wählen." : "Nichts passt zu „\(model.searchText)“.")
                            )
                            .padding(.top, 40)
                        }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // One lazy element per header and per booking (not per day):
                        // rows are nearly equally high, so the scroll bar stays steady.
                        ForEach(model.streamItems) { item in
                            switch item {
                            case .header(let day):
                                DayHeader(day: day)
                                    .padding(.top, 14)
                                    .id(day.id)
                            case .row(let b, let isLast):
                                DayCardRow(booking: b, isLast: isLast)
                                    .id(b.id)
                            }
                        }
                        if model.hasMoreBookings {
                            LoadMoreBookingsFooter()
                                .padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                #if os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // keeps the last booking clear of the floating search bar
                    Color.clear.frame(height: 64)
                }
                #endif
            }
            .background(Theme.canvas)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
            #if os(iOS)
            // iPhone: the detail column is not reachable by tapping, so show it as a sheet.
            .sheet(isPresented: Binding(
                get: { hSize == .compact && model.showBookingSheet && model.selectedBookingID != nil },
                set: { if !$0 { model.showBookingSheet = false } }
            )) {
                NavigationStack { InspectorView() }
                    .presentationDetents([.medium, .large])
            }
            #endif
            // Drop a receipt anywhere on the stream: matched by amount/date/merchant.
            .dropDestination(for: URL.self) { urls, _ in
                model.dropAnywhere(urls)
                return !urls.isEmpty
            }
            .background(SelectionScroller(proxy: proxy))
            // another account, group, period or view: back to the newest day
            .onChange(of: model.sidebarSelection) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.period) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scope) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.scrollToDay) { _, jump in
                guard let day = jump?.day else { return }
                withAnimation(Motion.animation(.easeOut(duration: 0.25))) { proxy.scrollTo(day, anchor: .top) }
                // select the day's first booking so the detail pane follows
                if let first = model.dayGroups.first(where: { $0.date == day })?.bookings.first {
                    model.selectedBookingID = first.id
                }
            }
        }
        // Pull-to-refresh (iOS): iCloud merge + bank sync of the current selection
        .refreshable { await model.refreshCurrentView() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = model.options.screenshotPath == nil
            #if os(macOS)
            ClickModifiers.install()
            #endif
        }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return) {
            // The balance chart sits inside the list: with keyboard focus there,
            // Return belongs to the chart (jump to the chosen day).
            guard !model.chartHasKeyboardFocus else { return .ignored }
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            model.editNote(for: b)
            return .handled
        }
        .onChange(of: model.focusListToken) { _, _ in focused = true }
        .merchantLogoTipEligibility()
        .onKeyPress(.space) {
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            // Space is Quick Look only (as in the Finder); "Geprüft" is ⇧⌘U.
            guard let d = model.documents(for: b).first else { return .ignored }
            if model.quickLookURL != nil { model.quickLookURL = nil } else { model.quickLook(d) }
            return .handled
        }
        #if os(macOS)
        // Bearbeiten › Alles auswählen (⌘A) selects all listed bookings
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAllBookings() }
        // ⌘C copies the selected booking (Edit ▸ Copy)
        .onCopyCommand {
            guard let b = model.selectedBooking else { return [] }
            return [NSItemProvider(object: b.clipboardLine as NSString)]
        }
        #endif
        .onKeyPress(characters: CharacterSet(charactersIn: "cCrR")) { press in
            // leave ⌘C to the copy command above
            guard !press.modifiers.contains(.command) else { return .ignored }
            guard model.options.screenshotPath == nil, let b = model.selectedBooking else { return .ignored }
            if press.characters.lowercased() == "c" {
                model.showCategorizer = true
            } else {
                model.openRuleEditor(from: b)
            }
            return .handled
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Händler, Zweck, IBAN, Betrag")
        #if os(iOS)
        .modifier(MainToolbar())
        #endif
        // A real window title (Window menu, Mission Control, VoiceOver); the
        // toolbar keeps its room for the scope picker.
        #if os(iOS)
        .modifier(WindowTitle(title: model.title))
        #endif
        .sheet(isPresented: $model.showPrintSheet) { PrintSheet() }
        .fileExporter(
            isPresented: $model.showCSVExporter,
            document: model.csvExport,
            contentType: .commaSeparatedText,
            defaultFilename: "GiroCrab-Buchungen"
        ) { result in
            if case .failure(let e) = result { model.showError(String(localized: "Export fehlgeschlagen"), e.localizedDescription) }
        }
    }


    @ViewBuilder
    private func header(isOverview: Bool, emptyVault: Bool, scope: Binding<BookingScope>) -> some View {
                VStack(alignment: .leading, spacing: 14) {
                    // Marketing screenshots (`--screenshot`) look like a real vault: no demo banner.
                    if model.demoActive && LaunchOptions.current.screenshotPath == nil {
                        DemoBanner()
                    }
                    #if os(iOS)
                    Picker("Ansicht", selection: scope) {
                        ForEach(BookingScope.ordered, id: \.self) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    #endif
                    if !emptyVault {
                        StreamHeaderCard()
                        if showStatistics && !isOverview && !isDepot && model.scope != .investments && !model.allAccounts.isEmpty {
                            HStack {
                                Button {
                                    withAnimation(Motion.animation(.easeInOut(duration: 0.25))) { showAnalytics.toggle() }
                                } label: {
                                    Label("Analysen", systemImage: "chart.bar.xaxis")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(showAnalytics ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Cashflow und Budgets für dieses Konto ein-/ausblenden")
                                Spacer()
                            }
                        }
                    }
                }
                #if os(iOS)
                // the scroll content already carries the 20pt side padding
                .padding(.top, 4)
                .padding(.bottom, 6)
                #else
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
                #endif
                .frame(maxWidth: .infinity)
                .padding(.trailing, scrollerInset)
    }

    /// macOS: width a scroller takes from the scroll area; the pinned header
    /// (outside the ScrollView) gets the same trailing inset to stay aligned.
    @State private var columnWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    private var scrollerInset: CGFloat {
        #if os(macOS)
        (columnWidth > 0 && contentWidth > 0) ? max(0, columnWidth - contentWidth) : 0
        #else
        0
        #endif
    }

    private static let topID = "stream-top"


    private func scrollToTop(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.topID, anchor: .top)
    }
}

#if os(macOS)
/// Keep the toolbar control independent of list, chart and inspector updates.
/// Its only observable dependency is the selected scope. The system segmented
/// control brings arrow-key navigation, focus ring and VoiceOver with it (an
/// older selection-animation glitch no longer occurs on current macOS).
private struct BookingScopePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Ansicht", selection: Binding(get: { model.scope }, set: { model.scope = $0 })) {
            ForEach(BookingScope.ordered, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Ansicht wählen (⌘1, ⌘2, ⌘3)")
    }
}
#endif

/// One horizontal slice of a white day card. The stream draws a card from
/// stacked slices (header, rows) so each slice can be a lazy element of its own:
/// rounded corners only at the card's top and bottom, the border only on the
/// sides in between.
private struct DayCardSegment: ViewModifier {
    let isTop: Bool
    let isBottom: Bool

    func body(content: Content) -> some View {
        let r: CGFloat = 12
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isTop ? r : 0, bottomLeadingRadius: isBottom ? r : 0,
            bottomTrailingRadius: isBottom ? r : 0, topTrailingRadius: isTop ? r : 0,
            style: .continuous)
        content
            .frame(maxWidth: .infinity)
            .background(shape.fill(Theme.card))
            .clipShape(shape)
            .overlay {
                // The border of the whole card: stroke a shape that reaches 1 pt past
                // an open edge and clip it, so only top/bottom slices draw that edge.
                Color.clear.overlay {
                    shape.strokeBorder(Theme.border, lineWidth: 1)
                        .padding(.top, isTop ? 0 : -1)
                        .padding(.bottom, isBottom ? 0 : -1)
                }
                .clipped()
                .allowsHitTesting(false)
            }
    }
}

/// Top of a day card: date and the day's sum.
struct DayHeader: View {
    let day: DayGroup

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(DateText.dayHeader(day.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Money.signed(day.sum))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(day.sum > 0 ? Theme.inflow : Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .modifier(DayCardSegment(isTop: true, isBottom: false))
    }
}

/// One booking of a day card; the last one closes the card.
struct DayCardRow: View {
    @Environment(AppModel.self) private var model
    let booking: Booking
    let isLast: Bool

    var body: some View {
        let b = booking
        VStack(spacing: 0) {
                BookingRow(booking: b)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.selectedBookingID = b.id
                        model.attach(urls, to: b)
                        return !urls.isEmpty
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if os(macOS)
                        // Finder-style: ⌘-click adds/removes, ⇧-click selects a range.
                        let flags = ClickModifiers.atLastMouseDown
                        model.selectBooking(b.id, toggle: flags.contains(.command), extend: flags.contains(.shift))
                        #else
                        model.selectBooking(b.id)
                        #endif
                        model.showBookingSheet = true
                    }
                    .modifier(RowSelectionTraits(id: b.id))
                    // simultaneous, so single clicks keep selecting without the double-click delay
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.editNote(for: b) })
                    .contextMenu { rowMenu(b) }
            if !isLast {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
            }
        }
        .modifier(DayCardSegment(isTop: false, isBottom: isLast))
    }

    @ViewBuilder
    private func rowMenu(_ b: Booking) -> some View {
        CategorizeMenuButton(booking: b)
        Button("Regel für diesen Händler erstellen …", systemImage: "wand.and.stars") { model.openRuleEditor(from: b) }
        Button("Notiz bearbeiten …", systemImage: "note.text") { model.editNote(for: b) }
        Button("Umsatz aufteilen (Splitbuchung) …", systemImage: "arrow.triangle.branch") { model.splitBooking = b }
        LoanAssignMenu(model: model, booking: b, hidesWhenUnavailable: true)
        Divider()
        Button("Nach „\(b.counterparty.isEmpty ? b.merchantName : b.counterparty)“ suchen", systemImage: "magnifyingglass") {
            model.searchText = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        }
        .disabled(b.counterparty.isEmpty && b.merchantName.isEmpty)
        Button("Neue Überweisung aus Buchung …", systemImage: "paperplane") { model.openTransfer(from: b) }
            .disabled(!model.canTransfer)
        Button("Umsatz kopieren", systemImage: "doc.on.doc") { copyToPasteboard(b.clipboardLine) }
        Divider()
        Button(b.checked ? "Als neu markieren" : "Als geprüft markieren", systemImage: "checkmark.circle") { model.setChecked(!b.checked, for: b) }
    }
}

/// Exactly three elements: signet · name + subtitle · amount.
struct BookingRow: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compactChip: Bool { sizeClass == .compact }
    #else
    private let compactChip = false
    #endif

    var body: some View {
        HStack(spacing: 12) {
            MerchantSignet(merchant: booking.merchant, categorySymbol: booking.categorySymbol, showNewDot: !booking.checked)
                .opacity(booking.isPending ? 0.7 : 1)
                .overlay {
                    // not booked yet: dashed outline instead of a solid tile
                    if booking.isPending {
                        RoundedRectangle(cornerRadius: 36 * 0.28, style: .continuous)
                            .strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(booking.merchant.name.isEmpty ? booking.bookingText : booking.merchant.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if booking.documentCount > 0 {
                        Image(systemName: "doc.text.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .help("\(booking.documentCount) Beleg(e) – Leertaste für QuickLook")
                    }
                    if model.recurringSeries(for: booking) != nil {
                        Image(systemName: "repeat")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                            .help("Wiederkehrende Buchung")
                            .accessibilityLabel("Wiederkehrend")
                    }
                }
                HStack(spacing: 6) {
                    #if !os(iOS)
                    if model.showsAccountMarkers {
                        AccountChip(label: model.accountShortLabel(booking.accountId), color: model.accountColor(booking.accountId),
                                    symbol: model.accountSymbol(booking.accountId), compact: compactChip)
                    }
                    #endif
                    // category with the sidebar's icon and colour, then the payment method
                    BookingCategoryLabel(booking: booking)
                        .layoutPriority(1)
                    if !booking.paymentMethod.isEmpty {
                        Text("· \(booking.paymentMethod)")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            if booking.checked {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
                    .help("Geprüft")
            }
            if booking.isPending {
                Image(systemName: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
                    .help("Vorgemerkt – noch nicht gebucht")
                    .accessibilityLabel("Vorgemerkt")
            }
            AmountLabel(cents: booking.amountCents)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, booking.isPending ? 6 : 0)
                .padding(.vertical, booking.isPending ? 2 : 0)
                .overlay {
                    if booking.isPending {
                        Capsule().strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(RowSelectionBackground(id: booking.id))
    }
}

/// Selection highlight of one row. It reads the selection in its own body, so
/// selecting a booking re-evaluates these backgrounds only and not every day
/// card and row built so far.
private struct RowSelectionBackground: View {
    @Environment(AppModel.self) private var model
    let id: Booking.ID

    var body: some View {
        model.selectedBookingIDs.contains(id) ? Theme.selection : Color.clear
    }
}

/// "Kategorisieren …" of the row menu; its title follows a multiple selection.
/// A view of its own, so the selection stays out of the day card's dependencies.
private struct CategorizeMenuButton: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    var body: some View {
        Button(model.isMultiSelection && model.selectedBookingIDs.contains(booking.id)
               ? "\(model.selectedBookingIDs.count) Buchungen kategorisieren …" : "Kategorisieren …", systemImage: "tag") {
            if !model.selectedBookingIDs.contains(booking.id) { model.selectedBookingID = booking.id }
            model.showCategorizer = true
        }
    }
}

/// "Selected" for assistive technologies; like `RowSelectionBackground`, it keeps
/// the selection out of the day card's dependencies.
private struct RowSelectionTraits: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: Booking.ID

    func body(content: Content) -> some View {
        content.accessibilityAddTraits(model.selectedBookingIDs.contains(id) ? [.isButton, .isSelected] : .isButton)
    }
}

/// Scrolls the stream to the selected booking. A view of its own, so the
/// selection is not a dependency of the whole list.
private struct SelectionScroller: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: model.selectedBookingID) { _, id in
                guard let id else { return }
                // Every row is an element of the lazy stream, so the proxy finds it
                // even while it is off-screen.
                withAnimation(Motion.animation(.easeOut(duration: 0.15))) { proxy.scrollTo(id) }
            }
    }
}

/// Category of a booking as in the sidebar: its icon and colour
/// ("Ohne Kategorie" like the sidebar entry, in the warning colour).
struct BookingCategoryLabel: View {
    let booking: Booking

    var body: some View {
        let none = booking.categoryName.isEmpty
        let color = none ? Theme.warning : Color.readable(hex: booking.categoryColorHex)
        HStack(spacing: 3) {
            Image(systemName: none ? "questionmark.folder" : (booking.categorySymbol.isEmpty ? "tag.fill" : booking.categorySymbol))
                .font(.caption)
            Text(none ? String(localized: "Ohne Kategorie") : booking.categoryName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// Account of a booking in mixed lists: the account's symbol in its colour
/// + short name (#170 – a symbol is easier to spot than a small dot).
struct AccountChip: View {
    let label: String
    let color: Color
    var symbol = "building.columns"
    /// Narrow rows: just the symbol (the category keeps the room).
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if !compact {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(compact ? 0 : 0.12)))
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Konto: \(label)"))
    }
}

/// Outflows dark slate, inflows an emerald badge.
struct AmountLabel: View {
    let cents: Int64

    var body: some View {
        if cents > 0 {
            Text(Money.signed(cents))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.inflow)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.inflowBadge))
        } else {
            Text(Money.format(cents))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.outflow)
        }
    }
}

/// End of the list: the default limit cut off older bookings – offer to load them.
struct LoadMoreBookingsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text("\(model.bookings.count) von \(model.bookings.count + model.remainingBookingCount) Buchungen geladen – ältere Buchungen sind noch nicht sichtbar.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // always laid out, only faded: the footer keeps its height while a page loads
            ProgressView().controlSize(.small)
                .opacity(model.isLoadingMoreBookings ? 1 : 0)
                .accessibilityHidden(!model.isLoadingMoreBookings)
            HStack(spacing: 10) {
                Button("Weitere Buchungen laden") { model.loadMoreBookings() }
                    .disabled(model.isLoadingMoreBookings)
                Button("Alle Buchungen laden") { model.loadAllBookings() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        // The footer scrolled into view: fetch the next page. Runs again after
        // each page for as long as the footer stays visible.
        .task(id: model.bookings.count) { model.loadMoreBookings() }
    }
}

/// macOS: the window carries the view's title, the toolbar does not show it
/// (macOS 15+). iOS keeps the empty navigation title as before.
struct WindowTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle(title)
        }
        #else
        content.navigationTitle("")
        #endif
    }
}

/// Toolbar of the booking list. macOS: customizable (View › Symbolleiste
/// anpassen …) – Überweisen and Abrufen are shown by default, the rest can be
/// added; every command is also in the menu bar. iOS: unchanged.
struct MainToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage(ViewLayout.inspectorKey) private var showInspector = true

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.bankingBlocksAll)
                Menu {
                    Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                        .disabled(!model.canTransfer)
                    Button { model.exportFilteredBookingsCSV() } label: { Label("CSV exportieren …", systemImage: "square.and.arrow.up") }
                    Button { model.showPrintSheet = true } label: { Label("Drucken …", systemImage: "printer") }
                    Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    Button { model.showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
                    if model.hasOwnVault {
                        Button { model.lock() } label: { Label("Tresor sperren", systemImage: "lock") }
                    }
                    if model.demoActive && (model.hasOwnVault || AppModel.vaultMayHoldRealData) {
                        Button { model.showOwnVault() } label: { Label("Zurück zum eigenen Tresor", systemImage: "lock.open") }
                    } else if !model.demoActive {
                        Button { model.showDemo() } label: { Label("Demo-Daten-Vorschau starten", systemImage: "theatermasks") }
                    }
                } label: { Label("Mehr", systemImage: "ellipsis.circle") }
            }
        }
        #else
        content.toolbar(id: "girocrab.main") {
            ToolbarItem(id: "scope", placement: .principal) {
                BookingScopePicker()
                    .disabled(model.sidebarSelection == .documents)
            }
            ToolbarItem(id: "transfer", placement: .primaryAction) {
                Button { model.openTransfer() } label: { Label("Überweisen", systemImage: "paperplane") }
                    .help("Neue Überweisung (⌘N)")
                    .disabled(!model.canTransfer)
            }
            ToolbarItem(id: "sync", placement: .primaryAction) {
                Button { model.requestSyncAll() } label: { Label("Abrufen", systemImage: "arrow.triangle.2.circlepath") }
                    .help(model.bankingBlocksAll ? (BankingPolicy.shared.gate?.message ?? "") : String(localized: "Alle Konten abrufen (⌘R)"))
                    .disabled(model.bankingBlocksAll)
            }
            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Informationen", systemImage: "sidebar.trailing") }
                    .help(showInspector ? String(localized: "Informationen ausblenden (⌥⌘I)") : String(localized: "Informationen einblenden (⌥⌘I)"))
            }
            ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
                Button { model.showCommandPalette = true } label: { Label("Befehle", systemImage: "command") }
                    .help("Befehlspalette (⌘K)")
            }
            ToolbarItem(id: "csv", placement: .primaryAction, showsByDefault: false) {
                Button { model.exportFilteredBookingsCSV() } label: { Label("CSV exportieren", systemImage: "square.and.arrow.up") }
                    .help("Gefilterte Buchungen als CSV exportieren …")
            }
            ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
                Button { model.showPrintSheet = true } label: { Label("Drucken", systemImage: "printer") }
                    .help("Gefilterte Buchungen drucken … (⌘P)")
            }
            ToolbarItem(id: "rules", placement: .primaryAction, showsByDefault: false) {
                Button { model.openRuleEditor() } label: { Label("Regeln", systemImage: "wand.and.stars") }
                    .help("Kategorisierungsregeln … (⌥⌘K)")
            }
            ToolbarItem(id: "lock", placement: .primaryAction, showsByDefault: false) {
                Button { model.lock() } label: { Label("Tresor sperren", systemImage: "lock") }
                    .help("Tresor sperren (⌃⌘L)")
                    .disabled(!model.hasOwnVault)
            }
            ToolbarItem(id: "settings", placement: .primaryAction, showsByDefault: false) {
                SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
                    .help("Einstellungen … (⌘,)")
            }
        }
        #endif
    }
}

#if os(macOS)
/// Modifier keys held at the last mouse-down in the app. SwiftUI runs a tap
/// gesture after the event has passed, so `NSApp.currentEvent` no longer
/// carries them; a local monitor records them as the click arrives.
@MainActor
enum ClickModifiers {
    private(set) static var atLastMouseDown: NSEvent.ModifierFlags = []
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            atLastMouseDown = event.modifierFlags.intersection([.command, .shift, .option, .control])
            return event
        }
    }
}
#endif
