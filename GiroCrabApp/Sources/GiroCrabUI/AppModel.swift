import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers
import ImageIO
import GiroCrabCore

enum SidebarItem: Hashable {
    case allAccounts
    case group(Int64)
    /// User-defined group ("Nach Gruppe"); empty uuid = "Ohne Gruppe".
    case userGroup(String)
    case account(Int64)
    case category(Int64)
    case uncategorized
    /// "Belege & PostBox"
    case documents
}

enum Period: String, CaseIterable, Identifiable {
    case all = "Gesamter Zeitraum"
    case thisMonth = "Dieser Monat"
    case lastMonth = "Letzter Monat"
    case last3Months = "Letzte 3 Monate"
    case last12Months = "Letzte 12 Monate"
    case thisQuarter = "Dieses Quartal"
    case thisYear = "Dieses Jahr"
    case lastYear = "Letztes Jahr"
    /// Pay cycle: from the latest detected salary inflow (GitHub #37).
    case sinceSalary = "Seit letztem Gehalt"
    /// User-defined start and end date (GitHub #53); the dates live in `AppModel`.
    case custom = "Benutzerdefiniert"
    var id: String { rawValue }

    /// Fixed periods for the picker; `.custom` is chosen through the date dialog.
    static var presets: [Period] { allCases.filter { $0 != .custom } }

    var title: String {
        switch self {
        case .all: return String(localized: "Gesamter Zeitraum")
        case .thisMonth: return String(localized: "Dieser Monat")
        case .lastMonth: return String(localized: "Letzter Monat")
        case .last3Months: return String(localized: "Letzte 3 Monate")
        case .last12Months: return String(localized: "Letzte 12 Monate")
        case .thisQuarter: return String(localized: "Dieses Quartal")
        case .thisYear: return String(localized: "Dieses Jahr")
        case .lastYear: return String(localized: "Letztes Jahr")
        case .sinceSalary: return String(localized: "Seit letztem Gehalt")
        case .custom: return String(localized: "Benutzerdefiniert")
        }
    }

    var range: (String?, String?) { range(now: Date()) }

    /// ISO start/end (inclusive, `nil` = open) relative to `now`.
    func range(now: Date) -> (String?, String?) {
        let cal = Calendar(identifier: .gregorian)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let startOfYear = cal.date(from: cal.dateComponents([.year], from: now))!
        switch self {
        // `.custom` dates live in `AppModel.periodRange`.
        case .all, .custom: return (nil, nil)
        // The salary start date lives in `AppModel.periodRange`; calendar month as fallback.
        case .thisMonth, .sinceSalary: return (DateText.iso(startOfMonth), nil)
        case .lastMonth:
            let start = cal.date(byAdding: .month, value: -1, to: startOfMonth)!
            let end = cal.date(byAdding: .day, value: -1, to: startOfMonth)!
            return (DateText.iso(start), DateText.iso(end))
        case .last3Months: return (DateText.iso(cal.date(byAdding: .month, value: -2, to: startOfMonth)!), nil)
        case .last12Months: return (DateText.iso(cal.date(byAdding: .month, value: -11, to: startOfMonth)!), nil)
        case .thisQuarter:
            let c = cal.dateComponents([.year, .month], from: now)
            let qStart = cal.date(from: DateComponents(year: c.year, month: ((c.month ?? 1) - 1) / 3 * 3 + 1, day: 1))!
            return (DateText.iso(qStart), nil)
        case .thisYear: return (DateText.iso(startOfYear), nil)
        case .lastYear:
            let start = cal.date(byAdding: .year, value: -1, to: startOfYear)!
            let end = cal.date(byAdding: .day, value: -1, to: startOfYear)!
            return (DateText.iso(start), DateText.iso(end))
        }
    }
}

extension BookingDirection: @retroactive Identifiable {
    public var id: Self { self }

    static let ordered: [BookingDirection] = [.all, .income, .expense]

    var title: String {
        switch self {
        case .all: return String(localized: "Einnahmen und Ausgaben")
        case .income: return String(localized: "Nur Einnahmen")
        case .expense: return String(localized: "Nur Ausgaben")
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Alle"
    case new = "Neu"
    case checked = "Geprüft"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "Alle")
        case .new: return String(localized: "Neu")
        case .checked: return String(localized: "Geprüft")
        }
    }
}

extension BookingScope {
    var title: String {
        switch self {
        case .all: return String(localized: "Alle Buchungen")
        case .everyday: return String(localized: "Alltag & Konsum")
        case .investments: return String(localized: "Sparpläne & Perks")
        }
    }
    /// Short labels for narrow (compact) screens.
    var shortTitle: String {
        switch self {
        case .all: return String(localized: "Alle")
        case .everyday: return String(localized: "Alltag")
        case .investments: return String(localized: "Sparpläne")
        }
    }
    static let ordered: [BookingScope] = [.all, .everyday, .investments]
}

struct DayJump: Equatable {
    let day: String
    let token = UUID()
}

struct DayGroup: Identifiable {
    let date: String
    let bookings: [Booking]
    var id: String { date }
    var sum: Int64 { bookings.reduce(0) { $0 + $1.amountCents } }
}

/// One lazily built element of the booking stream: a day header or a single
/// booking row. The list is flat, so its estimated height is based on rows of
/// nearly equal height instead of day cards of 1 to 30 bookings – the scroll
/// bar no longer jumps whenever a long or short day is built.
enum StreamItem: Identifiable {
    case header(DayGroup)
    case row(Booking, isLast: Bool)

    enum Key: Hashable {
        case day(String)
        case booking(Booking.ID)
    }

    var id: Key {
        switch self {
        case .header(let day): .day(day.id)
        case .row(let b, _): .booking(b.id)
        }
    }

    static func flatten(_ days: [DayGroup]) -> [StreamItem] {
        var out: [StreamItem] = []
        out.reserveCapacity(days.reduce(days.count) { $0 + $1.bookings.count })
        for day in days {
            out.append(.header(day))
            for (i, b) in day.bookings.enumerated() {
                out.append(.row(b, isLast: i == day.bookings.count - 1))
            }
        }
        return out
    }
}

struct ActiveChallenge: Identifiable {
    let id = UUID()
    let connection: BankConnection
    var challenge: Challenge
    var waiting: Bool
    var busy: Bool = false
    var error: String?
}

/// Missing FinTS product ID / API keys for a bank: shown as a setup form.
struct SetupRequest: Identifiable {
    let id = UUID()
    let connection: BankConnection
    let keys: [String]
}

/// Form state of "Neue Überweisung" (kept while the TAN sheet is shown).
/// CSV handed to `.fileExporter`.
struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TransferDraft {
    var accountID: Int64?
    var name = ""
    var iban = ""
    var bic = ""
    var amountText = ""
    var purpose = ""
    var pin = ""
    /// SEPA Instant (Echtzeitüberweisung). Off by default. If the bank does
    /// not offer or rejects it, nothing is sent automatically: the sheet
    /// offers to send it as a regular transfer (new approval).
    var instant = false
    /// Terminüberweisung: when on, `executionDate` is sent (FinTS only).
    var scheduled = false
    var executionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    /// `YYYY-MM-DD` for the core, or nil when not scheduled.
    var executionDateISO: String? {
        guard scheduled && !instant else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: executionDate)
    }
}

/// A transfer whose result is unclear: it may have been executed.
struct TransferUnknownNotice: Identifiable {
    let id = UUID()
    let reason: String
    let endToEndId: String
}

/// Name check (Verification of Payee) result awaiting the user's decision.
struct PendingPayeeCheck: Identifiable {
    let id = UUID()
    let connection: BankConnection
    let check: PayeeCheck
    var busy = false
}

struct PendingLogin: Identifiable {
    let id = UUID()
    let connection: BankConnection
}

struct CategoryNode: Identifiable, Hashable {
    let category: GiroCrabCore.Category
    var children: [CategoryNode]?
    var id: Int64 { category.id }
}

extension Array where Element == CategoryNode {
    /// Depth-first lookup of a node anywhere in the tree.
    func node(_ id: Int64) -> CategoryNode? {
        for n in self {
            if n.id == id { return n }
            if let hit = n.children?.node(id) { return hit }
        }
        return nil
    }
}

@MainActor
@Observable
public final class AppModel {
    enum VaultState: Equatable {
        /// First start: the demo is being prepared; a loading view shows meanwhile.
        case starting
        case locked
        case unlocking
        case open
        case failed(String)
    }

    let options: LaunchOptions
    private(set) var vault: Vault?
    /// Manual loans (GitHub #36), see ManualLoansUI.swift.
    @ObservationIgnored let loanStore = ManualLoanStore()
    var vaultState: VaultState = .locked
    /// The vault is open and the lock screen shows the crab's unlock hop for a moment.
    var unlockCelebrating = false

    // Data
    var groups: [AccountGroup] = [] {
        // Dock badge: unchecked bookings of the own vault; locking (ownVault
        // is gone before the lists are emptied) keeps the last known count.
        didSet {
            if dockBadge.record(newCount, ownVaultOpen: holdsRealData) { dockBadge.show() }
        }
    }
    @ObservationIgnored private let dockBadge = DockBadge()
    /// "Nach Gruppe" sidebar view (user groups, then "Ohne Gruppe").
    var userGroups: [UserGroup] = []
    /// Lookups for booking rows (see `rebuildAccountIndex`).
    private(set) var accountsByID: [Int64: Account] = [:]
    private(set) var accountMarkers: [Int64: AccountMarker] = [:]
    var categories: [GiroCrabCore.Category] = []
    var categoryTree: [CategoryNode] = []
    var bookings: [Booking] = [] { didSet { rebuildBookingIndex() } }
    /// Derived from `bookings` once per reload instead of on every view access.
    private(set) var dayGroups: [DayGroup] = [] { didSet { streamItems = StreamItem.flatten(dayGroups) } }
    /// `dayGroups` flattened into headers and rows for the lazy booking stream.
    private(set) var streamItems: [StreamItem] = []
    @ObservationIgnored private var bookingIndexByID: [Booking.ID: Int] = [:]
    var page: BookingPage?
    /// Flows of the selected account/group in the selected period; nil = not loaded yet.
    var selectionFlow: (consumption: Int64, invested: Int64, income: Int64)?
    var dashboard: InvestmentDashboard?
    var merchantStats: MerchantStats?
    var rules: [Rule] = []
    var history: [DailyBalance] = []
    var connections: [BankConnection] = []
    var settings: [SettingEntry] = []
    /// "off" (default), "duckduckgo" or "google" – normalised by the core
    /// (legacy "1"/"true" from the old toggle count as "google").
    var logoProvider = "off"
    var onlineLogos: Bool { logoProvider != "off" }
    /// Not observed: signets read it in their body (`cachedLogo`), and filling it
    /// must not re-render every signet on screen.
    @ObservationIgnored private var logoCache: [String: (image: Image, pixels: Int)] = [:]

    // UI state
    var sidebarSelection: SidebarItem? = .allAccounts { didSet { listLimit = Self.defaultListLimit; reloadSelection(periodChanged: false) } }
    var scope: BookingScope = .all {
        didSet {
            guard scope != oldValue else { return }
            listLimit = Self.defaultListLimit
            if scope == .investments, dashboardStale { loadDashboard() }
            // A selection still loading in the background has to pick up the new scope.
            if selectionLoadTask != nil { startSelectionLoad() } else { reloadScopeBookings() }
        }
    }
    var period: Period = .all { didSet { periodDidChange() } }
    /// Start/end of the `.custom` period (ISO, inclusive); remembered across launches.
    private(set) var customPeriodFrom: String = UserDefaults.standard.string(forKey: "period.customFrom") ?? AppModel.defaultCustomPeriod.from
    private(set) var customPeriodTo: String = UserDefaults.standard.string(forKey: "period.customTo") ?? AppModel.defaultCustomPeriod.to
    /// Shows the start/end date dialog of the period filter.
    var showCustomPeriod = false

    /// Sidebar selection and period as set by UI controls: the new data loads in
    /// the background, so the control responds at once. Setting `sidebarSelection`
    /// or `period` directly loads synchronously (the data is there on return).
    var interactiveSidebarSelection: SidebarItem? {
        get { sidebarSelection }
        set { loadsSelectionInBackground = true; sidebarSelection = newValue; loadsSelectionInBackground = false }
    }
    var interactivePeriod: Period {
        get { period }
        set { loadsSelectionInBackground = true; period = newValue; loadsSelectionInBackground = false }
    }
    /// Latest salary of the selected accounts; start of the `.sinceSalary` period.
    var salaryCycle: SalaryCycle?
    /// Recurring series of the selected accounts (GitHub #35).
    var recurring: [RecurringSeries] = [] {
        didSet { recurringByKey = Dictionary(grouping: recurring, by: \.baseKey) }
    }
    /// `recurring` by `baseKey`: every booking row asks `recurringSeries(for:)`,
    /// a lookup instead of a scan over all series.
    private var recurringByKey: [String: [RecurringSeries]] = [:]
    /// Recurring bookings of the current month: booked vs. still due.
    var recurringMonth: RecurringMonthOverview?
    var showRecurringSheet = false
    var showAddBank = false
    /// Series hidden with "Nicht wiederkehrend" (can be shown again).
    var recurringHidden: [IgnoredRecurring] = []
    /// Booking whose custom recurrence dates are being edited.
    var customRecurringBooking: Booking?
    /// New / checked only; filtered in the core like the direction filter, so
    /// the count, the pages and the printout follow.
    var statusFilter: StatusFilter = .all {
        didSet {
            guard statusFilter != oldValue else { return }
            listLimit = Self.defaultListLimit
            reloadBookings()
        }
    }

    /// Label of the header filter menu: "Status: Alle" or the active filters.
    var filterTitle: String {
        guard directionFilter != .all else { return String(localized: "Status: \(statusFilter.title)") }
        let kind = directionFilter == .income ? String(localized: "Einnahmen") : String(localized: "Ausgaben")
        return statusFilter == .all ? kind : "\(statusFilter.title) · \(kind)"
    }

    /// Filled icon while any filter is active.
    var filterSymbol: String {
        statusFilter == .all && directionFilter == .all
            ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
    }
    /// Income / expenses only (GitHub #53); filtered in the core, so totals and CSV follow.
    var directionFilter: BookingDirection = .all {
        didSet {
            guard directionFilter != oldValue else { return }
            listLimit = Self.defaultListLimit
            reloadBookings()
        }
    }
    var searchText: String = "" { didSet { scheduleSearch() } }
    var selectedBookingID: Booking.ID? {
        didSet {
            if stickyBooking?.id != selectedBookingID { stickyBooking = nil }
            Perf.signposter.emitEvent("selectBooking")
            // A plain selection (click, arrow keys, jumps) replaces a multiple one.
            if let id = selectedBookingID {
                if !selectedBookingIDs.contains(id) { selectedBookingIDs = [id] }
            } else if !selectedBookingIDs.isEmpty {
                selectedBookingIDs = []
            }
            // Cached per merchant; reloadMerchantStats() would drop the cache on every click.
            loadMerchantStats()
            if selectedBookingID != oldValue { scheduleAutoReview() }
        }
    }
    var autoReviewDelay: AutoReviewDelay = .stored {
        didSet { UserDefaults.standard.set(autoReviewDelay.rawValue, forKey: AutoReviewDelay.defaultsKey) }
    }
    @ObservationIgnored private(set) var autoReviewTask: Task<Void, Never>?

