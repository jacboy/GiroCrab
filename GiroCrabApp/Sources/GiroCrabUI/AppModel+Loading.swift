import Foundation
import SwiftUI
import GiroCrabCore

extension AppModel {
    // MARK: - Loading

    func reloadAll() {
        let all = Perf.signposter.beginInterval("reloadAll")
        defer { Perf.signposter.endInterval("reloadAll", all) }
        reloadAccounts()
        refreshSalaryCycle()
        refreshRecurring()
        mirrorDocumentsIfEnabled()
        reloadHistory()
        reloadCategories()
        reloadBookings()
        reloadRules()
        reloadSettings()
        reloadDashboard()
    }

    func reloadAccounts() {
        guard let vault else { return }
        runCore {
            applyAccountGroups(try vault.listAccountGroups(), try vault.listUserGroups())
            connections = try vault.listBankConnections()
            connectionKeys = Dictionary(uniqueKeysWithValues: connections.compactMap { c in
                (try? vault.connectionKey(connectionId: c.id)).map { (c.id, $0) }
            })
        }
    }

    func reloadCategories() {
        settlePendingSelectionLoad()
        guard let vault else { return }
        let (from, to) = periodRange
        runCore {
            categories = try vault.listCategories(dateFrom: from, dateTo: to)
            categoryTree = Self.buildTree(categories)
        }
    }

    func applyAccountGroups(_ groups: [AccountGroup], _ userGroups: [UserGroup]) {
        self.groups = groups
        self.userGroups = userGroups
        // a group removed or combined (also via sync) can't stay selected
        if case .userGroup(let u) = sidebarSelection, !userGroups.contains(where: { $0.uuid == u }) {
            sidebarSelection = .allAccounts
        }
        if case .bank(let key) = sidebarSelection, bankGroup(for: key) == nil {
            sidebarSelection = .allAccounts
        }
        rebuildAccountIndex()
    }

    func reloadDashboard() {
        guard let vault else { return }
        dashboardTask?.cancel()
        dashboardStale = false
        runCore { dashboard = try vault.investmentDashboard(months: 6) }
    }

    /// The investment dashboard reads every booking (~150 ms on 30k): off the
    /// main thread when it only follows an edit or a scope switch.
    func loadDashboard() {
        dashboardTask?.cancel()
        guard let vault else { return }
        dashboardStale = false
        dashboardTask = Task { [weak self] in
            do {
                let d = try await Self.offMain { try vault.investmentDashboard(months: 6) }
                guard !Task.isCancelled, let self, self.vault === vault else { return }
                self.dashboard = d
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.errorMessage = describe(error)
            }
        }
    }

    /// After an edit that can change a merchant's history: drop the cache, load again.
    func reloadMerchantStats() {
        merchantStatsCache = [:]
        loadMerchantStats()
    }

