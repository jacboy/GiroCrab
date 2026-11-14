import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

enum SidebarItem: Hashable {
    case allAccounts
    case group(Int64)
    /// Accounts of one bank ("Nach Bank"); empty = "Ohne Bank".
    case bank(String)
    /// User-defined group ("Nach Gruppe"); empty uuid = "Ohne Gruppe".
    case userGroup(String)
    case account(Int64)
    case category(Int64)
    case uncategorized
    /// "Belege & PostBox"
    case documents
    /// „Neue Umsätze“ (GitHub #352): unreviewed bookings of all accounts.
    case newBookings
    /// „Geplant“ (GitHub #240): future payments with an order at the bank.
    case planned
}

/// Period of the booking list and its sums. The menu follows MoneyMoney
/// (GitHub #382): rolling windows, then the latest months, quarters and years
/// by name, counted back from today.
enum Period: Hashable, Identifiable {
    case all
    /// Today and the `n − 1` days before.
    case days(Int)
    /// Rolling year: from the same day a year ago (exclusive) to today.
    case months12
    /// Pay cycle: from the latest detected salary inflow (GitHub #37).
    case sinceSalary
    case month(Int, Int)
    case quarter(Int, Int)
    case year(Int)
    /// User-defined start and end date (GitHub #53); the dates live in `AppModel`.
    case custom
    var id: Self { self }

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// The menu sections; `.custom` is chosen through the date dialog.
    static func menu(now: Date = Date()) -> [[Period]] {
        let c = calendar.dateComponents([.year, .month], from: now)
        let (y, m) = (c.year ?? 2000, c.month ?? 1)
        let months = (0..<3).map { back -> Period in
            let i = y * 12 + (m - 1) - back
            return .month(i / 12, i % 12 + 1)
        }
        let quarters = (0..<3).map { back -> Period in
            let i = y * 4 + (m - 1) / 3 - back
            return .quarter(i / 4, i % 4 + 1)
        }
        return [
            [.all],
            [.days(30), .days(90), .months12, .sinceSalary],
            months,
            quarters,
            (0..<3).map { .year(y - $0) },
        ]
    }

    /// The month before the current one (default of the date dialog, demo print).
    static func previousMonth(now: Date = Date()) -> Period { menu(now: now)[2][1] }
    /// The year before the current one.
    static func previousYear(now: Date = Date()) -> Period { menu(now: now)[4][1] }

    var title: String {
        switch self {
        case .all: return String(localized: "Gesamter Zeitraum")
        case .days(let n): return String(localized: "\(n) Tage")
        case .months12: return String(localized: "12 Monate")
        case .sinceSalary: return String(localized: "Seit letztem Gehalt")
        case .month(let y, let m):
            let date = Self.calendar.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
            return date.formatted(.dateTime.month(.wide).year())
        case .quarter(let y, let q): return String(localized: "\(q). Quartal \(String(y))")
        case .year(let y): return String(localized: "Jahr \(String(y))")
        case .custom: return String(localized: "Benutzerdefiniert")
        }
    }

    var range: (String?, String?) { range(now: Date()) }

    /// ISO start/end (inclusive, `nil` = open) relative to `now`.
    func range(now: Date) -> (String?, String?) {
        let cal = Self.calendar
        let today = cal.startOfDay(for: now)
        // first day of a month and the day before the first of `months` later
        let span = { (y: Int, m: Int, months: Int) -> (String?, String?) in
            let start = cal.date(from: DateComponents(year: y, month: m, day: 1))!
            let end = cal.date(byAdding: DateComponents(month: months, day: -1), to: start)!
            return (DateText.iso(start), DateText.iso(end))
        }
        switch self {
        // `.custom` dates live in `AppModel.periodRange`.
        case .all, .custom: return (nil, nil)
        case .days(let n): return (DateText.iso(cal.date(byAdding: .day, value: -(n - 1), to: today)!), nil)
        case .months12:
            let start = cal.date(byAdding: DateComponents(year: -1, day: 1), to: today)!
            return (DateText.iso(start), nil)
        // The salary start date lives in `AppModel.periodRange`; calendar month as fallback.
        case .sinceSalary:
            return (DateText.iso(cal.date(from: cal.dateComponents([.year, .month], from: now))!), nil)
        case .month(let y, let m): return span(y, m, 1)
        case .quarter(let y, let q): return span(y, (q - 1) * 3 + 1, 3)
        case .year(let y): return span(y, 1, 12)
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

    var executionMode: ExecutionMode {
        get { instant ? .instant : (scheduled ? .scheduled : .regular) }
        set {
            instant = newValue == .instant
            scheduled = newValue == .scheduled
        }
    }

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

/// How a transfer is executed; exactly one applies.
enum ExecutionMode: Hashable {
    case regular, scheduled, instant
}

/// A transfer whose result is unclear: it may have been executed.
struct TransferUnknownNotice: Identifiable {
    let id = UUID()
    let reason: String
    let endToEndId: String
}

/// A transfer cancellation the bank has not confirmed: the order (bunq draft)
/// may still be approvable. The session stays alive so the status can be re-checked.
struct UnconfirmedTransferCancel: Identifiable {
    let id = UUID()
    let session: TransferSession
    var outcome: CancelOutcome
    var busy = false

    var message: String {
        let head: String
        let reason: String
        switch outcome {
        case .cancelled:
            return ""
        case .cancellationPending(let r):
            head = String(localized: "Die Stornierung wurde von der Bank angenommen, aber noch nicht bestätigt.")
            reason = r
        case .cancellationUnknown(let r):
            head = String(localized: "Es ist unklar, ob die Überweisung storniert wurde (keine eindeutige Antwort der Bank).")
            reason = r
        case .cancellationFailed(let r):
            head = String(localized: "Die Überweisung konnte nicht storniert werden.")
            reason = r
        }
        let advice = String(localized: "Sie kann möglicherweise noch in der bunq-App freigegeben werden. Prüfen Sie den Status erneut oder lehnen Sie sie dort ab.")
        return "\(head)\n\n\(reason)\n\n\(advice)"
    }
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
        return String(localized: "Für diese Bank fehlt noch eine Einstellung: \(label). Bitte in den Einstellungen unter „Banken“ beim Bearbeiten dieser Bank eintragen.")
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

extension Result where Failure == Error {
    /// Async counterpart of `Result(catching:)`.
    init(catchingAsync body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