    /// Marks the selected booking as checked after `autoReviewDelay`, unless
    /// the selection moved on (or became a multiple one) in the meantime.
    private func scheduleAutoReview() {
        autoReviewTask?.cancel()
        autoReviewTask = nil
        guard let seconds = autoReviewDelay.seconds, let id = selectedBookingID, !isMultiSelection,
              let booking = selectedBooking, !booking.checked else { return }
        autoReviewTask = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard let self, !Task.isCancelled, self.selectedBookingID == id, !self.isMultiSelection,
                  let booking = self.selectedBooking, !booking.checked else { return }
            self.setChecked(true, for: booking)
        }
    }
    /// All selected bookings (⌘-click adds/removes, ⇧-click selects a range,
    /// ⌘A all visible). `selectedBookingID` is the one shown in the inspector.
    var selectedBookingIDs: Set<Booking.ID> = []
    var isMultiSelection: Bool { selectedBookingIDs.count > 1 }
    /// The selected bookings in list order.
    var selectedBookings: [Booking] { visibleBookings.filter { selectedBookingIDs.contains($0.id) } }

    /// Click on a booking row: plain = only this one, `toggle` (⌘) adds or
    /// removes it, `extend` (⇧) selects the range from the current booking.
    func selectBooking(_ id: Booking.ID, toggle: Bool = false, extend: Bool = false) {
        let list = visibleBookings.map(\.id)
        if extend, let anchor = selectedBookingID, let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: id) {
            selectedBookingIDs = Set(list[min(a, b)...max(a, b)])
            selectedBookingID = id
        } else if toggle {
            if selectedBookingIDs.contains(id) {
                selectedBookingIDs.remove(id)
                if selectedBookingID == id {
                    selectedBookingID = list.first { selectedBookingIDs.contains($0) }
                }
            } else {
                selectedBookingIDs.insert(id)
                selectedBookingID = id
            }
        } else {
            selectedBookingIDs = [id]
            selectedBookingID = id
        }
    }

    /// Bearbeiten › Alles auswählen (⌘A) in the booking list.
    func selectAllBookings() {
        let ids = visibleBookings.map(\.id)
        guard !ids.isEmpty else { return }
        selectedBookingIDs = Set(ids)
        if selectedBookingID.map({ !selectedBookingIDs.contains($0) }) ?? true { selectedBookingID = ids.first }
    }
    /// A booking that left the filtered list because the user just edited it
    /// (e.g. "kein Gehalt" in the salary period). It stays selected and visible
    /// in the inspector until the user selects something else, like in Mail.
    private var stickyBooking: Booking?
    /// iPhone: set by a tap on a booking row, presents the detail sheet.
    var showBookingSheet = false
    var collapsedGroups: Set<Int64> = Set(UserDefaults.standard.array(forKey: "sidebar.collapsedKindGroups") as? [Int64] ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedGroups), forKey: "sidebar.collapsedKindGroups") }
    }
    var collapsedUserGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsedUserGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedUserGroups), forKey: "sidebar.collapsedUserGroups") }
    }
    /// Archived accounts stay in their group; this hides their sidebar rows.
    var showArchivedAccounts: Bool = UserDefaults.standard.object(forKey: "sidebar.showArchived") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showArchivedAccounts, forKey: "sidebar.showArchived") }
    }
    /// Explicit per-device choice; `nil` = "Nach Gruppe" once groups exist.
    var accountViewChoice: AccountSidebarMode? = UserDefaults.standard.string(forKey: "sidebar.accountView").flatMap(AccountSidebarMode.init) {
        didSet { UserDefaults.standard.set(accountViewChoice?.rawValue, forKey: "sidebar.accountView") }
    }
    /// Settings tab on screen (set to `.groups` by "Gruppen bearbeiten …").
    var settingsTab: SettingsTab = .general
    /// macOS: the main window opens Settings when this is set (see `openSettings(_:)`).
    var settingsRequested = false
    /// (demo, `--demo-settings banks:edit|banks:add`) sheet the bank settings open on appear.
    var demoSettingsSheet: String?
    /// The one group dialog on screen (new / rename / delete / move account).
    var groupDialog: GroupDialog?
    /// The account whose Startsaldo sheet is open (#212).
    var openingBalanceRequest: OpeningBalanceRequest?
    /// The account / group whose "Symbol & Farbe" popover is open.
    var iconColorTarget: IconColorTarget?
    /// The "new category" name prompt on screen (sidebar, menu bar, ⌘K).
    var newCategoryRequest: NewCategoryRequest?
    /// "Belege & PostBox" filtered to one account (#172); nil = all accounts.
    var documentsAccountFilter: Int64?
    var expandedCategories: Set<Int64> = []
    var showRuleEditor = false {
        didSet { if showRuleEditor, rulesStale { reloadRules() } }
    }
    /// Rule match counts / investment dashboard are out of date (category change);
    /// reloaded when the rule editor opens or the Investments scope is shown.
    @ObservationIgnored private var rulesStale = false
    @ObservationIgnored private var dashboardStale = false
    var ruleDraft: Rule?
    var showSettings = false
    var showCommandPalette = false
    /// The balance chart has keyboard focus (Return there jumps to its day,
    /// instead of editing the selected booking's note).
    @ObservationIgnored var chartHasKeyboardFocus = false
    /// Run after the command palette sheet has been dismissed (opens the next sheet).
    @ObservationIgnored var afterPaletteDismiss: (@MainActor () -> Void)?
    var showCategorizer = false
    /// Booking whose inspector note field should take focus (double-click / Return in the list).
    /// Carries the id because the NoteCard is recreated per booking and claims it on appear.
    var pendingNoteFocus: Booking.ID?
    /// Bumped to hand keyboard focus back to the booking list (e.g. Esc in the note field).
    var focusListToken = 0
    var showMoneyMoneyImport = false
    /// (demo, `--demo-sheet moneymoney`) canned preview so the sheet can be shown without a file.
    var demoImportPreview: MoneyMoneyImportPreview?
    /// (demo, `--demo-sheet moneymoney-db`) canned database preview with invented data.
    var demoDbPreview: MoneyMoneyDbPreview?
    /// (demo, `--demo-sheet add-bank[:search:<text> | :bank:<name>[:setup]]`)
    /// opens "Bank hinzufügen" on that step, for PR screenshots.
    var demoAddBank: String?
    var pendingLogin: PendingLogin?
    var setupRequest: SetupRequest?
    /// Trade Republic in-app browser login (WKWebView).
    /// Not opened while the banking policy blocks this login (security lock).
    var webLoginConnection: BankConnection? {
        didSet {
            if let c = webLoginConnection, let gate = bankingGate(for: c) {
                webLoginConnection = nil
                showError(gate.title, gate.detail)
            }
        }
    }
    /// Connector key per login (`fints:<BLZ>`, …) for the banking policy.
    var connectionKeys: [Int64: String] = [:]
    /// Showing the throw-away demo vault (also when the own vault is still empty).
    var demoActive = false
    /// The personal vault while demo data is shown (nil if never unlocked).
    private(set) var ownVault: Vault?
    var activeChallenge: ActiveChallenge?
    var payeeCheck: PendingPayeeCheck?
    var syncingConnectionID: Int64?
    var toast: String?
    /// Text of the error alert. Clearing it also clears title and retry.
    var errorMessage: String? {
        didSet { if errorMessage == nil { errorTitle = nil; errorRetry = nil; errorAlternatives = [] } }
    }
    /// Alert title naming what failed (HIG: specific, not "something went wrong").
    var errorTitle: String?
    /// Optional "Erneut versuchen" action of the error alert.
    @ObservationIgnored var errorRetry: (@MainActor () -> Void)?
    /// Extra actions of the error alert after the bank rejected the FinTS registration in use:
    /// replace the own one, or switch to the other one.
    @ObservationIgnored var errorAlternatives: [(title: String, action: @MainActor () -> Void)] = []

    // MARK: FinTS product registration (GiroCrab's own vs. the user's)
    /// This build carries GiroCrab's own registration (release builds only).
    let fintsBuiltinAvailable = fintsBuiltinProductIdAvailable()
    /// Stored choice: "builtin", "own" or "" (not decided yet).
    var fintsProductIDMode = ""
    /// Registration that would be sent now: "builtin", "own" or "" (none).
    var fintsProductIDSource = ""
    /// Existing user with their own ID after an upgrade: ask once which to use.
    var offerProductIDChoice = false
    /// Settings should put the cursor into the field for the own registration.
    var focusOwnProductID = false

    /// Error alert with a specific title and, where it helps, a retry action.
    func showError(_ title: String, _ message: String, retry: (@MainActor () -> Void)? = nil) {
        errorMessage = message
        errorTitle = title
        errorRetry = retry
    }

    private var activeSession: SyncSession?
    private var activeTransfer: TransferSession?
    var showTransferSheet = false
    var csvExport = CSVFileDocument(data: Data())
    var showCSVExporter = false
    /// Print dialog (GitHub #53).
    var showPrintSheet = false
    var transferDraft = TransferDraft()
    var transferError: String?
    /// Instant was not possible and nothing was sent: why (shown in the
    /// transfer sheet with a "send as regular transfer" button).
    var transferInstantDeclined: String?
    /// The order reached the bank but its result is unclear.
    var transferUnknown: TransferUnknownNotice?
    var splitBooking: Booking?
    var transferBusy = false
    private var syncQueue: [BankConnection] = []
    /// "Alle abrufen": number of logins in the running batch (0 = single sync).
    private var syncBatchTotal = 0
    /// Logins the user skipped in the running batch, named when it ends.
    private var syncBatchSkipped: [String] = []
    /// Bumped by every sync start, cancel, skip and lock: a deferred step of
    /// an older one (e.g. the end of "Überspringen") checks it before acting.
    @ObservationIgnored private var syncGeneration = 0
    /// Security lock for bank connections; tests swap in their own instance.
    @ObservationIgnored var bankingPolicy: BankingPolicy = .shared
    /// Scheduled PSD2 sync loop (see PSD2Consent.swift).
    @ObservationIgnored var autoSyncTask: Task<Void, Never>?
    /// The running sync was started by the schedule: no login prompts, no error dialogs.
    var quietSyncConnectionID: Int64?
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var scopeLoadTask: Task<Void, Never>?
    @ObservationIgnored private var selectionLoadTask: Task<Void, Never>?
    /// A selection load has run longer than `selectionPlaceholderDelay`: list and chart are
    /// empty and show the loading placeholder until it publishes.
    private(set) var isLoadingSelection = false
    /// Grace period before a running selection load clears the previous data. Loads that
    /// finish sooner (most) swap list, chart and tiles in one step: no empty flash.
    /// Slower ones never leave the old figures under the new title for longer than this.
    @ObservationIgnored var selectionPlaceholderDelay: Duration = .milliseconds(200)
    @ObservationIgnored private var selectionPlaceholderTask: Task<Void, Never>?
    @ObservationIgnored private var loadsSelectionInBackground = false
    @ObservationIgnored private var merchantStatsTask: Task<Void, Never>?
    @ObservationIgnored private var merchantStatsCache: [String: MerchantStats] = [:]
    /// Merchant whose history `merchantStats` currently shows.
    @ObservationIgnored private var merchantStatsKey: String?

    public init(options: LaunchOptions = .current) {
        self.options = options
        StartupClock.mark("AppModel.init begin")
        if options.freshVault || options.demoSeed {
            // Developer switches only (screenshots): synchronous, not the normal start path.
            GiroCrabCore.setLanguage(code: Bundle.main.preferredLocalizations.first ?? "de")
        }
        if options.freshVault {
            openFreshVault()
            return
        }
        if !options.demoSeed {
            // Normal start: zero I/O and no FFI here. The first frame shows the loading view;
            // everything else (language, vault check, demo seeding) runs in `bootstrap()`.
            vaultState = .starting
            StartupClock.mark("AppModel.init end")
            return
        }
        if options.demoSeed {
            openDemoVault()
            switch options.initialView {
            case "alltag": scope = .everyday
            case "sparplaene", "sparpläne", "investments": scope = .investments
            case "belege", "documents": sidebarSelection = .documents
            default: break
            }
            if let q = options.selectAccount, let a = allAccounts.first(where: { $0.name.lowercased().contains(q) }) {
                sidebarSelection = .account(a.id)
                selectedBookingID = bookings.first?.id
            }
            switch options.demoFilter {
            case "income": directionFilter = .income
            case "expense", "expenses": directionFilter = .expense
            default: break
            }
            reloadBookings()
            if let q = options.pickBooking, let b = bookings.first(where: { $0.merchantName.lowercased().contains(q) || $0.counterparty.lowercased().contains(q) }) {
                selectedBookingID = b.id
            }
            if let sheet = options.demoSheet {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.presentDemoSheet(sheet)
                }
            }
            if let settings = options.demoSettings {
                let parts = settings.split(separator: ":").map(String.init)
                settingsTab = SettingsTab(demoName: parts[0]) ?? .general
                demoSettingsSheet = parts.count > 1 ? parts[1] : nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.settingsRequested = true
                }
            }
            if options.demoSync {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self?.requestSyncAll()
                }
            }
        }
    }

    /// Screenshot helper: open a sheet pre-filled with fictional data.
    private func presentDemoSheet(_ name: String) {
        switch name {
        case "icon-color":
            // the "Symbol & Farbe" popover of the first account (#167)
            if let a = allAccounts.first { iconColorTarget = .account(a.id) }
        case "icon-color-category":
            // the "Symbol & Farbe" popover of the first main category (#168)
            if let c = categories.first(where: { $0.depth == 0 }) { iconColorTarget = .category(c.id) }
        case "category":
            // "Neue Unterkategorie" sheet of the first main category (#168)
            if let c = categories.first(where: { $0.depth == 0 }) {
                newCategoryRequest = NewCategoryRequest(parent: c.id)
            }
        case "print":
            // Print dialog (GitHub #53) on last month's demo bookings.
            period = .lastMonth
            showPrintSheet = true
        case "transfer", "transfer-confirm":
            if let a = transferAccounts.first { sidebarSelection = .account(a.id) }
            openTransfer()
            transferDraft.name = "Stadtwerke München"
            transferDraft.iban = TransferSheetView.groupedIBAN("DE89370400440532013000")
            transferDraft.amountText = Money.plain(8500)
            transferDraft.purpose = "Abschlag Strom Kd-Nr 482910"
        case "moneymoney":
            demoImportPreview = MoneyMoneyImportPreview(
                totalRows: 4820, newBookings: 4820, duplicatesSkippedOrEnriched: 0, notesCount: 312,
                dateRangeStart: "2012-01-03", dateRangeEnd: "2026-10-30",
                detectedCategories: ["Haushalt > Lebensmittel", "Gehalt", "Steuern", "Wohnen > Miete", "Mobilität > Tanken", "Freizeit > Restaurants", "Versicherungen", "Reisen"],
                sampleBookings: [], suggestedAccountName: "MoneyMoney-Archiv", suggestedAccountId: nil)
            showMoneyMoneyImport = true
        case "recurring":
            showRecurringSheet = true
        case "find":
            #if os(macOS)
            ToolbarSearch.focus() // Bearbeiten › Suchen … (⌘F)
            #endif
        case "rules":
            ruleDraft = nil
            showRuleEditor = true
        case "rule-edit":
            // a rule opened in the editor (#179 pattern field)
            ruleDraft = rules.first
            showRuleEditor = true
        case "palette":
            showCommandPalette = true
        case "categorizer":
            if selectedBookingID == nil { selectedBookingID = bookings.first?.id }
            showCategorizer = true
        case "error":
            if let c = connections.first {
                showError(String(localized: "Abruf von „\(c.displayName)“ fehlgeschlagen"),
                          String(localized: "Die Bank hat nicht geantwortet (Zeitüberschreitung).")) { [weak self] in self?.requestSync(c) }
            }
        case "payee-match", "payee-close", "payee-nomatch":
            guard let connection = connections.first else { break }
            let result: PayeeMatch = name == "payee-match" ? .match : name == "payee-close" ? .closeMatch : .noMatch
            payeeCheck = PendingPayeeCheck(connection: connection, check: PayeeCheck(
                result: result, enteredName: "Stadtwerke Muenchen", iban: "DE89370400440532013000",
                bankName: result == .closeMatch ? "Stadtwerke München GmbH" : nil, reason: nil,
                notice: result == .noMatch ? "Wenn Sie die Überweisung trotzdem freigeben, kann das Geld an einen anderen Empfänger gehen." : nil))
        case let n where n == "add-bank" || n.hasPrefix("add-bank:"):
            // the original spelling (LaunchOptions lowercases --demo-sheet): "Sparkasse Köln"
            let args = CommandLine.arguments
            let raw = args.firstIndex(of: "--demo-sheet").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? n
            demoAddBank = String(raw.dropFirst("add-bank".count)).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            showAddBank = true
        case "moneymoney-db":
            #if os(macOS)
            demoDbPreview = Self.demoMoneyMoneyDbPreview(existingGiro: allAccounts.first { $0.kind == .checking })
            #endif
            showMoneyMoneyImport = true
        default: break
        }
    }

    /// Opens the MoneyMoney import. An import belongs in the own vault, so the
    /// demo data an empty vault starts with is left first.
    func openMoneyMoneyImport() {
        if isDemo && !options.demoSeed { showOwnVault() }
        showMoneyMoneyImport = true
    }

    var isDemo: Bool { demoActive }

    /// Login `demo` (case-insensitive, PIN 12345) at any bank: the core simulates the
    /// bank without network access or FinTS product ID (Apple App Review).
    nonisolated static func isMagicDemoLogin(_ login: String) -> Bool {
        login.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("demo") == .orderedSame
    }

    /// Fixed catalog entry "Demo-Bank (Test & Vorschau)" in the bank search.
    func addDemoBank() {
        addFinTsConnection(name: "Demo-Bank", blz: "99999999", url: "https://demo.invalid/fints", login: "demo")
    }

    /// Loads (or reloads) the throw-away demo vault with fictitious data for all banks,
    /// including the simulated sync / TAN / transfer flows. Own data stays untouched.
    func loadDemoData() {
        openDemoVault()
    }
    var hasOwnVault: Bool { ownVault != nil }

    // MARK: - Vault lifecycle

    /// Called by the root view's first `onAppear`: decides lock vs. demo off the main thread.
    func bootstrap() {
        guard !bootstrapped, vaultState == .starting else { return }
        bootstrapped = true
        _ = Self.quickLookCleanupObserver
        StartupClock.mark("first frame (RootView.onAppear)")
        // last known count, before the vault is unlocked
        dockBadge.show()
        Task { @MainActor [weak self] in
            let mayHoldRealData = await Task.detached(priority: .userInitiated) { () -> Bool in
                // Core texts follow the language the app bundle resolved (German without a bundle).
                GiroCrabCore.setLanguage(code: Bundle.main.preferredLocalizations.first ?? "de")
                // Decrypted QuickLook copies a crash or force quit may have left behind.
                Self.removeQuickLookFiles()
                return Self.vaultMayHoldRealData
            }.value
            guard let self else { return }
            if mayHoldRealData {
                self.vaultState = .locked
            } else {
                await self.openDemoVaultAsync()
            }
        }
    }

    @ObservationIgnored private var bootstrapped = false

    /// Create + seed the throw-away demo vault on a background thread; only the finished
    /// vault is handed back to the main actor.
    private func openDemoVaultAsync() async {
        let result: Result<Vault, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Self.makeDemoVault() }
        }.value
        StartupClock.mark("demo vault opened+seeded (background)")
        switch result {
        case .success(let v): adoptDemoVault(v)
        case .failure(let error): vaultState = .failed(describe(error))
        }
        StartupClock.mark("demo data loaded & shown")
    }

    nonisolated private static func makeDemoVault() throws -> Vault {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Demo.girocrab")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        // Throw-away demo key (the demo vault holds only fictitious data).
        let key = Data((0..<32).map { UInt8(($0 * 7 + 3) & 0xFF) })
        let v = try Vault.open(path: url.path, key: key)
        _ = try v.seedDemoData()
        return v
    }

    private func adoptDemoVault(_ v: Vault) {
        vault = v
        lockPreview = false
        demoActive = true
        vaultState = .open
        selectedBookingID = nil
        sidebarSelection = .allAccounts
        reloadAll()
        #if os(macOS)
        selectedBookingID = (bookings.first(where: { $0.flow == .consumption && $0.documentCount > 0 }) ?? bookings.first(where: { $0.flow == .consumption }))?.id
        #endif
    }

    private func openDemoVault() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Demo.girocrab")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        // Throw-away demo key (the demo vault holds only fictitious data).
        let key = Data((0..<32).map { UInt8(($0 * 7 + 3) & 0xFF) })
        do {
            let v = try Vault.open(path: url.path, key: key)
            _ = try v.seedDemoData()
            vault = v
            lockPreview = false
            demoActive = true
            vaultState = .open
            selectedBookingID = nil
            sidebarSelection = .allAccounts
            reloadAll()
            #if os(macOS)
            // iPhone: a preselected booking would push the detail page over the list.
            selectedBookingID = (bookings.first(where: { $0.flow == .consumption && $0.documentCount > 0 }) ?? bookings.first(where: { $0.flow == .consumption }))?.id
            #endif
        } catch {
            vaultState = .failed(describe(error))
        }
    }

    /// Set once the --fresh-vault file was wiped in this process.
    private static var freshVaultWiped = false

    /// Developer switch --fresh-vault: empty personal vault without Keychain.
    /// Wiped only once per launch: SwiftUI may build further `AppModel`s
    /// (`State(initialValue:)` runs on every `RootView` init), and wiping again
    /// would delete the file the live model is still writing to.
    private func openFreshVault() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Fresh.girocrab")
        // --keep-fresh-vault reopens the file as it is (e.g. a restored copy).
        if !Self.freshVaultWiped, !options.keepFreshVault {
            Self.freshVaultWiped = true
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        do {
            let v = try Vault.open(path: url.path, key: Data(repeating: 0x5A, count: 32))
            _ = try v.seedStarterCategories()
            ownVault = v
            useVault(v, demo: false)
            if let bank = options.tryAddBank,
               let kind = bankCatalog().first(where: { $0.name.lowercased().contains(bank) })?.kind {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.addConnection(kind, login: "kunde-4711")
                }
            }
        } catch {
            vaultState = .failed(describe(error))
        }
    }

    /// Structural trace (no secrets) shared with the core's depot debug log.
    /// Off unless `GIROCRAB_DEPOT_DEBUG=1`; per-user temp dir, mode 0600,
    /// no symbolic links, 5 MB cap (same rules as `depot_debug.rs`).
    static let debugLogEnabled =
        ProcessInfo.processInfo.environment["GIROCRAB_DEPOT_DEBUG"]?
            .trimmingCharacters(in: .whitespaces) == "1"

    static func debugLog(_ msg: String) {
        guard debugLogEnabled else { return }
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("girocrab-depot-debug.log").path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, st.st_uid == Darwin.getuid(), st.st_nlink == 1 else { return }
        if st.st_mode & 0o077 != 0 { Darwin.fchmod(fd, 0o600) }
        if st.st_size > 5 * 1024 * 1024 { Darwin.ftruncate(fd, 0) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    nonisolated static var vaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GiroCrab", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Keychain bypass (dev): separate file, so the real vault is never opened with the throw-away key.
        return base.appendingPathComponent(VaultKeyManager.keychainBypassed ? "tresor-dev.girocrab" : "tresor.girocrab")
    }

    func unlock() {
        guard vaultState != .unlocking else { return }
        demoDismissedLock = false
        lockPreview = false
        vaultState = .unlocking
        Task {
            do {
                // A new key only while no vault file exists: with a file, a missing
                // key (e.g. iCloud Keychain not synced yet) is an error, never a
                // fresh key that would shadow the real one.
                let existingSize = (try? FileManager.default.attributesOfItem(atPath: Self.vaultURL.path)[.size] as? Int) ?? 0
                var key = try await VaultKeyManager.shared.unlock(allowCreate: existingSize == 0)
                defer { key.resetBytes(in: 0..<key.count) }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: Self.vaultURL.path)[.size] as? Int) ?? -1
                Self.debugLog("unlock: vault=\(Self.vaultURL.lastPathComponent) size=\(fileSize) key_created_new=\(VaultKeyManager.shared.lastUnlockCreatedKey)")
                let v = try Vault.open(path: Self.vaultURL.path, key: key)
                _ = try v.seedStarterCategories()
                self.ownVault = v
                // Let the crab's unlock hop play on the lock screen before the main view replaces it.
                if !Motion.reduced {
                    self.unlockCelebrating = true
                    try? await Task.sleep(for: .milliseconds(320))
                }
                defer { self.unlockCelebrating = false }
                if try v.accountCount() == 0 && self.connectionsExist(v) == false {
                    // Nothing synced yet: show demo bookings so the UI can be judged.
                    UserDefaults.standard.set(false, forKey: Self.realDataKey)
                    self.openDemoVault()
                    self.toast = String(localized: "Ihr Tresor ist noch leer – Sie sehen Demo-Daten")
                } else {
                    self.useVault(v, demo: false)
                }
                if CloudSyncManager.shared.isEnabled {
                    await self.performSyncOrAutoAdopt(vault: v)
                }
            } catch {
                if self.ownVault == nil && !Self.vaultMayHoldRealData {
                    // Cancelled before any real data exists: back to the demo, never a dead end.
                    self.openDemoVault()
                } else {
                    self.vaultState = .failed(describe(error))
                }
            }
        }
    }

    /// Merges the other devices' snapshots and writes this device's one.
    /// The open vault does this with its own key: no biometric prompt.
    func syncNow() {
        guard let v = ownVault else { return }
        Task { await self.performSyncOrAutoAdopt(vault: v) }
    }

    /// Secondary device: the user pasted the vault key of the iCloud snapshot.
    /// Merges the snapshot with it, then switches this device's vault and
    /// keychain to that key so both devices share one key from now on.
    func adoptSyncKey(_ text: String) {
        guard let v = ownVault else { return }
        Task {
            do {
                let pasted = try VaultKeyManager.parseKey(text)
                let current = try await VaultKeyManager.shared.unlock()
                let cloud = CloudSyncManager.shared
                await cloud.sync(vault: v, remoteKey: pasted, mergeOnly: true)
                guard cloud.lastError == nil else { self.toast = cloud.lastError; return }
                if pasted != current {
                    try v.rekey(newKey: pasted)
                    do {
                        // On failure importKey writes `current` back into the keychain.
                        try VaultKeyManager.shared.importKey(pasted, replacing: current)
                    } catch {
                        // keep vault and keychain consistent: both on `current` again
                        try? v.rekey(newKey: current)
                        throw error
                    }
                }
                await cloud.sync(vault: v)
                self.reloadAll()
                self.toast = String(localized: "Tresor-Schlüssel übernommen – iCloud Sync aktiv")
            } catch {
                self.toast = describe(error)
            }
        }
    }

    private func performSyncOrAutoAdopt(vault v: Vault) async {
        await CloudSyncManager.shared.sync(vault: v)
        CloudSyncManager.shared.startAutoSync(vault: v) { [weak self] in self?.reloadAll() }
        if ((try? v.accountCount()) ?? 0) > 0 || self.connectionsExist(v) {
            if self.demoActive {
                self.useVault(v, demo: false)
            } else {
                self.reloadAll()
            }
        } else {
            self.reloadAll()
        }
    }

    private func connectionsExist(_ v: Vault) -> Bool {
        ((try? v.listBankConnections()) ?? []).isEmpty == false
    }

    private func useVault(_ v: Vault, demo: Bool) {
        vault = v
        demoActive = demo
        if !demo { UserDefaults.standard.set(true, forKey: Self.realDataKey) }
        vaultState = .open
        selectedBookingID = nil
        sidebarSelection = .allAccounts
        logoCache = [:]
        reloadAll()
        selectedBookingID = bookings.first?.id
        if demo { stopAutoSync() } else { startAutoSync() }
    }

    /// Switch to the demo data (own vault stays unlocked in the background).
    func showDemo() {
        guard !demoActive else { return }
        openDemoVault()
    }

    /// Switch back to the personal vault (unlocks it first if needed).
    func showOwnVault() {
        if let ov = ownVault {
            useVault(ov, demo: false)
        } else {
            vaultState = .locked
            unlock()
        }
    }

    /// Set when the user left the demo to the lock screen: no automatic prompt then.
    var demoDismissedLock = false

    nonisolated private static let realDataKey = "girocrab.hasRealData"

    /// Real data may exist in the (encrypted, hence unreadable while locked) vault.
    /// Without a stored answer, an existing vault file counts as real data.
    nonisolated static var vaultMayHoldRealData: Bool {
        if let v = UserDefaults.standard.object(forKey: realDataKey) as? Bool { return v }
        return FileManager.default.fileExists(atPath: vaultURL.path)
    }

    /// The personal vault is what is shown (not the demo): must be locked in the background.
    var holdsRealData: Bool { ownVault != nil && !demoActive }

    /// Demo only: shows the lock screen once so the protection can be tried out.
    /// Unlocking afterwards opens the personal vault (or comes back to the demo while it is empty).
    var lockPreview = false
    func previewLock() {
        guard demoActive, ownVault == nil, !Self.vaultMayHoldRealData else { return }
        lockPreview = true
        demoDismissedLock = true
        vaultState = .locked
    }

    /// Leaves the lock-screen preview back to the demo (never offered with real data).
    func endLockPreview() {
        guard lockPreview, !Self.vaultMayHoldRealData else { return }
        lockPreview = false
        openDemoVault()
    }

    func lock() {
        guard holdsRealData else { return }
        demoDismissedLock = true
        scopeLoadTask?.cancel()
        categoryRefreshTask?.cancel()
        dashboardTask?.cancel()
        endSelectionLoad()
        dropPendingPage()
        merchantStatsTask?.cancel()
        merchantStatsCache = [:]
        searchTask?.cancel()
        stopAutoSync()
        endBankDialogsForLock()
        quickLookURL = nil
        Self.removeQuickLookFiles()
        CloudSyncManager.shared.stopAutoSync(flushing: true)
        ownVault = nil
        demoActive = false
        vault = nil
        groups = []; userGroups = []; accountsByID = [:]; accountMarkers = [:]; bookings = []; categories = []; categoryTree = []; rules = []; connections = []; settings = []
        page = nil; dashboard = nil; merchantStats = nil; logoCache = [:]
        vaultState = .locked
    }

    /// Locking ends every bank dialog: no session keeps writing into the vault,
    /// no PIN/TAN prompt comes back after unlocking, no PIN stays in memory.
    private func endBankDialogsForLock() {
        pollTask?.cancel()
        pollTask = nil
        let session = activeSession
        let transfer = activeTransfer
        activeSession = nil
        activeTransfer = nil
        activeChallenge = nil
        payeeCheck = nil
        pendingLogin = nil
        setupRequest = nil
        webLoginConnection = nil
        syncingConnectionID = nil
        quietSyncConnectionID = nil
        statementsAccountID = nil
        syncGeneration &+= 1
        resetSyncBatch()
        transferBusy = false
        showTransferSheet = false
        transferDraft.pin = ""
        Task {
            await session?.cancel()
            await transfer?.cancel()
        }
    }

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
        run {
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
        run {
            categories = try vault.listCategories(dateFrom: from, dateTo: to)
            categoryTree = Self.buildTree(categories)
        }
    }

    private func applyAccountGroups(_ groups: [AccountGroup], _ userGroups: [UserGroup]) {
        self.groups = groups
        self.userGroups = userGroups
        // a group removed or combined (also via sync) can't stay selected
        if case .userGroup(let u) = sidebarSelection, !userGroups.contains(where: { $0.uuid == u }) {
            sidebarSelection = .allAccounts
        }
        rebuildAccountIndex()
    }

    func reloadDashboard() {
        guard let vault else { return }
        dashboardTask?.cancel()
        dashboardStale = false
        run { dashboard = try vault.investmentDashboard(months: 6) }
    }

    @ObservationIgnored private var dashboardTask: Task<Void, Never>?

    /// The investment dashboard reads every booking (~150 ms on 30k): off the
    /// main thread when it only follows an edit or a scope switch.
    private func loadDashboard() {
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
    private func loadMerchantStats(keepShown: Bool = false) {
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
    /// How many bookings a full reload fetches: one page, or as many as are loaded.
    var listLimit: UInt32 = AppModel.defaultListLimit
    /// Size of the pages appended while scrolling (tests use small pages).
    var appendPageSize: UInt32 = AppModel.defaultListLimit
    /// The next page is being fetched in the background.
    private(set) var isLoadingMoreBookings = false
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    /// Bumped by every full reload of the list; a page requested before is dropped.
    @ObservationIgnored private var listGeneration = 0

    /// Every full reload calls this first: a page still on its way belongs to the old list.
    private func dropPendingPage() {
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
    private func loadBookings(through day: String) {
        guard let vault, let total = page?.totalCount, UInt32(bookings.count) < total else { return }
        if let oldest = dayGroups.last?.date, day >= oldest { return }
        // count the bookings from that day on
        var f = currentFilter
        if f.dateFrom.map({ $0 < day }) ?? true { f.dateFrom = day }
        f.limit = 1
        if let newer = try? vault.listTransactions(filter: f).totalCount {
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
        case .userGroup(let uuid): accountIDs = userGroupAccountIDs(uuid)
        case .category(let id): category = id
        case .uncategorized: uncategorized = true
        case .allAccounts, .documents, .none: break
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

    // MARK: - Printing (GitHub #53)

    /// Everything the list shows (account, period, search, scope, status) without the list limit.
    func printSource() -> PrintReport? {
        guard let vault else { return nil }
        var filter = currentFilter
        filter.limit = 0
        do {
            let rows = try vault.listTransactions(filter: filter).transactions.map(PrintRow.init)
            let accounts = allAccounts.map {
                PrintAccount(id: $0.id, name: $0.name, iban: $0.iban, balanceCents: $0.balanceCents,
                             balanceDate: $0.balanceDate, currency: $0.currency)
            }
            var report = PrintReport(title: title, periodLabel: periodTitle, rows: rows, accounts: accounts)
            // The list's own income/expense filter is named in the printout header.
            switch directionFilter {
            case .all: break
            case .income: report.filterNotes = [PrintDirection.income.title]
            case .expense: report.filterNotes = [PrintDirection.expenses.title]
            }
            return report
        } catch {
            showError(String(localized: "Drucken nicht möglich"), error.localizedDescription)
            return nil
        }
    }

    /// End-of-day balances since `from` for each account (key = id) and combined (key 0).
    func printDailyBalances(accountIds: [Int64], from: String) -> [Int64: [String: Int64]] {
        guard let vault, !accountIds.isEmpty else { return [:] }
        let today = Calendar.current.startOfDay(for: Date())
        let start = DateText.date(from) ?? today
        let days = UInt32(max(1, (Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0) + 1))
        func map(_ ids: [Int64]) -> [String: Int64] {
            let points = (try? vault.balanceHistory(accountIds: ids, days: days)) ?? []
            return Dictionary(points.map { ($0.date, $0.balanceCents) }, uniquingKeysWith: { _, b in b })
        }
        var out: [Int64: [String: Int64]] = [0: map(accountIds)]
        for id in accountIds { out[id] = map([id]) }
        return out
    }

    func reloadBookings() {
        // A synchronous refresh (account, period, edit, vault change) supersedes
        // any scope request still running in the background.
        settlePendingSelectionLoad()
        scopeLoadTask?.cancel()
        dropPendingPage()
        guard let vault else { return }
        run {
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
    private func pruneMultiSelection() {
        guard !selectedBookingIDs.isEmpty else { return }
        let visible = Set(visibleBookings.map(\.id))
        let kept = selectedBookingIDs.filter { visible.contains($0) || $0 == selectedBookingID }
        if kept.count != selectedBookingIDs.count { selectedBookingIDs = kept }
    }

    /// Shows a freshly loaded list page. A selected booking the page no longer
    /// contains falls back to the first row, unless it is sticky (kept in the
    /// inspector after an edit moved it out of the filter).
    private func publish(_ p: BookingPage) {
        page = p
        bookings = p.transactions
        if let id = selectedBookingID, booking(withID: id) == nil, stickyBooking?.id != id {
            selectedBookingID = p.transactions.first?.id
        }
        pruneMultiSelection()
    }

    /// Let the segmented control finish updating immediately. Database work
    /// and UniFFI conversion must not run inside its selection setter.
    private func reloadScopeBookings() {
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
        run {
            let f = try vault.selectionFlow(accountIds: ids, dateFrom: from, dateTo: to)
            selectionFlow = (f.consumptionCents, f.investedCents, f.incomeCents)
        }
    }

    func reloadHistory() {
        settlePendingSelectionLoad()
        guard let vault else { return }
        let (ids, days) = historyRequest
        let (from, to) = periodRange
        run { history = Self.trimmedHistory(try vault.balanceHistory(accountIds: ids, days: days), from: from, to: to) }
    }

    /// Accounts and day count of the balance chart for the current selection and period.
    private var historyRequest: (ids: [Int64], days: UInt32) {
        var ids: [Int64]
        switch sidebarSelection {
        case .account(let id): ids = [id]
        // same accounts as the group's sum in the header (#208)
        case .group(let gid): ids = groups.first(where: { $0.id == gid })?.accounts.filter { !$0.isArchived }.map(\.id) ?? []
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

    private static func trimmedHistory(_ all: [DailyBalance], from: String?, to: String?) -> [DailyBalance] {
        var points = all
        if let to { points = points.filter { $0.date <= to } }
        if from == nil,
           let firstChange = points.indices.dropFirst().first(where: { points[$0].balanceCents != points[$0 - 1].balanceCents }) {
            // keep one point before the first change
            points = Array(points[(firstChange - 1)...])
        }
        return points
    }

    // MARK: - Selection change (account, group, category, period)

    private func reloadSelection(periodChanged: Bool) {
        if loadsSelectionInBackground, vault != nil {
            startSelectionLoad()
        } else if selectionLoadTask != nil {
            settlePendingSelectionLoad() // reloads everything
        } else {
            reloadSelectionNow(periodChanged: periodChanged)
        }
    }

    private func reloadSelectionNow(periodChanged: Bool) {
        refreshSalaryCycle()
        if periodChanged { reloadCategories() } else { refreshRecurring() }
        reloadBookings()
        reloadHistory()
    }

    /// A synchronous reload while a background selection load is still running:
    /// drop that load and bring everything it would have delivered up to date
    /// now, so its older result can never overwrite fresher data.
    private func settlePendingSelectionLoad() {
        guard selectionLoadTask != nil else { return }
        endSelectionLoad()
        refreshSalaryCycle()
        refreshRecurring()
        reloadCategories()
        reloadBookings()
        reloadHistory()
    }

    /// Runs blocking core calls off the main thread; cancelling the caller cancels the work.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let job = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    /// Stops a running selection load and its placeholder timer (no data is touched).
    private func endSelectionLoad() {
        selectionLoadTask?.cancel()
        selectionLoadTask = nil
        selectionPlaceholderTask?.cancel()
        selectionPlaceholderTask = nil
        isLoadingSelection = false
    }

    /// The load is slow: empty list and chart, so nothing of the previous
    /// selection stays under the new title.
    private func showSelectionPlaceholder() {
        isLoadingSelection = true
        page = nil
        bookings = []
        history = []
    }

    /// Everything a selection change needs, loaded off the main thread and
    /// published in one go. The previous data stays until then, at most for
    /// `selectionPlaceholderDelay`; after that list and chart show the placeholder.
    private func startSelectionLoad() {
        selectionPlaceholderTask?.cancel()
        selectionPlaceholderTask = nil
        selectionLoadTask?.cancel()
        scopeLoadTask?.cancel()
        dropPendingPage()
        guard let vault else { return }
        let ids = selectionAccountIDs
        let month = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        if selectionPlaceholderDelay <= .zero || isLoadingSelection {
            showSelectionPlaceholder()
        } else {
            let delay = selectionPlaceholderDelay
            selectionPlaceholderTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.selectionLoadTask != nil else { return }
                self.selectionPlaceholderTask = nil
                self.showSelectionPlaceholder()
            }
        }
        let task = Task { [weak self] in
            let load = Perf.signposter.beginInterval("selectionLoad")
            defer { Perf.signposter.endInterval("selectionLoad", load) }
            do {
                // The pay cycle comes first: `.sinceSalary` derives the period from it.
                let cycle = try await Self.offMain { try vault.salaryCycle(accountIds: ids) }
                guard !Task.isCancelled, let self else { return }
                self.salaryCycle = cycle
                let filter = self.currentFilter
                let (from, to) = self.periodRange
                let chart = self.historyRequest
                let listHasFlow = filter.listHasFlow
                let loaded = try await Self.offMain {
                    let page = try Perf.interval("listTransactions") { try vault.listTransactions(filter: filter) }
                    try Task.checkCancellation()
                    let flow = listHasFlow ? page.flow : try vault.selectionFlow(accountIds: filter.accountIds, dateFrom: from, dateTo: to)
                    try Task.checkCancellation()
                    let recurring = try vault.recurringSnapshot(accountIds: ids, year: Int32(month.year ?? 2026), month: UInt32(month.month ?? 1))
                    let categories = try vault.listCategories(dateFrom: from, dateTo: to)
                    try Task.checkCancellation()
                    let history = try vault.balanceHistory(accountIds: chart.ids, days: chart.days)
                    return (page: page, flow: flow, recurring: recurring, categories: categories, history: history)
                }
                // A newer selection or a synchronous reload cancelled this request.
                guard !Task.isCancelled else { return }
                self.selectionLoadTask = nil
                self.endSelectionLoad()
                let publish = Perf.signposter.beginInterval("publishSelection")
                self.publish(loaded.page)
                self.selectionFlow = (loaded.flow.consumptionCents, loaded.flow.investedCents, loaded.flow.incomeCents)
                self.recurring = loaded.recurring.series
                self.recurringHidden = loaded.recurring.ignored
                self.recurringMonth = loaded.recurring.month
                self.categories = loaded.categories
                self.categoryTree = Self.buildTree(loaded.categories)
                self.history = Self.trimmedHistory(loaded.history, from: from, to: to)
                Perf.signposter.endInterval("publishSelection", publish)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.selectionLoadTask = nil
                self.endSelectionLoad()
                self.errorMessage = describe(error)
            }
        }
        selectionLoadTask = task
    }

    func reloadRules() {
        guard let vault else { return }
        rulesStale = false
        run { rules = try vault.listRules() }
    }

    func reloadSettings() {
        guard let vault else { return }
        run {
            settings = try vault.listSettings()
            logoProvider = try vault.onlineLogoProvider()
        }
        reloadProductIDState(vault)
    }

    /// Mirrors the core's FinTS registration choice. New users start with GiroCrab's
    /// registration; users who already entered their own are asked once.
    private func reloadProductIDState(_ vault: Vault) {
        var mode = (try? vault.fintsProductIdMode()) ?? ""
        let hasOwn = settingEntry("fints.product_id")?.hasValue == true
        if fintsBuiltinAvailable, mode.isEmpty, !hasOwn, !isDemo {
            try? vault.setFintsProductIdMode(mode: "builtin")
            mode = "builtin"
        }
        fintsProductIDMode = mode
        fintsProductIDSource = (try? vault.fintsProductIdSource()) ?? ""
        offerProductIDChoice = fintsBuiltinAvailable && mode.isEmpty && hasOwn && !isDemo
    }

    /// Stores the choice. The user's own ID always stays in the vault.
    func setFintsProductIDMode(_ mode: String) {
        guard let vault else { return }
        run { try vault.setFintsProductIdMode(mode: mode) }
        offerProductIDChoice = false
        reloadSettings()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadBookings()
        }
    }

    // MARK: - Pay cycle (GitHub #37)

    /// Accounts of the sidebar selection; empty = all accounts.
    private var selectionAccountIDs: [Int64] {
        switch sidebarSelection {
        case .account(let id): return [id]
        case .group(let gid): return groups.first(where: { $0.id == gid })?.accounts.map(\.id) ?? []
        case .userGroup(let uuid): return userGroupAccountIDs(uuid)
        default: return []
        }
    }

    /// Date range of the selected period; `.sinceSalary` starts at the latest salary.
    var periodRange: (String?, String?) {
        if period == .sinceSalary, let c = salaryCycle { return (c.lastDate, nil) }
        if period == .custom { return (customPeriodFrom, customPeriodTo) }
        return period.range
    }

    /// Label of the period menu: the preset name or "15.03.2025 – 30.06.2025".
    var periodTitle: String {
        guard period == .custom else { return period.title }
        return "\(DateText.medium(customPeriodFrom)) – \(DateText.medium(customPeriodTo))"
    }

    /// Default of the date dialog before the user ever picked a range: last month.
    static var defaultCustomPeriod: (from: String, to: String) {
        let (from, to) = Period.lastMonth.range
        return (from ?? DateText.iso(Date()), to ?? DateText.iso(Date()))
    }

    /// Switches to the user-defined period (GitHub #53); swaps the dates if needed.
    func applyCustomPeriod(from: Date, to: Date) {
        let (a, b) = from <= to ? (from, to) : (to, from)
        customPeriodFrom = DateText.iso(a)
        customPeriodTo = DateText.iso(b)
        UserDefaults.standard.set(customPeriodFrom, forKey: "period.customFrom")
        UserDefaults.standard.set(customPeriodTo, forKey: "period.customTo")
        if period == .custom { periodDidChange() } else { period = .custom }
    }

    private func periodDidChange() {
        listLimit = Self.defaultListLimit
        reloadSelection(periodChanged: true)
    }

    /// Subtitle of the period-based KPI tiles.
    var periodSubtitle: String {
        guard period == .sinceSalary else { return periodTitle }
        guard let c = salaryCycle else { return String(localized: "Monat (kein Gehalt)") }
        return String(localized: "Seit Gehalt am \(DateText.medium(c.lastDate))")
    }

    func refreshSalaryCycle() {
        settlePendingSelectionLoad()
        guard let vault else { salaryCycle = nil; return }
        let ids = selectionAccountIDs
        run { salaryCycle = try vault.salaryCycle(accountIds: ids) }
    }

    /// `true` = salary, `false` = never salary, `nil` = automatic detection.
    func setSalaryFlag(_ booking: Booking, _ flag: Bool?) {
        guard let vault else { return }
        run { try vault.setBookingSalaryFlag(bookingId: booking.id, flag: flag) }
        // keep the edited booking selected even if it leaves the period
        if selectedBookingID == booking.id { stickyBooking = freshBooking(booking) }
        refreshSalaryCycle()
        if period == .sinceSalary { reloadCategories(); reloadHistory() }
        reloadBookings()
    }

    /// Re-reads one booking from the vault (independent of the list filter).
    private func freshBooking(_ b: Booking) -> Booking? {
        guard let vault else { return nil }
        let f = BookingFilter(accountIds: [b.accountId], categoryId: nil, includeSubcategories: true, uncategorizedOnly: false,
                              search: nil, dateFrom: b.bookingDate, dateTo: b.bookingDate, limit: 0, offset: 0,
                              scope: .all, merchantKey: nil, direction: .all, checked: nil, wholeDays: false)
        return (try? vault.listTransactions(filter: f))?.transactions.first { $0.id == b.id }
    }

    // MARK: - PDF statements & document folder (GitHub #57)

    private static let mirrorDirKey = "documents.mirrorDir"
    /// Folder that receives a copy of every document (nil = off). Per Mac, not per vault.
    var documentMirrorPath: String? = UserDefaults.standard.string(forKey: "documents.mirrorDir")
    /// Result of the latest mirror run, for the settings.
    var documentMirrorStatus: String?
    private var mirrorRunning = false

    /// Suggested mirror folder: iCloud Drive/GiroCrab/Kontoauszüge (if iCloud Drive exists).
    static var suggestedMirrorURL: URL? {
        #if os(macOS)
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docs.path) else { return nil }
        return docs.appendingPathComponent("GiroCrab/Kontoauszüge", isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Turns the document folder on (all documents are copied once) or off.
    func setDocumentMirror(_ url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            documentMirrorPath = url.path
            UserDefaults.standard.set(url.path, forKey: Self.mirrorDirKey)
            if let vault { run { try vault.resetDocumentMirror() } }
            mirrorDocumentsIfEnabled()
        } else {
            documentMirrorPath = nil
            documentMirrorStatus = nil
            UserDefaults.standard.removeObject(forKey: Self.mirrorDirKey)
        }
    }

    /// Copies documents that are not in the folder yet (after syncs, imports, drops).
    func mirrorDocumentsIfEnabled() {
        guard let vault, let dir = documentMirrorPath, !isDemo, !mirrorRunning else { return }
        mirrorRunning = true
        Task { @MainActor [weak self] in
            let result: Result<UInt32, Error> = await Task.detached(priority: .utility) {
                Result { try vault.mirrorNewDocuments(destDir: dir) }
            }.value
            guard let self else { return }
            mirrorRunning = false
            switch result {
            case .success(let n):
                let time = Date().formatted(date: .omitted, time: .shortened)
                documentMirrorStatus = n == 0
                    ? String(localized: "Aktuell (geprüft \(time))")
                    : String(localized: "\(n) Dokument(e) gesichert (\(time))")
            case .failure(let e):
                documentMirrorStatus = describe(e)
            }
        }
    }

    func autoStatements(_ account: Account) -> Bool {
        guard let vault else { return false }
        return (try? vault.autoStatementsEnabled(accountId: account.id)) ?? false
    }

    func setAutoStatements(_ account: Account, _ on: Bool) {
        guard let vault else { return }
        run { try vault.setAutoStatements(accountId: account.id, enabled: on) }
    }

    // MARK: - Recurring bookings (GitHub #35)

    func refreshRecurring() {
        settlePendingSelectionLoad()
        guard let vault else { recurring = []; recurringMonth = nil; return }
        let ids = selectionAccountIDs
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        run {
            let snapshot = try vault.recurringSnapshot(accountIds: ids, year: Int32(c.year ?? 2026), month: UInt32(c.month ?? 1))
            recurring = snapshot.series
            recurringHidden = snapshot.ignored
            recurringMonth = snapshot.month
        }
    }

    /// The recurring series a booking belongs to, if any.
    func recurringSeries(for b: Booking) -> RecurringSeries? {
        guard !b.recurrenceKey.isEmpty else { return nil }
        return recurringByKey[b.recurrenceKey]?.first { s in
            (!s.amountSpecific || abs(b.amountCents - s.amountCents) * 100 <= abs(s.amountCents) * 15)
        }
    }

    func markRecurring(_ b: Booking, _ interval: RecurrenceInterval, customDates: [String] = []) {
        guard let vault else { return }
        run { try vault.markBookingRecurring(bookingId: b.id, interval: interval, customDates: customDates) }
        refreshRecurring()
    }

    /// "Nicht wiederkehrend" for a detected or marked series.
    func ignoreRecurring(_ s: RecurringSeries) {
        guard let vault else { return }
        run { try vault.ignoreRecurring(seriesKey: s.seriesKey) }
        refreshRecurring()
    }

    /// Back to automatic detection (also shows a hidden series again).
    func resetRecurring(_ s: RecurringSeries) { resetRecurring(key: s.seriesKey) }

    func resetRecurring(key: String) {
        guard let vault else { return }
        run { try vault.resetRecurring(seriesKey: key) }
        refreshRecurring()
    }

    /// Selects a booking in the list, widening the period if it is outside of it.
    func revealBooking(_ id: Int64) {
        if booking(withID: id) == nil {
            sidebarSelection = .allAccounts
            period = .all
            directionFilter = .all
            statusFilter = .all
            searchText = ""
        }
        // After a closing sheet / list reload, so the list can scroll to the row.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            // an older booking is not on the first page: load back to its day
            if booking(withID: id) == nil, let day = try? vault?.bookingDate(bookingId: id) {
                loadBookings(through: day)
            }
            if selectedBookingID == id { selectedBookingID = nil }
            selectedBookingID = id
        }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = describe(error) }
    }

    // MARK: - Logos (Tier 2)

    /// Bumped whenever a domain override changes -> signets refetch.
    var logoVersion = 0
    private var logoInflight: [String: Task<(image: Image, pixels: Int)?, Never>] = [:]

    /// Dual-source pipeline, stage 2: cached PNG/ICO from the vault or the
    /// Google S2 / DuckDuckGo favicon for the first candidate domain that
    /// yields a real logo (default globe rejected in Rust). Requests for the
    /// same merchant are shared; results pop into every row automatically.
    func logo(for merchant: MerchantInfo) async -> (image: Image, pixels: Int)? {
        let candidates = Self.logoCandidates(merchant)
        guard !candidates.isEmpty, let vault else { return nil }
        let key = candidates.joined(separator: "|")
        if let hit = logoCache[key] { return hit }
        if let running = logoInflight[key] { return await running.value }
        let online = onlineLogos
        let task = Task<(image: Image, pixels: Int)?, Never> {
            // Vault read (decryption) and PNG decoding off the main thread: a
            // signet scrolling into view must not cost a frame.
            let cached = try? await Self.offMain { () -> (image: Image, pixels: Int)? in
                for d in candidates {
                    if let data = try? vault.getMerchantLogoPng(domain: d) { return Self.decodeLogo(data) }
                }
                return nil
            }
            if let cached { return cached }
            guard online, let data = (try? await vault.fetchMerchantLogo(candidates: candidates))??.bytes else { return nil }
            return try? await Self.offMain { Self.decodeLogo(data) }
        }
        logoInflight[key] = task
        let result = await task.value
        logoInflight[key] = nil
        if let result { logoCache[key] = result }
        return result
    }

    /// The logo of `merchant` if it is already loaded – for a signet's first frame,
    /// so a row built while scrolling shows its logo at once instead of one
    /// frame later.
    func cachedLogo(for merchant: MerchantInfo) -> (image: Image, pixels: Int)? {
        let candidates = Self.logoCandidates(merchant)
        return candidates.isEmpty ? nil : logoCache[candidates.joined(separator: "|")]
    }

    private nonisolated static func logoCandidates(_ merchant: MerchantInfo) -> [String] {
        if merchant.domainCandidates.isEmpty && !merchant.domain.isEmpty { return [merchant.domain] }
        return merchant.domainCandidates
    }

    /// Decodes a favicon (PNG/ICO) into a ready-to-draw bitmap once: `NSImage`
    /// would decode lazily at first draw, i.e. on the main thread mid-scroll.
    /// `pixels` is the largest representation (the "sharp logo" threshold).
    nonisolated static func decodeLogo(_ data: Data) -> (image: Image, pixels: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best = -1, bestWidth = 0
        for i in 0..<CGImageSourceGetCount(src) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if w > bestWidth || best < 0 { best = i; bestWidth = w }
        }
        guard best >= 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, best, opts as CFDictionary) else { return nil }
        return (image: Image(decorative: cg, scale: 1), pixels: bestWidth)
    }

    /// Kept for callers that only know a domain.
    func logo(for domain: String) async -> (image: Image, pixels: Int)? {
        guard !domain.isEmpty, let vault else { return nil }
        if let hit = logoCache[domain] { return hit }
        var data = try? vault.getMerchantLogoPng(domain: domain)
        if data == nil, onlineLogos { data = try? await vault.fetchLogo(domain: domain) }
        guard let data, let img = Self.image(from: data) else { return nil }
        let entry = (image: img, pixels: Self.pixelWidth(of: data))
        logoCache[domain] = entry
        return entry
    }

    /// Sets / clears the original loan amount ("Ursprünglicher Kreditbetrag").
    func setAccountInitialBalance(_ accountId: Int64, cents: Int64?) {
        guard let vault else { return }
        run { try vault.setAccountInitialBalance(accountId: accountId, cents: cents) }
        reloadAccounts()
    }

    /// Manual domain from the inspector; nil/empty removes the override.
    func setMerchantDomain(_ merchant: MerchantInfo, _ domain: String?) {
        guard let vault else { return }
        run {
            let stored = try vault.setMerchantDomain(merchantKey: merchant.key, domain: domain)
            toast = stored.map { String(localized: "Domain für \(merchant.name): \($0) – Logo wird geladen") } ?? String(localized: "Domain-Zuordnung entfernt")
        }
        logoCache = [:]
        logoVersion += 1
        reloadBookings()
        reloadMerchantStats()
    }

    static func pixelWidth(of data: Data) -> Int {
        #if os(macOS)
        return NSImage(data: data)?.representations.map(\.pixelsWide).max() ?? 0
        #else
        return UIImage(data: data).map { Int($0.size.width * $0.scale) } ?? 0
        #endif
    }

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    func clearLogoCache() {
        guard let vault else { return }
        run { _ = try vault.clearLogoCache() }
        logoCache = [:]
        toast = String(localized: "Logo-Cache geleert")
    }

    // MARK: - Derived

    /// The loaded bookings; every filter of the list is applied by the core.
    var visibleBookings: [Booking] { bookings }

    /// Day card the stream should scroll to (set by a click in the balance chart);
    /// a fresh token per click, so clicking the same day again scrolls again.
    var scrollToDay: DayJump?

    /// Jump to `date` in the booking stream: that day, or the nearest earlier
    /// day with bookings (the balance of a quiet day comes from there).
    func jumpToDay(_ date: Date) {
        let day = DateText.iso(date)
        loadBookings(through: day)
        let groups = dayGroups // newest first
        guard let target = groups.first(where: { $0.date <= day }) ?? groups.last else { return }
        scrollToDay = DayJump(day: target.date)
    }

    private func rebuildBookingIndex() {
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

    private func booking(withID id: Booking.ID) -> Booking? {
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
        case .allAccounts, .none: return String(localized: "Übersicht")
        case .group(let id): return groups.first { $0.id == id }?.name ?? String(localized: "Gruppe")
        case .userGroup(let uuid): return userGroups.first { $0.uuid == uuid }?.name ?? String(localized: "Gruppe")
        case .account(let id): return allAccounts.first { $0.id == id }?.name ?? String(localized: "Konto")
        case .category(let id): return categories.first { $0.id == id }?.path ?? String(localized: "Kategorie")
        case .uncategorized: return String(localized: "Ohne Kategorie")
        case .documents: return String(localized: "Belege & PostBox")
        }
    }

    var headerBalance: (label: String, cents: Int64)? {
        switch sidebarSelection {
        case .account(let id): return allAccounts.first { $0.id == id }.map { (String(localized: "Kontostand"), $0.balanceCents) }
        case .group(let id): return groups.first { $0.id == id }.map { (String(localized: "Summe"), $0.balanceCents) }
        case .userGroup(let uuid): return userGroups.first { $0.uuid == uuid }.map { (String(localized: "Summe"), $0.balanceCents) }
        case .allAccounts, .none: return (String(localized: "Verfügbar (Giro, Tagesgeld, Karten)"), liquidBalance)
        case .category(let id): return categories.first { $0.id == id }.map { (String(localized: "Summe im Zeitraum"), $0.totalCents) }
        case .uncategorized, .documents: return nil
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
        case .userGroup(let uuid): userGroupAccountIDs(uuid).count > 1
        default: accountMarkers.count > 1
        }
    }

    func setAccountColor(_ accountId: Int64, hex: String?) {
        guard let vault else { return }
        run { try vault.setAccountColor(accountId: accountId, colorHex: hex) }
        reloadAccounts()
    }

    /// Back to the symbol of the account kind; a bank sync keeps a chosen symbol.
    func resetAccountSymbol(_ accountId: Int64) {
        guard let vault else { return }
        run { try vault.resetAccountSymbol(accountId: accountId) }
        reloadAccounts()
    }

    func setAccountSymbol(_ accountId: Int64, symbol: String) {
        guard let vault else { return }
        run { try vault.setAccountSymbol(accountId: accountId, sfSymbol: symbol) }
        reloadAccounts()
    }

    fileprivate func rebuildAccountIndex() {
        reloadLoans()
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

    // MARK: - Keyboard navigation

    func moveSelection(_ delta: Int) {
        let list = visibleBookings
        guard !list.isEmpty else { return }
        let idx = selectedBookingID.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(list.count - 1, idx + delta))
        selectedBookingIDs = []
        selectedBookingID = list[next].id
    }

    // MARK: - Editing

    func setCategory(_ categoryID: Int64?, for booking: Booking) {
        setCategory(categoryID, for: [booking])
    }

    /// One category for several bookings (multiple selection).
    /// The write is cheap; the reloads behind it are not (~0.5 s on 30k bookings).
    /// So the rows show the new category at once and everything derived from it
    /// (totals, counts, KPIs) follows from a background refresh.
    func setCategory(_ categoryID: Int64?, for bookings: [Booking]) {
        guard let vault, !bookings.isEmpty else { return }
        do {
            for b in bookings { try vault.setTransactionCategory(transactionId: b.id, categoryId: categoryID) }
        } catch {
            // Partly written: show the database state as before (synchronous).
            errorMessage = describe(error)
            reloadAfterCategoryChange()
            return
        }
        showCategory(categoryID, on: Set(bookings.map(\.id)))
        // Merchant histories count categories: keep the shown one until the new one is in.
        merchantStatsCache = [:]
        loadMerchantStats(keepShown: true)
        // Rule counts and the investment dashboard: reload only when on screen,
        // otherwise when the rule editor opens / the Investments scope is shown.
        if showRuleEditor { reloadRules() } else { rulesStale = true }
        if scope == .investments { loadDashboard() } else { dashboardStale = true }
        refreshAfterCategoryChange()
    }

    /// Optimistic update: the new category on the loaded rows (and a sticky
    /// inspector booking) before the background refresh brings the real data.
    private func showCategory(_ categoryID: Int64?, on ids: Set<Booking.ID>) {
        let c = categoryID.flatMap { id in categories.first { $0.id == id } }
        func patch(_ b: inout Booking) {
            b.categoryId = c?.id
            b.categoryName = c?.name ?? ""
            b.categoryPath = c?.path ?? ""
            b.categoryColorHex = c?.colorHex ?? ""
            b.categorySymbol = c?.sfSymbol ?? ""
            b.categorySource = c == nil ? .none : .manual
        }
        var rows = bookings
        for i in rows.indices where ids.contains(rows[i].id) { patch(&rows[i]) }
        bookings = rows
        if var s = stickyBooking, ids.contains(s.id) { patch(&s); stickyBooking = s }
    }

    /// The synchronous reloads a category change needs (fallback when the write
    /// or the background refresh failed).
    private func reloadAfterCategoryChange() {
        categoryRefreshTask?.cancel()
        reloadBookings(); reloadCategories(); reloadAccounts()
    }

    /// Category refresh in flight; only a newer category change or a vault
    /// switch cancels it, so the totals it brings can't get lost.
    @ObservationIgnored private var categoryRefreshTask: Task<Void, Never>?

    /// Everything a category change affects, loaded off the main thread:
    /// - the list page, published unless another list load started meanwhile
    ///   (`listGeneration`; that load already reads the new category),
    /// - KPIs and category totals, published if the accounts / period are unchanged,
    /// - the account counters ("ohne Kategorie"), published always.
    /// Quick successive assignments only publish the last result.
    private func refreshAfterCategoryChange() {
        // A selection still loading publishes everything itself.
        if selectionLoadTask != nil { settlePendingSelectionLoad(); reloadAccounts(); return }
        categoryRefreshTask?.cancel()
        // An older list load in flight would publish rows without the new category.
        scopeLoadTask?.cancel()
        dropPendingPage()
        guard let vault else { return }
        let generation = listGeneration
        let filter = currentFilter
        let (from, to) = periodRange
        let listHasFlow = filter.listHasFlow
        categoryRefreshTask = Task { [weak self] in
            do {
                let r = try await Self.offMain { () -> CategoryRefresh in
                    let page = try Perf.interval("listTransactions") { try vault.listTransactions(filter: filter) }
                    try Task.checkCancellation()
                    let flow = listHasFlow ? page.flow : try vault.selectionFlow(accountIds: filter.accountIds, dateFrom: from, dateTo: to)
                    try Task.checkCancellation()
                    return CategoryRefresh(
                        page: page,
                        flow: flow,
                        categories: try vault.listCategories(dateFrom: from, dateTo: to),
                        groups: try vault.listAccountGroups(),
                        userGroups: try vault.listUserGroups()
                    )
                }
                guard !Task.isCancelled, let self, self.vault === vault else { return }
                if generation == self.listGeneration {
                    self.dropPendingPage()
                    self.publish(r.page)
                }
                let (nowFrom, nowTo) = self.periodRange
                if nowFrom == from, nowTo == to {
                    if self.currentFilter.accountIds == filter.accountIds {
                        self.selectionFlow = (r.flow.consumptionCents, r.flow.investedCents, r.flow.incomeCents)
                    }
                    self.categories = r.categories
                    self.categoryTree = Self.buildTree(r.categories)
                }
                self.applyAccountGroups(r.groups, r.userGroups)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.errorMessage = describe(error)
                self.reloadAfterCategoryChange()
            }
        }
    }

    private struct CategoryRefresh: @unchecked Sendable {
        let page: BookingPage
        let flow: SelectionFlow
        let categories: [GiroCrabCore.Category]
        let groups: [AccountGroup]
        let userGroups: [UserGroup]
    }

    func setChecked(_ checked: Bool, for booking: Booking) {
        guard let vault else { return }
        run { try vault.setTransactionChecked(transactionId: booking.id, checked: checked) }
        // With "Neu" / "Geprüft" active the booking leaves the list: keep it in the inspector.
        if statusFilter != .all, selectedBookingID == booking.id { stickyBooking = freshBooking(booking) }
        reloadBookings(); reloadAccounts()
    }

    /// "Alle als gelesen markieren" (GitHub #236): everything new in the list as
    /// filtered now, or – with `accountIDs`, from a sidebar entry – in those
    /// accounts regardless of period, search and scope. One SQL update off the
    /// main thread; undoable via Bearbeiten › Widerrufen.
    /// The Buchung menu entry: nothing to do without new bookings, and not in
    /// Belege (there the list would silently mean every account).
    var canMarkAllChecked: Bool { vault != nil && newCount > 0 && sidebarSelection != .documents }

    func markAllChecked(accountIDs: [Int64]? = nil) {
        guard let vault else { return }
        if accountIDs == nil, sidebarSelection == .documents { return }
        var f = currentFilter
        if let accountIDs {
            f.accountIds = accountIDs; f.categoryId = nil; f.uncategorizedOnly = false
            f.search = nil; f.dateFrom = nil; f.dateTo = nil; f.direction = .all
            f.scope = .all; f.merchantKey = nil
        }
        f.checked = false; f.limit = 0; f.offset = 0; f.wholeDays = false
        let filter = f
        Task { [weak self] in
            do {
                let ids = try await Self.offMain { try vault.setCheckedForFilter(filter: filter, checked: true) }
                guard let self, self.vault === vault else { return }
                self.finishMarkChecked(ids)
            } catch {
                self?.errorMessage = describe(error)
            }
        }
    }

    private func finishMarkChecked(_ ids: [Int64]) {
        guard !ids.isEmpty else {
            toast = String(localized: "Keine neuen Umsätze")
            return
        }
        if let um = windowUndoManager {
            um.registerUndo(withTarget: self) { m in m.setChecked(ids, to: false) }
            um.setActionName(String(localized: "Alle als gelesen markieren"))
        }
        toast = String(localized: "\(ids.count) Umsätze als gelesen markiert")
        // With "Neu" / "Geprüft" active the bookings leave the list: keep the selected one in the inspector (like setChecked)
        if statusFilter != .all, let b = selectedBooking, ids.contains(b.id) { stickyBooking = freshBooking(b) }
        reloadBookings(); reloadAccounts()
    }

    /// Undo / redo of `markAllChecked` for exactly the bookings it changed.
    private func setChecked(_ ids: [Int64], to checked: Bool) {
        guard let vault else { return }
        do { try vault.setCheckedForIds(ids: ids, checked: checked) } catch { errorMessage = describe(error); return }
        if let um = windowUndoManager {
            um.registerUndo(withTarget: self) { m in m.setChecked(ids, to: !checked) }
            um.setActionName(String(localized: "Alle als gelesen markieren"))
        }
        reloadBookings(); reloadAccounts()
    }

    func updateText(counterparty: String, purpose: String, for booking: Booking) {
        guard let vault else { return }
        run { try vault.updateTransactionText(transactionId: booking.id, counterparty: counterparty, purpose: purpose) }
        reloadBookings(); reloadMerchantStats()
    }

    /// Select the booking and put the cursor into its note field in the inspector.
    func editNote(for booking: Booking) {
        #if os(macOS)
        // the note lives in the inspector: show it if it was hidden (the field claims the focus when it appears)
        UserDefaults.standard.set(true, forKey: ViewLayout.inspectorKey)
        #endif
        selectedBookingID = booking.id
        pendingNoteFocus = booking.id
    }

    func updateNote(_ note: String, for booking: Booking) {
        guard let vault else { return }
        run { try vault.updateTransactionNote(transactionId: booking.id, note: note) }
        reloadBookings()
    }

    func createCategory(name: String, parent: Int64?, symbol: String, color: String) {
        guard let vault else { return }
        run { _ = try vault.createCategory(name: name, parentId: parent, sfSymbol: symbol, colorHex: color) }
        reloadCategories()
    }

    /// Changes one property of a category and keeps the others (#168) –
    /// the core only updates a category as a whole.
    private func editCategory(_ id: Int64, _ change: (inout GiroCrabCore.Category) -> Void) {
        guard let vault, var c = categories.first(where: { $0.id == id }) else { return }
        change(&c)
        run {
            try vault.updateCategory(id: c.id, name: c.name, parentId: c.parentId,
                                     sfSymbol: c.sfSymbol, colorHex: c.colorHex)
        }
        reloadCategories()
        reloadBookings() // the booking list shows a category's name, symbol and colour
    }

    /// "Umbenennen …" of a category.
    func renameCategory(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editCategory(id) { $0.name = trimmed }
    }

    /// "Verschieben nach ▸" of a category: under another category, or to the
    /// top level (nil). The core refuses moving it below itself.
    func moveCategory(_ id: Int64, to parent: Int64?) {
        editCategory(id) { $0.parentId = parent }
        if let parent { expandedCategories.insert(parent) } // keep it in view
    }

    /// "Symbol & Farbe …" of a category.
    func setCategorySymbol(_ id: Int64, symbol: String) { editCategory(id) { $0.sfSymbol = symbol } }
    func setCategoryColor(_ id: Int64, hex: String) { editCategory(id) { $0.colorHex = hex } }

    /// Where a category can move: every category except itself and its own
    /// sub-categories.
    func categoryMoveTargets(for id: Int64) -> [GiroCrabCore.Category] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isOwnOrBelow(_ c: GiroCrabCore.Category) -> Bool {
            var cur: Int64? = c.id
            var steps = 0
            while let i = cur, steps < 64 {
                if i == id { return true }
                cur = byID[i]?.parentId
                steps += 1
            }
            return false
        }
        return categories.filter { !isOwnOrBelow($0) }
    }

    /// "Hauptkategorie › Unterkategorie" for a category id (nil = top level).
    func categoryPath(_ id: Int64?) -> String? {
        id.flatMap { id in categories.first { $0.id == id }?.path }
    }

    func deleteCategory(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteCategory(id: id) }
        if sidebarSelection == .category(id) { sidebarSelection = .allAccounts }
        reloadAll()
    }

    func newRuleDraft(from booking: Booking? = nil) -> Rule {
        Rule(
            id: 0,
            name: booking.map { "\($0.merchant.name)" } ?? String(localized: "Neue Regel"),
            categoryId: booking?.categoryId ?? categories.first(where: { $0.depth > 0 })?.id ?? categories.first?.id ?? 0,
            field: booking == nil ? .any : .counterparty,
            matchKind: .keyword,
            pattern: booking.map { $0.merchant.known ? $0.merchant.name : $0.counterparty.split(separator: " ").prefix(2).joined(separator: " ") } ?? "",
            caseSensitive: false,
            minAmountCents: nil,
            maxAmountCents: booking.map { $0.amountCents < 0 ? 0 : nil } ?? nil,
            accountId: nil,
            priority: Int32((rules.map(\.priority).max() ?? 0) + 10),
            enabled: true,
            matchCount: 0
        )
    }

    func openRuleEditor(from booking: Booking? = nil) {
        ruleDraft = booking.map { newRuleDraft(from: $0) }
        showRuleEditor = true
    }

    @discardableResult
    func saveRule(_ rule: Rule) -> Int64? {
        guard let vault else { return nil }
        do {
            let id = try vault.saveRule(rule: rule)
            _ = try vault.applyRules(onlyUncategorized: false)
            reloadAll()
            return id
        } catch {
            showError(String(localized: "Regel konnte nicht gespeichert werden"), describe(error))
            return nil
        }
    }

    func deleteRule(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteRule(ruleId: id) }
        reloadAll()
    }

    func preview(_ rule: Rule) -> (matches: [Booking], error: String?) {
        guard let vault else { return ([], nil) }
        do { return (try vault.previewRule(rule: rule, limit: 200), nil) } catch { return ([], describe(error)) }
    }

    func applyAllRules() {
        guard let vault else { return }
        run {
            let n = try vault.applyRules(onlyUncategorized: false)
            toast = String(localized: "Regeln angewendet – \(n) Buchungen neu zugeordnet")
        }
        reloadAll()
    }

    func saveSetting(_ key: String, _ value: String) {
        guard let vault else { return }
        run { try vault.setSetting(key: key, value: value) }
        reloadSettings()
    }

    /// Adds a bank login. While demo data is shown, the login goes into the
    /// personal vault (switching to it), then setup / PIN entry starts.
    func addConnection(_ kind: ConnectorKind, login: String) {
        withFreshBankingPolicy { [self] in
            guard Self.isMagicDemoLogin(login) || bankingAllowsAdding(bankingGate(forNew: kind)) else { return }
            addConnectionChecked(kind, login: login)
        }
    }

    private func addConnectionChecked(_ kind: ConnectorKind, login: String) {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addBankConnection(connector: kind, displayName: "", loginName: login) }
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// Adds a login at any FinTS 3.0 bank (BLZ + https URL), then starts setup / PIN entry.
    func addFinTsConnection(name: String, blz: String, url: String, login: String, tanMedium: String = "") {
        withFreshBankingPolicy { [self] in
            guard Self.isMagicDemoLogin(login) || bankingAllowsAdding(bankingGate(forNewFinTS: blz)) else { return }
            addFinTsConnectionChecked(name: name, blz: blz, url: url, login: login, tanMedium: tanMedium)
        }
    }

    private func addFinTsConnectionChecked(name: String, blz: String, url: String, login: String, tanMedium: String) {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addFintsConnection(blz: blz, url: url, displayName: name, loginName: login, tanMedium: tanMedium) }
        reloadSettings()
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// Adds a login at a bank reached via Enable Banking (PSD2), then starts the
    /// setup (Enable Banking credentials, if missing) and the consent redirect.
    func addEnableBankingConnection(aspsp: String, country: String, name: String, label: String) {
        withFreshBankingPolicy { [self] in
            guard Self.isMagicDemoLogin(label) || bankingAllowsAdding(bankingGate(forNew: .enableBanking)) else { return }
            addEnableBankingConnectionChecked(aspsp: aspsp, country: country, name: name, label: label)
        }
    }

    private func addEnableBankingConnectionChecked(aspsp: String, country: String, name: String, label: String) {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addEnableBankingConnection(aspsp: aspsp, country: country, displayName: name, loginName: label) }
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// All banks Enable Banking offers (`GET /aspsps`); empty until loaded or without credentials.
    var livePsd2Banks: [Psd2Bank] = []

    /// Enable Banking connections the last MoneyMoney import set up, with the
    /// accounts to link to the user's application – shown in the Enable
    /// Banking setup so they can be linked while activating it.
    var psd2LinkHints: [MoneyMoneyDbPsd2Connection] = []

    /// Loads the live ASPSP list when the user's Enable Banking credentials are set.
    func loadLivePsd2Banks() {
        guard let vault, livePsd2Banks.isEmpty, !isDemo,
              settingEntry("enablebanking.application_id")?.hasValue == true,
              settingEntry("enablebanking.private_key_pem")?.hasValue == true else { return }
        Task { [weak self] in
            let list = (try? await vault.listEnableBankingAspsps(country: "")) ?? []
            await MainActor.run { self?.livePsd2Banks = list }
        }
    }

    /// Setting keys a bank still needs (FinTS product ID, API keys …).
    func missingSettings(for connection: BankConnection) -> [String] {
        if Self.isMagicDemoLogin(connection.loginName) { return [] }
        guard let d = bankCatalog().first(where: { $0.kind == connection.connector }) else { return [] }
        return d.requiredSettings.filter { key in
            // A usable FinTS registration (GiroCrab's or the user's) satisfies this one.
            if key == "fints.product_id", !fintsProductIDSource.isEmpty { return false }
            return !(settings.first { $0.key == key }?.hasValue ?? false)
        }
    }

    /// "Mit … erneut versuchen" after a bank rejected the FinTS registration in use.
    /// The bank refused the FinTS product registration (9078, or 9010 as some banks answer).
    /// The core reports the FIRST code of the reply (often 9050 "Nachricht enthält Fehler"),
    /// so 9078/9010 are also looked for in the joined message.
    nonisolated static func isProductIDRejection(_ error: Error) -> Bool {
        guard let ce = error as? CoreError, case .Bank(let code, let message) = ce else { return false }
        let codes = ["9010", "9078"]
        return codes.contains(code) || codes.contains { message.contains($0) }
    }

    private func productIDAlternatives(for conn: BankConnection, error: Error, secret: String?) -> [(title: String, action: @MainActor () -> Void)] {
        guard Self.isProductIDRejection(error),
              bankCatalog().first(where: { $0.kind == conn.connector })?.requiredSettings.contains("fints.product_id") == true
        else { return [] }
        let hasOwn = settingEntry("fints.product_id")?.hasValue == true
        var out: [(title: String, action: @MainActor () -> Void)] = []
        switch fintsProductIDSource {
        case "builtin":
            // GiroCrab's registration was refused: the own one goes into Settings (no extra
            // field here), then the account is fetched again by hand.
            out.append((hasOwn ? String(localized: "Eigene Registrierung ersetzen …") : String(localized: "Eigene Registrierung eintragen …"),
                        { [weak self] in self?.enterOwnProductID() }))
        case "own":
            // The own registration is wrong: replace it, or use GiroCrab's instead.
            out.append((String(localized: "Eigene Registrierung ersetzen …"), { [weak self] in self?.enterOwnProductID() }))
            if fintsBuiltinAvailable {
                out.append((String(localized: "Mit GiroCrab-Registrierung erneut versuchen"), { [weak self] in
                    self?.setFintsProductIDMode("builtin")
                    guard let self, let c = self.connections.first(where: { $0.id == conn.id }) else { return }
                    // Same login and PIN as the failed attempt: only the registration changes.
                    if let secret, !secret.isEmpty, self.bankingGate(for: c) == nil {
                        self.startSync(c, secret: secret)
                    } else {
                        self.requestSync(c)
                    }
                }))
            }
        default: break
        }
        return out
    }

    /// After a rejected registration: switch to the own one, open Settings › FinTS & API keys
    /// and put the cursor into its field (no extra field in the alert).
    func enterOwnProductID() {
        setFintsProductIDMode("own")
        focusOwnProductID = true
        openSettings(.credentials)
    }

    func settingEntry(_ key: String) -> SettingEntry? { settings.first { $0.key == key } }

    /// Saves the setup form and continues with the sync.
    func completeSetup(_ request: SetupRequest, values: [String: String]) {
        for (k, v) in values where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            saveSetting(k, v)
        }
        setupRequest = nil
        let still = missingSettings(for: request.connection)
        if still.isEmpty {
            requestSync(request.connection)
        } else {
            setupRequest = SetupRequest(connection: request.connection, keys: still)
        }
    }

    func holdings(for accountID: Int64) -> [Holding] {
        (try? vault?.listHoldings(accountId: accountID)) ?? []
    }

    /// Archives ("Das Konto wurde aufgelöst") or reactivates an account. Archived accounts keep
    /// everything, but are skipped by syncs and rule runs and leave the overall total.
    func setAccountArchived(_ account: Account, _ archived: Bool) {
        guard let vault else { return }
        run {
            try vault.setAccountArchived(accountId: account.id, archived: archived)
            toast = archived
                ? String(localized: "„\(account.name)“ archiviert")
                : String(localized: "„\(account.name)“ reaktiviert")
        }
        reloadAll()
    }

    /// Deletes one archived account incl. bookings/documents/holdings (and its connection if it was the last account).
    func deleteAccount(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteAccount(accountId: id) }
        if sidebarSelection == .account(id) { sidebarSelection = .allAccounts }
        reloadAll()
    }

    func removeConnection(_ id: Int64) {
        guard let vault else { return }
        // Trade Republic: also drop the browser session (tr_session, tr_refresh, website data).
        if connections.first(where: { $0.id == id })?.connector == .tradeRepublic {
            Task { await WebLoginSheet.clearAllTradeRepublicWebData() }
        }
        run { try vault.deleteBankConnection(connectionId: id) }
        reloadAll()
    }

    // MARK: - Sync (two-phase)

    // MARK: - Belege & PostBox

    var documentsVersion = 0
    /// Account whose statements (HKEKA) are being fetched by the running session.
    var statementsAccountID: Int64?
    private var statementsCountBefore = 0

    func accountDocuments(_ accountID: Int64) -> [DocumentInfo] {
        _ = documentsVersion
        let f = DocumentFilter(accountId: accountID, docType: nil, search: nil, unlinkedOnly: false)
        return (try? vault?.listAllDocuments(filter: f)) ?? []
    }

    func canFetchStatements(_ account: Account) -> Bool {
        guard let c = account.connector, account.kind != .loan else { return false }
        return [.volksbankKasselGoettingen, .direkt1822, .finTsGeneric].contains(c)
    }

    /// Explicit "Kontoauszüge abrufen": regular syncs never fetch statements (speed, no extra TAN).
    func fetchStatements(for account: Account) {
        guard syncingConnectionID == nil,
              let cid = account.connectionId,
              let connection = connections.first(where: { $0.id == cid }) else { return }
        statementsAccountID = account.id
        statementsCountBefore = accountDocuments(account.id).count
        requestSync(connection)
    }

    /// Decrypted copy shown in QuickLook; removed again as soon as the
    /// preview closes or shows another document (and on lock / quit).
    var quickLookURL: URL? {
        didSet {
            if let old = oldValue, old != quickLookURL { try? FileManager.default.removeItem(at: old) }
        }
    }

    /// Private folder (0700) for the decrypted QuickLook copies.
    nonisolated static var quickLookDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-QuickLook", isDirectory: true)
    }

    /// Deletes every decrypted QuickLook copy (lock, quit, next launch).
    public nonisolated static func removeQuickLookFiles() {
        try? FileManager.default.removeItem(at: quickLookDirectory)
    }

    /// Quit: the decrypted copies go too (launch cleans up after a crash). Both
    /// entry points (SwiftPM and Xcode target) share this, so it lives here.
    private static let quickLookCleanupObserver: NSObjectProtocol = {
        #if os(macOS)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.willTerminateNotification
        #endif
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            AppModel.removeQuickLookFiles()
        }
    }()

    /// Creates the QuickLook folder owner-only; refuses a symlink or a
    /// folder of another user in its place.
    private nonisolated static func preparedQuickLookDirectory() -> URL? {
        let fm = FileManager.default
        let dir = quickLookDirectory
        var st = Darwin.stat()
        if lstat(dir.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return nil }
            if st.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
            return dir
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            return nil
        }
    }

    func documents(for booking: Booking) -> [DocumentInfo] {
        _ = documentsVersion
        return (try? vault?.listDocumentsForBooking(bookingId: booking.id)) ?? []
    }

    func allDocuments(search: String = "", unlinkedOnly: Bool = false, accountId: Int64? = nil) -> [DocumentInfo] {
        _ = documentsVersion
        let f = DocumentFilter(accountId: accountId, docType: nil, search: search.isEmpty ? nil : search, unlinkedOnly: unlinkedOnly)
        return (try? vault?.listAllDocuments(filter: f)) ?? []
    }

    func documentData(_ doc: DocumentInfo) -> Data? {
        try? vault?.getDocumentBytes(docId: doc.id)
    }

    private func documentsChanged() {
        documentsVersion += 1
        reloadBookings()
    }

    /// Dropped onto a booking row / the inspector drop zone.
    func attach(_ urls: [URL], to booking: Booking) {
        guard let vault else { return }
        var n = 0
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            run { _ = try vault.attachDocumentToBooking(bookingId: booking.id, fileName: url.lastPathComponent, bytes: data); n += 1 }
        }
        if n > 0 { toast = String(localized: "\(n) Belege an „\(booking.merchantName)“ angehängt") }
        documentsChanged()
    }

    /// Dropped anywhere: Rust matches amount/date/merchant (with PDFKit/Vision text as hint).
    func dropAnywhere(_ urls: [URL]) {
        guard let vault else { return }
        Task {
            var linked: [String] = []
            var unmatched = 0
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let text = await ReceiptText.extract(data: data, fileName: url.lastPathComponent)
                do {
                    if let hit = try vault.autoMatchDocument(fileName: url.lastPathComponent, bytes: data, textHint: text) {
                        linked.append(hit)
                    } else {
                        unmatched += 1
                    }
                } catch {
                    showError(String(localized: "Beleg konnte nicht zugeordnet werden"), describe(error))
                }
            }
            if !linked.isEmpty {
                toast = String(localized: "Beleg zugeordnet: \(linked.joined(separator: ", "))")
            } else if unmatched > 0 {
                toast = String(localized: "Kein passender Umsatz gefunden – in „Belege & PostBox“ abgelegt")
            }
            documentsChanged()
        }
    }

    func deleteDocument(_ doc: DocumentInfo) {
        guard let vault else { return }
        run { try vault.deleteDocument(docId: doc.id) }
        documentsChanged()
    }

    func linkDocument(_ doc: DocumentInfo, to booking: Booking?) {
        guard let vault else { return }
        run { try vault.linkDocument(docId: doc.id, bookingId: booking?.id) }
        documentsChanged()
    }

    /// Writes the document to a temp file and shows it in QuickLook.
    func quickLook(_ doc: DocumentInfo) {
        guard let data = documentData(doc) else { return }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/heic": "heic"][doc.mimeType] ?? "pdf"
        _ = Self.quickLookCleanupObserver
        guard let dir = Self.preparedQuickLookDirectory() else { return }
        let url = dir.appendingPathComponent("GiroCrab-Beleg-\(doc.id).\(ext)")
        // Owner-only from the first byte: O_EXCL + O_NOFOLLOW, mode 0600.
        try? FileManager.default.removeItem(at: url)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        Darwin.close(fd)
        guard written else { try? FileManager.default.removeItem(at: url); return }
        quickLookURL = url
    }

    func exportAllDocuments(to folder: URL) {
        guard let vault else { return }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        run {
            let n = try vault.exportAllDocuments(destDir: folder.path)
            toast = String(localized: "\(n) Belege nach „\(folder.lastPathComponent)/GiroCrab-Belege“ exportiert")
        }
    }

    func connectionStatus(_ id: Int64) -> ConnectionStatus? {
        try? vault?.connectionStatus(connectionId: id)
    }

    func updateConnection(_ id: Int64, name: String, login: String) {
        guard let vault else { return }
        run { try vault.updateBankConnection(connectionId: id, displayName: name, loginName: login) }
        reloadAccounts()
    }

    func setConnectionPin(_ id: Int64, _ pin: String?) {
        guard let vault else { return }
        run { try vault.setConnectionPin(connectionId: id, pin: pin) }
    }

    func clearSession(_ id: Int64) {
        guard let vault else { return }
        run { try vault.clearConnectionSession(connectionId: id) }
        toast = String(localized: "Sitzung gelöscht")
    }

    func revealSetting(_ key: String) -> String {
        ((try? vault?.getSetting(key: key)) ?? nil) ?? ""
    }

    /// Cookies from the in-app browser login -> vault -> sync without 2FA.
    func applyBrowserSession(_ connection: BankConnection, cookies: String) {
        guard let vault else { return }
        webLoginConnection = nil
        do {
            try vault.setConnectionSession(connectionId: connection.id, cookies: cookies)
            toast = String(localized: "Trade-Republic-Sitzung übernommen")
            startSync(connection, secret: "")
        } catch {
            resetSyncBatch()   // like any sync error: ends "Alle abrufen" instead of stalling it
            showError(String(localized: "Anmeldung konnte nicht übernommen werden"), describe(error))
        }
    }

    /// Starts a sync (or the login it needs) once the banking policy is fresh
    /// and allows this login; otherwise explains why not.
    func requestSync(_ connection: BankConnection) {
        withFreshBankingPolicy { [self] in
            if let gate = bankingGate(for: connection) {
                statementsAccountID = nil
                if syncBatchTotal > 1, !gate.all {
                    // A lock published while "Alle abrufen" runs: skip this
                    // login, go on with the rest, name it in the closing notice.
                    syncBatchSkipped.append(String(localized: "\(connection.displayName) (Sicherheitssperre)"))
                    syncNextInQueue()
                } else {
                    resetSyncBatch()
                    showError(gate.title, gate.detail)
                }
                return
            }
            requestSyncChecked(connection)
        }
    }

    private func requestSyncChecked(_ connection: BankConnection) {
        // Amex / Amazon Visa: embedded web-portal login (no API keys needed).
        if usesPortal(connection) {
            webLoginConnection = connection
            return
        }
        // Trade Republic: AWS WAF blocks raw logins – without a stored
        // session the in-app browser login is the default flow.
        let magicDemo = Self.isMagicDemoLogin(connection.loginName)
        if !isDemo, !magicDemo, connection.connector == .tradeRepublic, !(connectionStatus(connection.id)?.hasSession ?? false) {
            webLoginConnection = connection
            return
        }
        if !isDemo, let st = connectionStatus(connection.id), (st.hasPin || (connection.connector == .tradeRepublic && st.hasSession)),
           missingSettings(for: connection).isEmpty {
            startSync(connection, secret: "")
            return
        }
        if !isDemo {
            let missing = missingSettings(for: connection)
            if !missing.isEmpty {
                setupRequest = SetupRequest(connection: connection, keys: missing)
                return
            }
        }
        let needsSecret = !(bankCatalog().first { $0.kind == connection.connector }?.secretLabel.hasPrefix("(") ?? false)
        if isDemo || !needsSecret {
            startSync(connection, secret: isDemo ? "demo" : "")
        } else {
            pendingLogin = PendingLogin(connection: connection)
        }
    }

    func requestSyncAll() {
        // portal connections need an interactive login – not part of "sync all"
        // logins whose accounts are all archived are not asked at all
        requestSyncBatch { [self] in connections.filter { !usesPortal($0) && !$0.allAccountsArchived } }
    }

    /// "Konten abrufen" in a group's menu: the logins behind the group's
    /// accounts, subgroups included, each once – as "Alle abrufen" would.
    func groupSyncConnections(_ group: UserGroup) -> [BankConnection] {
        let ids = Set(userGroupSubtree(group.uuid).flatMap(\.accounts)
            .filter { !$0.isArchived }.compactMap(\.connectionId))
        return connections.filter { ids.contains($0.id) && !usesPortal($0) }
    }

    func requestSyncGroup(_ group: UserGroup) {
        requestSyncBatch { [self] in groupSyncConnections(group) }
    }

    /// What a pull-to-refresh starts besides the iCloud merge.
    enum RefreshSyncAction: Equatable {
        case none
        case connection(Int64)
        case group(String)
        case all
    }

    /// Context-aware bank sync of the current sidebar selection. Import-only
    /// and portal accounts (interactive login) need no bank sync: the iCloud
    /// merge and reload cover them.
    func refreshSyncAction() -> RefreshSyncAction {
        switch sidebarSelection {
        case .account(let id):
            guard let cid = allAccounts.first(where: { $0.id == id })?.connectionId,
                  let c = connections.first(where: { $0.id == cid }),
                  !usesPortal(c), !c.allAccountsArchived else { return .none }
            return .connection(cid)
        case .userGroup(let uuid) where !uuid.isEmpty:
            return .group(uuid)
        case .documents:
            return .none
        default:
            return .all
        }
    }

    /// Hook for tests: runs the action's sync instead of the real one.
    @ObservationIgnored var refreshSyncOverride: ((RefreshSyncAction) -> Void)?

    /// Pull-to-refresh: merges the iCloud snapshots first (bookings synced on
    /// the Mac), then syncs what the current selection shows. Returns when the
    /// work is done, so the native spinner stays up. While a sync runs it only
    /// waits for it instead of starting a second one.
    func refreshCurrentView() async {
        if let v = ownVault, CloudSyncManager.shared.isEnabled {
            await CloudSyncManager.shared.sync(vault: v)
            reloadAll()
        }
        guard syncingConnectionID == nil else {
            await awaitSyncSettled()
            return
        }
        let action = refreshSyncAction()
        guard action != .none else { return }
        if let hook = refreshSyncOverride { hook(action); return }
        switch action {
        case .none: return
        case .connection(let id):
            guard let c = connections.first(where: { $0.id == id }) else { return }
            requestSync(c)
        case .group(let uuid):
            guard let g = userGroups.first(where: { $0.uuid == uuid }) else { return }
            requestSyncGroup(g)
        case .all:
            requestSyncAll()
        }
        await awaitSyncSettled()
    }

    /// Waits until the running sync (batch included) is over, or stops at a
    /// PIN / TAN / setup prompt, which only the user can answer.
    private func awaitSyncSettled() async {
        var waited = 0
        // the banking policy check may delay the start a moment
        try? await Task.sleep(for: .milliseconds(150))
        while !Task.isCancelled, waited < 600 {
            let prompting = pendingLogin != nil || setupRequest != nil || webLoginConnection != nil || activeChallenge != nil
            if prompting || (syncingConnectionID == nil && syncQueue.isEmpty) { return }
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
    }

    /// Runs `logins` one after another; read once the banking policy is fresh.
    private func requestSyncBatch(_ logins: @escaping @MainActor () -> [BankConnection]) {
        guard syncingConnectionID == nil else { return }
        withFreshBankingPolicy { [self] in
            guard syncingConnectionID == nil else { return }
            let batch = logins()
            // Logins the banking policy blocks are skipped and named at the end.
            let blocked = batch.filter { bankingGate(for: $0) != nil }
            let allowed = batch.filter { bankingGate(for: $0) == nil }
            guard let head = allowed.first else {
                if let gate = blocked.first.flatMap({ bankingGate(for: $0) }) {
                    showError(gate.title, gate.detail)
                }
                return
            }
            syncQueue = Array(allowed.dropFirst())
            syncBatchTotal = allowed.count
            syncBatchSkipped = blocked.map { String(localized: "\($0.displayName) (Sicherheitssperre)") }
            requestSyncChecked(head)
        }
    }

    /// Position in a running "Alle abrufen" over several logins, e.g. (2, 5).
    var syncBatchProgress: (current: Int, total: Int)? {
        guard syncBatchTotal > 1 else { return nil }
        return (syncBatchTotal - syncQueue.count, syncBatchTotal)
    }

    /// More logins wait after the current one: cancelling a PIN or TAN
    /// prompt then skips this login instead of stopping the whole batch.
    var canSkipInSyncBatch: Bool { !syncQueue.isEmpty }

    /// Cancel button of the TAN sheet. In a batch it drops this login and goes
    /// on with the next one (on the last one it ends the batch with its notice).
    func skipCurrentSync() {
        guard syncBatchTotal > 1, activeTransfer == nil else { cancelSync(); return }
        if let name = activeChallenge?.connection.displayName
            ?? connections.first(where: { $0.id == syncingConnectionID })?.displayName {
            syncBatchSkipped.append(name)
        }
        pollTask?.cancel()
        let s = activeSession
        activeSession = nil
        activeChallenge = nil
        statementsAccountID = nil
        syncGeneration &+= 1
        let generation = syncGeneration
        Task {
            // end the bank dialog first: the next login may be the same bank.
            // syncingConnectionID stays set until then, so neither a scheduled
            // sync nor a new "Alle abrufen" can start in between.
            await s?.cancel()
            // "Alle abbrechen", a lock or a new sync meanwhile own the state now:
            // never end a session this skip did not start.
            guard self.syncGeneration == generation else { return }
            self.syncingConnectionID = nil
            self.syncNextInQueue()
        }
    }

    /// "Alle abbrechen": ends the running sync and closes whichever prompt of
    /// the batch is open (PIN, setup, browser login, TAN).
    func cancelAllSync() {
        setupRequest = nil
        webLoginConnection = nil   // in a batch only the Trade Republic login
        cancelSync()
    }

    /// "Abbrechen" / "Überspringen" in the PIN sheet.
    func cancelPendingLogin() {
        let c = pendingLogin?.connection
        pendingLogin = nil
        skipPrompt(for: c)
    }

    /// "Abbrechen" / "Überspringen" in the setup sheet (missing settings).
    func cancelSetupRequest() {
        let c = setupRequest?.connection
        setupRequest = nil
        skipPrompt(for: c)
    }

    /// "Abbrechen" / "Überspringen" in the Trade Republic browser login.
    func cancelWebLogin() {
        let c = webLoginConnection
        webLoginConnection = nil
        skipPrompt(for: c)
    }

    /// A prompt before the bank dialog (PIN, setup, browser login) was
    /// cancelled: in a batch go on with the next login, otherwise end it –
    /// a stale queue would otherwise resume after a later single sync.
    private func skipPrompt(for connection: BankConnection?) {
        // A cancelled "Kontoauszüge abrufen" must never carry over to the next
        // sync – it would send that login's PIN for another bank's account.
        statementsAccountID = nil
        guard syncBatchTotal > 1 else { resetSyncBatch(); return }
        if let name = connection?.displayName { syncBatchSkipped.append(name) }
        syncNextInQueue()
    }

    private func resetSyncBatch() {
        syncQueue = []
        syncBatchTotal = 0
        syncBatchSkipped = []
    }

    /// Toast suffix: new bookings the bank delivered for archived accounts (not stored).
    static func skippedArchivedNote(_ s: SyncSummary) -> String {
        s.transactionsSkippedArchived == 0 ? "" : " · " + String(localized: "\(s.transactionsSkippedArchived) Buchungen archivierter Konten übersprungen")
    }

    /// Locale of the UI language (Settings › Allgemein › Sprache), which can
    /// differ from the system's – e.g. "und" vs. "and" in a list. Builds
    /// without the translations (`swift run`) fall back to the system locale.
    private static var uiLocale: Locale {
        LanguagePreference.isAvailable ? Locale(identifier: LanguagePreference.runningLanguage) : .current
    }

    private func syncNextInQueue() {
        guard syncQueue.isEmpty else {
            requestSync(syncQueue.removeFirst())
            return
        }
        // batch done: name what was skipped, after the last login's own notice
        if !syncBatchSkipped.isEmpty {
            let note = String(localized: "Übersprungen: \(syncBatchSkipped.formatted(.list(type: .and).locale(Self.uiLocale)))")
            toast = toast.map { $0 + " · " + note } ?? note
            // the notice disappears after a few seconds: VoiceOver reads it out
            AccessibilityNotification.Announcement(note).post()
        }
        resetSyncBatch()
    }

    func startSync(_ connection: BankConnection, secret: String) {
        guard let vault else { return }
        if usesPortal(connection) { webLoginConnection = connection; return }
        pendingLogin = nil
        // Statements only for an account of exactly this login: a stale value
        // would hand this login's PIN to another bank.
        if let accountID = statementsAccountID,
           allAccounts.first(where: { $0.id == accountID })?.connectionId != connection.id
            || quietSyncConnectionID == connection.id {
            statementsAccountID = nil
        }
        let statementsFor = statementsAccountID
        syncingConnectionID = connection.id
        syncGeneration &+= 1
        Task {
            var started: SyncSession?
            do {
                let session: SyncSession
                if let accountID = statementsFor {
                    session = try vault.fetchAccountStatements(accountId: accountID, secret: secret, demo: isDemo)
                } else {
                    session = try vault.beginSync(connectionId: connection.id, secret: secret, demo: isDemo)
                }
                started = session
                self.activeSession = session
                let step = try await session.start()
                guard self.activeSession === session else { return }  // skipped / cancelled meanwhile
                self.handle(step, connection: connection)
            } catch {
                if let started, self.activeSession !== started { return }
                // Kept for the "use GiroCrab's registration" retry of a rejected product ID,
                // so the login is not asked again; finishSync takes it and clears it.
                if statementsFor == nil { self.failedSyncSecret = secret }
                self.finishSync(error: error)
            }
        }
    }

    private func handle(_ step: SyncStep, connection: BankConnection) {
        // A scheduled sync never asks for a login: the bank wants a new
        // consent, so stop quietly – the connection view shows it.
        if quietSyncConnectionID == connection.id {
            switch step {
            case .needsChallenge, .stillWaiting:
                quietSyncConnectionID = nil
                let s = activeSession
                activeSession = nil
                syncingConnectionID = nil
                Task { await s?.cancel() }
                checkConsentExpiry()
                return
            case .finished:
                break
            }
        }
        switch step {
        case .needsChallenge(let c):
            activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: false)
            if c.kind == .decoupledPush { schedulePoll(connection: connection, interval: c.pollIntervalSeconds) }
        case .stillWaiting(let c):
            if activeChallenge == nil {
                activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: true)
            } else {
                activeChallenge?.waiting = true
                activeChallenge?.busy = false
            }
            schedulePoll(connection: connection, interval: c.pollIntervalSeconds)
        case .finished(let s):
            activeChallenge = nil
            syncingConnectionID = nil
            activeSession = nil
            if let accountID = statementsAccountID {
                statementsAccountID = nil
                documentsVersion += 1
                let n = max(0, accountDocuments(accountID).count - statementsCountBefore)
                toast = String(localized: "\(connection.displayName): \(n) neue Kontoauszüge")
            } else {
                let quiet = quietSyncConnectionID == connection.id
                // scheduled syncs only speak up when something changed
                if !quiet || s.transactionsImported > 0 || !s.newAccounts.isEmpty || !s.revokedAccounts.isEmpty {
                    toast = syncNotice(connection, s) + Self.skippedArchivedNote(s)
                }
            }
            quietSyncConnectionID = nil
            reloadAll()
            syncNextInQueue()
        }
    }

    fileprivate func schedulePoll(connection: BankConnection, interval: UInt32) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(interval, 1)) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if let transfer = self.activeTransfer {
                do {
                    let step = try await transfer.poll()
                    guard self.activeTransfer === transfer else { return }  // cancelled meanwhile
                    self.handleTransfer(step, connection: connection)
                } catch {
                    guard self.activeTransfer === transfer else { return }
                    self.finishTransfer(error: error)
                }
                return
            }
            guard let session = self.activeSession else { return }
            do {
                let step = try await session.poll()
                guard self.activeSession === session else { return }  // skipped / cancelled meanwhile
                self.handle(step, connection: connection)
            } catch {
                guard self.activeSession === session else { return }
                self.finishSync(error: error)
            }
        }
    }

    func submitCode(_ code: String) {
        if let transfer = activeTransfer, let ch = activeChallenge {
            activeChallenge?.busy = true
            activeChallenge?.error = nil
            Task {
                do {
                    let step = try await transfer.submitCode(code: code)
                    // cancelled while the TAN was on its way: the cancel notice owns the sheet
                    guard self.activeTransfer === transfer else { return }
                    self.handleTransfer(step, connection: ch.connection)
                } catch {
                    guard self.activeTransfer === transfer else { return }
                    self.finishTransfer(error: error)
                }
            }
            return
        }
        guard let session = activeSession, let ch = activeChallenge else { return }
        activeChallenge?.busy = true
        activeChallenge?.error = nil
        Task {
            do {
                let step = try await session.submitCode(code: code)
                // "Überspringen" while the code was on its way: drop the late answer
                guard self.activeSession === session else { return }
                self.handle(step, connection: ch.connection)
            } catch {
                guard self.activeSession === session else { return }
                self.finishSync(error: error)
            }
        }
    }

    func cancelSync() {
        pollTask?.cancel()
        if let t = activeTransfer {
            activeTransfer = nil
            activeChallenge = nil
            transferBusy = false
            transferError = String(localized: "Überweisung abgebrochen – es wurde nichts gesendet, solange die TAN nicht bestätigt wurde.")
            showTransferSheet = true
            Task { await t.cancel() }
            return
        }
        let s = activeSession
        activeSession = nil
        activeChallenge = nil
        pendingLogin = nil
        syncingConnectionID = nil
        statementsAccountID = nil
        syncGeneration &+= 1
        resetSyncBatch()
        Task { await s?.cancel() }
    }

    private var syncingConnectionIDBeforeError: Int64?
    /// PIN of the sync that just failed (memory only, cleared in `finishSync`).
    private var failedSyncSecret: String?

    private func finishSync(error: Error) {
        let retrySecret = failedSyncSecret
        failedSyncSecret = nil
        if let quietID = quietSyncConnectionID {
            // scheduled sync: a notice instead of dialogs / login prompts
            quietSyncConnectionID = nil
            pollTask?.cancel()
            activeSession = nil
            activeChallenge = nil
            syncingConnectionID = nil
            let name = connections.first { $0.id == quietID }?.displayName ?? ""
            toast = String(localized: "\(name): automatischer Abruf fehlgeschlagen – \(describe(error))")
            return
        }
        statementsAccountID = nil
        syncingConnectionIDBeforeError = syncingConnectionID
        pollTask?.cancel()
        activeSession = nil
        activeChallenge = nil
        syncingConnectionID = nil
        resetSyncBatch()
        if let ce = error as? CoreError, case .BrowserLoginRequired(let m) = ce,
           let conn = connections.first(where: { $0.id == syncingConnectionIDBeforeError }) {
            toast = m
            webLoginConnection = conn
            return
        }
        if let ce = error as? CoreError, case .MissingSetting(let key) = ce,
           let conn = connections.first(where: { $0.id == syncingConnectionIDBeforeError }) {
            var keys = missingSettings(for: conn)
            if !keys.contains(key) { keys.insert(key, at: 0) }
            setupRequest = SetupRequest(connection: conn, keys: keys)
            return
        }
        if let conn = connections.first(where: { $0.id == syncingConnectionIDBeforeError }) {
            showError(String(localized: "Abruf von „\(conn.displayName)“ fehlgeschlagen"), describe(error)) { [weak self] in
                guard let self, let c = self.connections.first(where: { $0.id == conn.id }) else { return }
                self.requestSync(c)
            }
            errorAlternatives = productIDAlternatives(for: conn, error: error, secret: retrySecret)
        } else {
            showError(String(localized: "Abruf fehlgeschlagen"), describe(error))
        }
    }
}