    /// Merchant history of the selected booking. The core scans every booking
    /// for it, so it runs off the main thread and is cached per merchant; the
    /// short delay keeps arrow-key navigation from queueing one scan per row.
    /// `keepShown`: after a data change the shown history of the same merchant
    /// stays until the fresh one arrives (no flicker).
    func loadMerchantStats(keepShown: Bool = false) {
        merchantStatsTask?.cancel()
        guard let vault, let key = selectedBooking?.merchant.key else {
            merchantStats = nil; merchantStatsKey = nil; return
        }
        if let cached = merchantStatsCache[key] { merchantStats = cached; merchantStatsKey = key; return }
        if !(keepShown && merchantStatsKey == key) { merchantStats = nil; merchantStatsKey = nil }
        merchantStatsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let stats = await Task.detached(priority: .userInitiated) {
                Perf.interval("merchantStats") { try? vault.merchantStats(merchantKey: key) }
            }.value
            // A vault switch or data change in the meantime cancels this task.
            guard !Task.isCancelled, let self, let stats else { return }
            self.merchantStatsCache[key] = stats
            if self.selectedBooking?.merchant.key == key { self.merchantStats = stats; self.merchantStatsKey = key }
        }
    }

    static func buildTree(_ flat: [GiroCrabCore.Category]) -> [CategoryNode] {
        func children(of parent: Int64?) -> [CategoryNode] {
            flat.filter { $0.parentId == parent }.map { c in
                let kids = children(of: c.id)
                return CategoryNode(category: c, children: kids.isEmpty ? nil : kids)
            }
        }
        return children(of: nil)
    }

    /// The stream starts with the newest bookings (one page, rounded up to whole
    /// days) and appends further pages while the user scrolls. A click on an
    /// older day in the balance chart raises the limit until that day is loaded.
    static let defaultListLimit: UInt32 = 300

    /// Every full reload calls this first: a page still on its way belongs to the old list.
    func dropPendingPage() {
        listGeneration += 1
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMoreBookings = false
    }

    /// More bookings match the current filter than are loaded (list limit reached).
    var hasMoreBookings: Bool {
        // the previous selection's page may still show during a selection load
        guard selectionLoadTask == nil, let total = page?.totalCount else { return false }
        return UInt32(bookings.count) < total
    }

    var remainingBookingCount: Int {
        max(0, Int(page?.totalCount ?? 0) - bookings.count)
    }

    /// Fetches the next page off the main thread and appends it. Nothing loaded
    /// so far is fetched again, so scrolling stays smooth.
    func loadMoreBookings() {
        guard let vault, hasMoreBookings, !isLoadingMoreBookings, selectionLoadTask == nil else { return }
        var next = currentFilter
        next.offset = UInt32(bookings.count)
        next.limit = appendPageSize
        let filter = next
        let generation = listGeneration
        isLoadingMoreBookings = true
        loadMoreTask = Task { [weak self] in
            let next = try? await Self.offMain {
                try Perf.interval("listTransactions") { try vault.listTransactions(filter: filter) }
            }
            // A full reload in the meantime has replaced the list this page belongs to.
            guard let self, !Task.isCancelled, generation == self.listGeneration else { return }
            self.loadMoreTask = nil
            self.isLoadingMoreBookings = false
            guard let next, !next.transactions.isEmpty else { return }
            Perf.interval("publishBookings") {
                self.bookings.append(contentsOf: next.transactions)
            }
            // an edit reloads exactly what is on screen
            self.listLimit = UInt32(self.bookings.count)
        }
    }

    /// Loads the list far enough back to contain `day` (plus some older context).
    func loadBookings(through day: String) {
        guard let vault, let total = page?.totalCount, UInt32(bookings.count) < total else { return }
        if let oldest = dayGroups.last?.date, day >= oldest { return }
        // count the bookings from that day on
        var f = currentFilter
        if f.dateFrom.map({ $0 < day }) ?? true { f.dateFrom = day }
        if let newer = try? vault.countTransactions(filter: f) {
            listLimit = max(listLimit, newer + 200)
            reloadBookings()
        }
    }

    /// Raises the list limit to everything matching the current filter.
    func loadAllBookings() {
        listLimit = max(listLimit, page?.totalCount ?? listLimit)
        reloadBookings()
    }

    var currentFilter: BookingFilter {
        let (from, to) = periodRange
        var accountIDs: [Int64] = []
        var category: Int64?
        var uncategorized = false
        switch sidebarSelection {
        case .account(let id): accountIDs = [id]
        case .group(let gid): accountIDs = groups.first(where: { $0.id == gid })?.accounts.map(\.id) ?? []
        case .bank(let key): accountIDs = bankGroup(for: key)?.accounts.map(\.id) ?? []
        case .userGroup(let uuid): accountIDs = userGroupAccountIDs(uuid)
        case .category(let id): category = id
        case .uncategorized: uncategorized = true
        case .allAccounts, .documents, .newBookings, .planned, .none: break
        }
        // Everything new, whatever the list filters say elsewhere.
        if sidebarSelection == .newBookings {
            return BookingFilter(
                accountIds: [], categoryId: nil, includeSubcategories: true, uncategorizedOnly: false,
                search: nil, dateFrom: nil, dateTo: nil, limit: listLimit, offset: 0, scope: .all,
                merchantKey: nil, direction: .all, checked: false, wholeDays: true
            )
        }
        return BookingFilter(
            accountIds: accountIDs,
            categoryId: category,
            includeSubcategories: true,
            uncategorizedOnly: uncategorized,
            search: searchText.isEmpty ? nil : searchText,
            dateFrom: from,
            dateTo: to,
            limit: listLimit,
            offset: 0,
            scope: scope,
            merchantKey: nil,
            direction: directionFilter,
            checked: statusFilter == .all ? nil : statusFilter == .checked,
            wholeDays: true
        )
    }

    /// Exports every booking matching the current list filter as Excel-friendly CSV.
    func exportFilteredBookingsCSV() {
        guard let vault else { return }
        do {
            let csv = try vault.exportBookingsCsv(filter: currentFilter)
            csvExport = CSVFileDocument(data: Data(csv.utf8))
            showCSVExporter = true
        } catch {
            showError(String(localized: "Export fehlgeschlagen"), error.localizedDescription)
        }
    }

    // MARK: - Booking list, KPIs & history

    func reloadBookings() {
        // A synchronous refresh (account, period, edit, vault change) supersedes
        // any scope request still running in the background.
        settlePendingSelectionLoad()
        scopeLoadTask?.cancel()
        dropPendingPage()
        guard let vault else { return }
        runCore {
            let filter = currentFilter
            let p = try Perf.interval("listTransactions") { try vault.listTransactions(filter: filter) }
            Perf.interval("publishBookings") { publish(p) }
        }
        reloadSelectionKPIs()
        // Every edit, sync and import ends up here: cached merchant histories may be
        // stale, and so may a scan still running from before the change. Restart it,
        // also when a history is on screen (it would otherwise keep the old numbers).
        merchantStatsCache = [:]
        loadMerchantStats(keepShown: true)
    }

    /// After a reload: the multiple selection keeps only bookings the list still
    /// shows (plus the inspector's own booking, which may be sticky).
    func pruneMultiSelection() {
        guard !selectedBookingIDs.isEmpty else { return }
        let visible = Set(visibleBookings.map(\.id))
        let kept = selectedBookingIDs.filter { visible.contains($0) || $0 == selectedBookingID }
        if kept.count != selectedBookingIDs.count { selectedBookingIDs = kept }
    }

    /// Shows a freshly loaded list page. A selected booking the page no longer
    /// contains falls back to the first row, unless it is sticky (kept in the
    /// inspector after an edit moved it out of the filter).
    func publish(_ p: BookingPage) {
        page = p
        bookings = p.transactions
        if let id = selectedBookingID, booking(withID: id) == nil, stickyBooking?.id != id {
            // „Neue Umsätze“: no booking selected unasked, auto review would check it
            selectedBookingID = sidebarSelection == .newBookings ? nil : p.transactions.first?.id
        }
        pruneMultiSelection()
    }

    /// Let the segmented control finish updating immediately. Database work
    /// and UniFFI conversion must not run inside its selection setter.
    func reloadScopeBookings() {
        scopeLoadTask?.cancel()
        dropPendingPage()
        guard let vault else { return }
        let filter = currentFilter
        scopeLoadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let load = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try vault.listTransactions(filter: filter)
            }
            do {
                let p = try await withTaskCancellationHandler {
                    try await load.value
                } onCancel: {
                    load.cancel()
                }
                // Rapid switches or a different vault/filter must never publish
                // a result from an older request, including an older error.
                guard !Task.isCancelled, let self else { return }
                // a page requested while this scope was loading belongs to no list
                self.dropPendingPage()
                self.publish(p)
                // selectionFlow always uses scope .all and is unchanged here.
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errorMessage = describe(error)
            }
        }
    }

    /// KPI tiles: same flow rules as the dashboard, but for the selected
    /// period and account/group (no account selected = all accounts).
    func reloadSelectionKPIs() {
        guard let vault else { selectionFlow = nil; return }
        let (from, to) = periodRange
        let filter = currentFilter
        // The list query already summed the same bookings unless it is narrowed further.
        if let page, filter.listHasFlow {
            selectionFlow = (page.flow.consumptionCents, page.flow.investedCents, page.flow.incomeCents)
            return
        }
        let ids = filter.accountIds
        runCore {
            let f = try vault.selectionFlow(accountIds: ids, dateFrom: from, dateTo: to)
            selectionFlow = (f.consumptionCents, f.investedCents, f.incomeCents)
        }
    }

    func reloadHistory() {
        settlePendingSelectionLoad()
        guard let vault else { return }
        let (ids, days) = historyRequest
        let (from, to) = periodRange
        runCore { history = Self.trimmedHistory(try vault.balanceHistory(accountIds: ids, days: days), from: from, to: to) }
    }

    /// Accounts and day count of the balance chart for the current selection and period.
    var historyRequest: (ids: [Int64], days: UInt32) {
        var ids: [Int64]
        switch sidebarSelection {
        case .account(let id): ids = [id]
        // same accounts as the group's sum in the header (#208)
        case .group(let gid): ids = groups.first(where: { $0.id == gid })?.accounts.filter { !$0.isArchived }.map(\.id) ?? []
        case .bank(let key): ids = bankGroup(for: key)?.accounts.filter { !$0.isArchived }.map(\.id) ?? []
        case .userGroup(let uuid): ids = userGroupBalanceAccountIDs(uuid)
        default: ids = liquidAccounts.map(\.id)
        }
        if ids.isEmpty { ids = [-1] }
        // The chart follows the selected period. "Gesamter Zeitraum": up to ~15 years back,
        // then the flat lead-in before the first booking is cut off.
        let today = Calendar.current.startOfDay(for: Date())
        let start = periodRange.0.flatMap(DateText.date) ?? Calendar.current.date(byAdding: .year, value: -15, to: today)!
        let days = max(2, (Calendar.current.dateComponents([.day], from: start, to: today).day ?? 120) + 1)
        return (ids, UInt32(days))
    }

    static func trimmedHistory(_ all: [DailyBalance], from: String?, to: String?) -> [DailyBalance] {
        var points = all
        if let to { points = points.filter { $0.date <= to } }
        if from == nil,
           let firstChange = points.indices.dropFirst().first(where: { points[$0].balanceCents != points[$0 - 1].balanceCents }) {
            // keep one point before the first change
            points = Array(points[(firstChange - 1)...])
        } else if from == nil, points.count > 366 {
            // nothing ever changed (e.g. a depot without bookings): the last year is enough
            points = Array(points.suffix(366))
        }
        return points
    }

    func reloadRules() {
        guard let vault else { return }
        rulesStale = false
        runCore { rules = try vault.listRules() }
    }

    func reloadSettings() {
        guard let vault else { return }
        runCore {
            settings = try vault.listSettings()
            logoProvider = try vault.onlineLogoProvider()
        }
        reloadProductIDState(vault)
    }

    // MARK: - Derived

    /// The loaded bookings; every filter of the list is applied by the core.
    /// „Neue Umsätze“ shows the bookings per account: ↑/↓ and ranges follow the cards.
    var visibleBookings: [Booking] {
        sidebarSelection == .newBookings ? newBookingSections.flatMap(\.bookings) : bookings
    }

    /// „Neue Umsätze“: the loaded bookings as one card per account.
    var newBookingSections: [NewBookingsSection] { NewBookings.sections(bookings: bookings, accounts: allAccounts) }

    /// Jump to `date` in the booking stream: that day, or the nearest earlier
    /// day with bookings (the balance of a quiet day comes from there).
    func jumpToDay(_ date: Date) {
        let day = DateText.iso(date)
        loadBookings(through: day)
        let groups = dayGroups // newest first
        guard let target = groups.first(where: { $0.date <= day }) ?? groups.last else { return }
        scrollToDay = DayJump(day: target.date)
    }

    func rebuildBookingIndex() {
        var index: [Booking.ID: Int] = [:]
        index.reserveCapacity(bookings.count)
        for (i, b) in bookings.enumerated() { index[b.id] = i }
        bookingIndexByID = index
        rebuildDayGroups()
    }

    private func rebuildDayGroups() {
        var out: [DayGroup] = []
        var current: [Booking] = []
        var day = ""
        for b in visibleBookings {
            if b.bookingDate != day, !current.isEmpty {
                out.append(DayGroup(date: day, bookings: current))
                current = []
            }
            day = b.bookingDate
            current.append(b)
        }
        if !current.isEmpty { out.append(DayGroup(date: day, bookings: current)) }
        dayGroups = out
    }

    func booking(withID id: Booking.ID) -> Booking? {
        bookingIndexByID[id].map { bookings[$0] }
    }

    var selectedBooking: Booking? {
        guard let id = selectedBookingID else { return nil }
        return booking(withID: id) ?? (stickyBooking?.id == id ? stickyBooking : nil)
    }

    var allAccounts: [Account] { groups.flatMap(\.accounts) }
    var hasArchivedAccounts: Bool { allAccounts.contains(where: \.isArchived) }
    /// Everyday accounts counted in "Verfügbar" (skips groups excluded from the total).
    var liquidAccounts: [Account] { allAccounts.filter { $0.inTotal && [.checking, .savings, .paymentService, .creditCard, .cash].contains($0.kind) } }
    var liquidBalance: Int64 { liquidAccounts.reduce(0) { $0 + $1.balanceCents } }
    var newCount: Int { allAccounts.reduce(0) { $0 + Int($1.newCount) } }
    var uncategorizedCount: Int { allAccounts.filter { $0.kind != .loan }.reduce(0) { $0 + Int($1.uncategorizedCount) } }

    /// Everyday spending this month (never includes ETF plans / perks).
    /// Selected account/group and period; falls back to the dashboard month.
    var consumptionThisMonth: Int64 { selectionFlow?.consumption ?? dashboard?.monthly.last?.consumptionCents ?? 0 }
    var investedThisMonth: Int64 { selectionFlow?.invested ?? dashboard?.monthly.last?.investmentCents ?? 0 }
    var incomeThisMonth: Int64 { selectionFlow?.income ?? dashboard?.monthly.last?.incomeCents ?? 0 }

    /// Number of bookings matching the list filter (the list itself loads them page by page).
    var bookingCountLabel: Int {
        Int(page?.totalCount ?? UInt32(bookings.count))
    }

    var title: String {
        switch sidebarSelection {
        case .allAccounts, .none: return String(localized: "Alle Konten")
        case .group(let id): return groups.first { $0.id == id }?.name ?? String(localized: "Gruppe")
        case .bank(let key): return bankGroup(for: key)?.name ?? String(localized: "Bank")
        case .userGroup(let uuid): return userGroups.first { $0.uuid == uuid }?.name ?? String(localized: "Gruppe")
        case .account(let id): return allAccounts.first { $0.id == id }?.name ?? String(localized: "Konto")
        case .category(let id): return categories.first { $0.id == id }?.path ?? String(localized: "Kategorie")
        case .uncategorized: return String(localized: "Ohne Kategorie")
        case .documents: return String(localized: "Belege & PostBox")
        case .newBookings: return String(localized: "Neue Umsätze")
        case .planned: return String(localized: "Geplant")
        }
    }

    var headerBalance: (label: String, cents: Int64)? {
        switch sidebarSelection {
        case .account(let id): return allAccounts.first { $0.id == id }.map { (isTangible(id) ? String(localized: "Wert heute") : String(localized: "Kontostand"), $0.balanceCents) }
        case .group(let id): return groups.first { $0.id == id }.map { (String(localized: "Summe"), $0.balanceCents) }
        case .bank(let key): return bankGroup(for: key).map { (String(localized: "Summe"), $0.balanceCents) }
        case .userGroup(let uuid): return userGroups.first { $0.uuid == uuid }.map { (String(localized: "Summe"), $0.balanceCents) }
        case .allAccounts, .none: return (String(localized: "Verfügbar (Giro, Tagesgeld, Karten)"), liquidBalance)
        case .category(let id): return categories.first { $0.id == id }.map { (String(localized: "Summe im Zeitraum"), $0.totalCents) }
        case .uncategorized, .documents, .newBookings, .planned: return nil
        }
    }

    var lastSyncText: String {
        let latest = connections.compactMap(\.lastSyncUnix).max()
        guard let latest else { return String(localized: "Noch nie aktualisiert") }
        let f = RelativeDateTimeFormatter()
        f.locale = .autoupdatingCurrent
        f.unitsStyle = .full
        let relative = f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(latest)), relativeTo: Date())
        return String(localized: "Aktualisiert \(relative)")
    }

    func account(for id: Int64) -> Account? { accountsByID[id] }

    // MARK: - Account markers (which account a booking belongs to)

    /// The account's colour (stored in the core: the user's choice, else a
    /// default from its sync identity – the same on every device). Looked up
    /// in `accountMarkers`, built once per account reload.
    func accountColor(_ accountId: Int64) -> Color {
        accountMarkers[accountId]?.color ?? Theme.tertiary
    }

    /// Short account label for the booking list, e.g. "Girokonto" – with
    /// "··3000" only when another account has the same name.
    func accountSymbol(_ accountId: Int64) -> String {
        accountMarkers[accountId]?.symbol ?? "building.columns"
    }

    func accountShortLabel(_ accountId: Int64) -> String {
        accountMarkers[accountId]?.label ?? ""
    }

    /// Markers only where the list mixes bookings of several accounts.
    var showsAccountMarkers: Bool {
        switch sidebarSelection {
        case .account: false
        case .group(let id): (groups.first { $0.id == id }?.accounts.count ?? 0) > 1
        case .bank(let key): (bankGroup(for: key)?.accounts.count ?? 0) > 1
        case .userGroup(let uuid): userGroupAccountIDs(uuid).count > 1
        case .newBookings: false // the card header names the account
        default: accountMarkers.count > 1
        }
    }

    func setAccountColor(_ accountId: Int64, hex: String?) {
        guard let vault else { return }
        runCore { try vault.setAccountColor(accountId: accountId, colorHex: hex) }
        reloadAccounts()
    }

    /// Back to the symbol of the account kind; a bank sync keeps a chosen symbol.
    func resetAccountSymbol(_ accountId: Int64) {
        guard let vault else { return }
        runCore { try vault.resetAccountSymbol(accountId: accountId) }
        reloadAccounts()
    }

    func setAccountSymbol(_ accountId: Int64, symbol: String) {
        guard let vault else { return }
        runCore { try vault.setAccountSymbol(accountId: accountId, sfSymbol: symbol) }
        reloadAccounts()
    }

    func rebuildAccountIndex() {
        reloadLoans()
        reloadAssets()
        let accounts = allAccounts
        accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func base(_ a: Account) -> String { a.name.replacingOccurrences(of: " (MoneyMoney)", with: "") }
        let nameCount = Dictionary(accounts.map { (base($0).lowercased(), 1) }, uniquingKeysWith: +)
        accountMarkers = Dictionary(accounts.map { a in
            var label = base(a)
            if nameCount[label.lowercased(), default: 0] > 1 {
                let digits = String((a.iban.isEmpty ? a.accountNumber : a.iban).filter(\.isNumber).suffix(4))
                if !digits.isEmpty && !label.contains(digits) { label += " ··\(digits)" }
            }
            return (a.id, AccountMarker(label: label, color: Color.readable(hex: a.colorHex), symbol: a.sfSymbol))
        }, uniquingKeysWith: { a, _ in a })
    }
}