// MARK: - SEPA-Überweisung

extension AppModel {
    /// Checking accounts that are connected via FinTS (HKCCS-capable banks).
    var transferAccounts: [Account] {
        allAccounts.filter {
            $0.kind == .checking && !$0.iban.isEmpty && !$0.isArchived
                && [.volksbankKasselGoettingen, .direkt1822, .finTsGeneric, .bunq].contains($0.connector)
        }
    }

    /// Checking accounts GiroCrab cannot send from (e.g. C24 via Enable Banking,
    /// which is read-only): the transfer form ends with a GiroCode to scan in
    /// the bank's app instead of a TAN.
    var giroCodeAccounts: [Account] {
        let sending = Set(transferAccounts.map(\.id))
        // Archived accounts are out of the form entirely (like transferAccounts);
        // otherwise an archived FinTS account would fall through to here.
        return allAccounts.filter {
            $0.kind == .checking && !$0.iban.isEmpty && !$0.isArchived && !sending.contains($0.id)
        }
    }

    /// Accounts offered in the transfer form: sending ones first.
    var transferFormAccounts: [Account] { transferAccounts + giroCodeAccounts }

    func canSendTransfer(from accountID: Int64?) -> Bool {
        transferAccounts.contains { $0.id == accountID } && bankingGate(forAccount: accountID) == nil
    }

    var canTransfer: Bool { vault != nil && !transferFormAccounts.isEmpty && syncingConnectionID == nil && activeTransfer == nil }

    /// Pre-selects the sidebar account if it is offered in the form, else the first one.
    func openTransfer() {
        guard canTransfer else { return }
        let offered = transferFormAccounts
        var selected: Int64?
        if case .account(let id) = sidebarSelection, offered.contains(where: { $0.id == id }) { selected = id }
        if transferDraft.accountID == nil || !offered.contains(where: { $0.id == transferDraft.accountID }) {
            transferDraft.accountID = selected ?? offered.first?.id
        } else if let selected {
            transferDraft.accountID = selected
        }
        transferError = nil
        transferInstantDeclined = nil
        showTransferSheet = true
    }

    /// After an instant transfer was declined (nothing sent): send the same
    /// draft as a regular SEPA transfer. A new order with its own approval,
    /// only ever started by the user.
    func sendAsRegularTransfer() {
        transferInstantDeclined = nil
        transferDraft.instant = false
        startTransfer()
    }

    /// Context menu: new transfer pre-filled from a booking.
    func openTransfer(from b: Booking) {
        guard canTransfer else { return }
        transferDraft.name = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        transferDraft.iban = TransferSheetView.groupedIBAN(b.counterpartyIban)
        transferDraft.bic = ""
        transferDraft.amountText = Money.plain(abs(b.amountCents))
        transferDraft.purpose = String(b.purpose.prefix(140))
        openTransfer()
    }

    func suggestRecipients(_ query: String) -> [KnownRecipient] {
        (try? vault?.suggestRecipients(query: query, limit: 6)) ?? []
    }

    func startTransfer() {
        withFreshBankingPolicy { [self] in
            if let gate = bankingGate(forAccount: transferDraft.accountID) {
                transferError = gate.message
                return
            }
            startTransferChecked()
        }
    }

    private func startTransferChecked() {
        guard let vault, let accID = transferDraft.accountID, canSendTransfer(from: accID),
              let account = allAccounts.first(where: { $0.id == accID }),
              let connection = connections.first(where: { $0.id == account.connectionId }) else { return }
        do {
            let cents = try parseAmountToCents(text: transferDraft.amountText)
            let bic = transferDraft.bic.trimmingCharacters(in: .whitespaces)
            // Instant and scheduled transfers are FinTS-only.
            let offersInstant = account.connector?.offersInstantChoice ?? false
            let request = SepaTransferRequest(
                accountId: accID,
                recipientName: transferDraft.name,
                recipientIban: transferDraft.iban,
                recipientBic: bic.isEmpty ? nil : bic,
                amountCents: cents,
                purpose: transferDraft.purpose,
                instant: transferDraft.instant && offersInstant,
                executionDate: offersInstant ? transferDraft.executionDateISO : nil)
            let stored = connectionStatus(connection.id)?.hasPin ?? false
            if !isDemo && !stored && transferDraft.pin.isEmpty {
                transferError = String(localized: "Bitte die Banking-PIN eingeben.")
                return
            }
            let session = try vault.beginTransfer(request: request, secret: isDemo ? "demo" : transferDraft.pin, demo: isDemo)
            transferError = nil
            transferInstantDeclined = nil
            transferBusy = true
            showTransferSheet = false
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

    fileprivate func handleTransfer(_ step: TransferStep, connection: BankConnection) {
        if case .needsPayeeConfirmation = step {} else { payeeCheck = nil }
        switch step {
        case .needsPayeeConfirmation(let check):
            pollTask?.cancel()
            activeChallenge = nil
            payeeCheck = PendingPayeeCheck(connection: connection, check: check)
        case .needsChallenge(let c):
            activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: false)
            if c.kind == .decoupledPush { schedulePoll(connection: connection, interval: c.pollIntervalSeconds) }
        case .stillWaiting(let c):
            if activeChallenge == nil {
                activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: true)
            } else {
                activeChallenge?.waiting = true
                activeChallenge?.busy = false
            }
            schedulePoll(connection: connection, interval: c.pollIntervalSeconds)
        case .finished(let outcome):
            pollTask?.cancel()
            activeChallenge = nil
            activeTransfer = nil
            transferBusy = false
            transferDraft = TransferDraft(accountID: transferDraft.accountID, instant: false)
            if outcome.instant {
                toast = String(localized: "Echtzeitüberweisung freigegeben und vorgemerkt")
            } else {
                toast = String(localized: "Überweisung freigegeben und vorgemerkt")
            }
            reloadAll()
        case .instantDeclined(let reason):
            // Nothing was sent. Keep the draft and let the user decide.
            pollTask?.cancel()
            activeChallenge = nil
            activeTransfer = nil
            transferBusy = false
            transferError = nil
            transferInstantDeclined = reason
            showTransferSheet = true
        case .outcomeUnknown(let reason, let endToEndId):
            // May have been executed: no retry button, clear the draft so it
            // cannot be resent with one click, and say so clearly.
            pollTask?.cancel()
            activeChallenge = nil
            activeTransfer = nil
            transferBusy = false
            transferDraft = TransferDraft(accountID: transferDraft.accountID, instant: false)
            transferUnknown = TransferUnknownNotice(reason: reason, endToEndId: endToEndId)
            reloadAll()
        }
    }

    /// Name check: send anyway (the bank then asks for the approval).
    func confirmPayee() {
        guard let transfer = activeTransfer, let pending = payeeCheck else { return }
        payeeCheck?.busy = true
        Task {
            do {
                let step = try await transfer.confirmPayee()
                guard self.activeTransfer === transfer else { return }  // cancelled meanwhile
                self.handleTransfer(step, connection: pending.connection)
            } catch {
                guard self.activeTransfer === transfer else { return }
                self.finishTransfer(error: error)
            }
        }
    }

    /// Name check: do not send. `useBankName` takes over the account
    /// holder's name reported by the bank and reopens the form.
    func cancelPayee(useBankName: Bool = false) {
        guard let pending = payeeCheck else { return }
        let transfer = activeTransfer
        payeeCheck = nil
        activeTransfer = nil
        transferBusy = false
        if useBankName, let name = pending.check.bankName {
            transferDraft.name = name
            transferError = String(localized: "Name des Kontoinhabers übernommen – bitte prüfen und erneut freigeben. Es wurde nichts gesendet.")
        } else {
            transferError = String(localized: "Überweisung abgebrochen – es wurde nichts gesendet.")
        }
        showTransferSheet = true
        Task { await transfer?.cancel() }
    }

    fileprivate func finishTransfer(error: Error) {
        pollTask?.cancel()
        payeeCheck = nil
        activeChallenge = nil
        activeTransfer = nil
        transferBusy = false
        transferDraft.pin = ""
        transferError = describe(error)
        showTransferSheet = true
    }
}

/// Human-readable (localised) text for core errors (instead of
/// "GiroCrabCore.CoreError.MissingSetting(key: …)").
func describe(_ error: Error) -> String {
    guard let e = error as? CoreError else { return error.localizedDescription }
    switch e {
    case .Database(let m): return String(localized: "Datenbankfehler: \(m)")
    case .WrongKey: return String(localized: "Der Tresor konnte nicht entsperrt werden (falscher Schlüssel oder beschädigte Datei).")
    case .NotFound(let what): return String(localized: "Nicht gefunden: \(what)")
    case .InvalidInput(let m): return String(localized: "Ungültige Eingabe: \(m)")
    case .MissingSetting(let key):
        let label = settingLabels[key] ?? key
        return String(localized: "Für diese Bank fehlt noch eine Einstellung: \(label). Bitte in den Einstellungen unter „FinTS & API-Schlüssel“ eintragen.")
    case .Network(let m): return String(localized: "Netzwerkfehler: \(m)")
    case .Bank(let code, let m): return String(localized: "Die Bank hat abgelehnt (\(code)): \(m)")
    case .Authentication(let m): return String(localized: "Anmeldung fehlgeschlagen: \(m)")
    case .Protocol(let m): return String(localized: "Protokollfehler: \(m)")
    case .SessionClosed: return String(localized: "Dieser Abruf ist nicht mehr aktiv.")
    case .BrowserLoginRequired(let m): return m
    case .BankingBlocked(let m): return m
    case .SchemaTooNew: return String(localized: "Dieser Tresor wurde mit einer neueren GiroCrab-Version gespeichert. Bitte die App aktualisieren.")
    }
}

let settingLabels: [String: String] = [
    "fints.product_id": String(localized: "FinTS-Produktregistrierung"),
    "fints.url.52090000": String(localized: "FinTS-Server Volksbank Kassel Göttingen"),
    "fints.url.50050201": String(localized: "FinTS-Server 1822direkt"),
    "comdirect.client_id": String(localized: "comdirect Client-ID"),
    "comdirect.client_secret": String(localized: "comdirect Client-Secret"),
    "paypal.client_id": String(localized: "PayPal Client-ID"),
    "paypal.client_secret": String(localized: "PayPal Secret"),
    "enablebanking.application_id": String(localized: "Enable Banking Application-ID"),
    "enablebanking.private_key_pem": String(localized: "Enable Banking Private Key"),
    "enablebanking.redirect_url": String(localized: "Enable Banking Redirect-URL"),
]

func formatIBAN(_ iban: String) -> String {
    var out = ""
    for (i, ch) in iban.enumerated() {
        if i > 0 && i % 4 == 0 { out.append(" ") }
        out.append(ch)
    }
    return out
}

/// How a booking row marks its account: short name and colour.
struct AccountMarker {
    let label: String
    let color: Color
    /// The account's SF Symbol, tinted with `color` (#170).
    let symbol: String
}


/// Startup timing (unified log, Debug builds only): milliseconds since process start.
enum StartupClock {
    @inline(__always)
    static func mark(_ label: String) {
        #if DEBUG
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = Double(info.kp_proc.p_un.__p_starttime.tv_sec) + Double(info.kp_proc.p_un.__p_starttime.tv_usec) / 1e6
        let ms = Int((Date().timeIntervalSince1970 - start) * 1000)
        NSLog("[startup] %6d ms  %@", ms, label)
        #endif
    }
}

extension BookingFilter {
    /// The list query sums exactly the selection's bookings (all of them, not a
    /// narrowed subset), so its `flow` can stand in for `selectionFlow`.
    var listHasFlow: Bool {
        scope == .all && direction == .all && checked == nil && search == nil && categoryId == nil && !uncategorizedOnly
    }
}
