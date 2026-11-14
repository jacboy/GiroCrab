import SwiftUI
import GiroCrabCore

/// ⌘K command palette: views, actions, accounts, categories, merchants.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var items: [Item] {
        var out: [Item] = []
        let action = String(localized: "Aktion")
        for s in BookingScope.ordered {
            out.append(Item(title: s.title, subtitle: String(localized: "Ansicht"), symbol: "rectangle.split.3x1") { model.scope = s })
        }
        if model.canTransfer {
            out.append(Item(title: String(localized: "Überweisung senden"), subtitle: "\(action) · ⌘N", symbol: "paperplane") { model.openTransfer() })
        }
        if !model.bankingBlocksAll {
            out.append(Item(title: String(localized: "Alle Konten abrufen"), subtitle: "\(action) · ⌘R", symbol: "arrow.triangle.2.circlepath") { model.requestSyncAll() })
        }
        out.append(Item(title: String(localized: "Regeln bearbeiten"), subtitle: action, symbol: "wand.and.stars") { model.openRuleEditor() })
        out.append(Item(title: String(localized: "Buchungen drucken"), subtitle: "\(action) · ⌘P", symbol: "printer") {
            // once the palette sheet is gone: one sheet at a time
            model.afterPaletteDismiss = { model.showPrintSheet = true }
        })
        out.append(Item(title: String(localized: "Wiederkehrende Buchungen"), subtitle: action, symbol: "repeat") { model.showRecurringSheet = true })
        out.append(Item(title: String(localized: "Zeitraum: Seit letztem Gehalt"), subtitle: String(localized: "Ansicht"), symbol: "banknote") { model.interactivePeriod = .sinceSalary })
        out.append(Item(title: String(localized: "Zeitraum: 12 Monate"), subtitle: String(localized: "Ansicht"), symbol: "calendar") { model.interactivePeriod = .months12 })
        let previousYear = Period.previousYear()
        out.append(Item(title: String(localized: "Zeitraum: \(previousYear.title)"), subtitle: String(localized: "Ansicht"), symbol: "calendar") { model.interactivePeriod = previousYear })
        out.append(Item(title: String(localized: "Zeitraum: Benutzerdefiniert …"), subtitle: String(localized: "Ansicht"), symbol: "calendar.badge.clock") {
            // once the palette sheet is gone, so the popover can anchor
            model.afterPaletteDismiss = { model.showCustomPeriod = true }
        })
        if let b = model.selectedBooking {
            out.append(Item(title: String(localized: "„\(b.merchant.name)“ kategorisieren"), subtitle: "\(action) · C", symbol: "tag") { model.showCategorizer = true })
            out.append(Item(title: String(localized: "Regel für „\(b.merchant.name)“ erstellen"), subtitle: "\(action) · R", symbol: "wand.and.stars") { model.openRuleEditor(from: b) })
        }
        out.append(Item(title: String(localized: "MoneyMoney Historie & Kategorien importieren"), subtitle: action, symbol: "square.and.arrow.down.on.square") { model.openMoneyMoneyImport() })
        out.append(Item(title: String(localized: "Regeln jetzt anwenden"), subtitle: action, symbol: "play") { model.applyAllRules() })
        #if os(macOS)
        out.append(Item(title: String(localized: "Einstellungen"), subtitle: "\(action) · ⌘,", symbol: "gearshape") { openSettings() })
        #else
        out.append(Item(title: String(localized: "Einstellungen"), subtitle: action, symbol: "gearshape") { model.showSettings = true })
        #endif
        out.append(Item(title: String(localized: "Alle Konten"), subtitle: String(localized: "Konten"), symbol: "square.grid.2x2") { model.interactiveSidebarSelection = .allAccounts })
        out.append(Item(title: String(localized: "Neue Umsätze"), subtitle: String(localized: "Konten"), symbol: "tray.full") { model.interactiveSidebarSelection = .newBookings })
        out.append(Item(title: String(localized: "Geplant"), subtitle: String(localized: "Konten"), symbol: "calendar.badge.clock") { model.interactiveSidebarSelection = .planned })
        out.append(Item(title: String(localized: "Neue Kontogruppe"), subtitle: "\(action) · ⇧⌘N", symbol: "folder.badge.plus") { model.groupDialog = .create() })
        out.append(Item(title: String(localized: "Kontogruppen bearbeiten"), subtitle: action, symbol: "slider.horizontal.3") { model.openGroupManager() })
        out.append(Item(title: String(localized: "Neue Hauptkategorie"), subtitle: action, symbol: "plus.square") {
            model.afterPaletteDismiss = { model.newCategoryRequest = NewCategoryRequest(parent: nil) }
        })
        out.append(Item(title: String(localized: "Neues Darlehen"), subtitle: action, symbol: "car") { model.openLoanEditor(.create) })
        out.append(Item(title: String(localized: "Neues Sachwerte-Konto"), subtitle: action, symbol: "diamond") { model.createTangibleAccount() })
        if case .account(let id) = model.sidebarSelection, model.isTangible(id) {
            out.append(Item(title: String(localized: "Sachwert hinzufügen"), subtitle: action, symbol: "plus") { model.openAssetEditor(accountId: id) })
        }
        if case .account(let id) = model.sidebarSelection, let loan = model.manualLoan(id) {
            out.append(Item(title: String(localized: "Stand von „\(loan.setup.name)“ neu setzen"), subtitle: action, symbol: "calendar.badge.clock") { model.openLoanEditor(.anchor, accountId: id) })
        }
        for m in AccountSidebarMode.allCases where m != model.accountView {
            out.append(Item(title: m.switchTitle, subtitle: String(localized: "Ansicht"), symbol: m.symbol) { model.accountView = m })
        }
        for b in model.bankGroups {
            out.append(Item(title: b.name, subtitle: String(localized: "Bank · \(accountCountText(b.accounts.count))"), symbol: b.sfSymbol) {
                model.accountView = .byBank
                model.interactiveSidebarSelection = .bank(b.id)
            })
        }
        for g in model.namedUserGroups {
            out.append(Item(title: g.name, subtitle: String(localized: "Gruppe · \(accountCountText(g.accounts.count))"), symbol: g.sfSymbol) {
                model.accountView = .byGroup
                model.interactiveSidebarSelection = .userGroup(g.uuid)
            })
        }
        if case .account(let id) = model.sidebarSelection, let a = model.account(for: id) {
            for g in model.namedUserGroups where g.uuid != a.userGroupUuid {
                out.append(Item(title: String(localized: "„\(a.name)“ nach „\(g.name)“ verschieben"), subtitle: action, symbol: "folder") { model.moveAccount(a.id, to: g.uuid) })
            }
        }
        for a in model.allAccounts {
            out.append(Item(title: a.name, subtitle: String(localized: "Konto · \(a.bankName)"), symbol: a.sfSymbol) { model.interactiveSidebarSelection = .account(a.id) })
        }
        for c in model.categories {
            out.append(Item(title: c.name, subtitle: String(localized: "Kategorie · \(c.path)"), symbol: c.sfSymbol) { model.interactiveSidebarSelection = .category(c.id) })
        }
        var seen = Set<String>()
        for b in model.bookings where seen.insert(b.merchant.key).inserted && seen.count < 300 {
            let name = b.merchant.name
            out.append(Item(title: name, subtitle: String(localized: "Händler suchen"), symbol: "magnifyingglass") { model.searchText = name })
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(out.prefix(14)) }
        return out.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }.prefix(14).map { $0 }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Theme.secondary)
                TextField("Befehl, Konto, Kategorie oder Händler …", text: $query)
                    .textFieldStyle(.plain)
                    .appFont(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        // A real button: VoiceOver and Full Keyboard Access can run it.
                        Button { index = i; run(list) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(i == index ? Theme.accent : Theme.secondary)
                            Text(item.title).foregroundStyle(Theme.text)
                            Spacer()
                            Text(item.subtitle).appFont(.caption).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? Theme.selection : Color.clear))
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(i == index ? .isSelected : [])
                    }
                }
                .padding(8)
            }
            .frame(height: 380)
        }
        .macFrame(width: 560)
        .background(Theme.card)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        let action = list[index].action
        dismiss()
        DispatchQueue.main.async { action() }
    }
}

/// "C": pick a category for the selected booking (type to filter).
struct CategorizerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    /// Pickable categories under one top-level category (`root == nil`:
    /// top-level categories without sub-categories, shown first without a header).
    struct Group: Identifiable {
        var root: GiroCrabCore.Category?
        var items: [GiroCrabCore.Category]
        var id: Int64 { root?.id ?? -1 }
    }

    /// Pickable categories (sub-categories and childless top-level ones)
    /// matching the query, grouped by their top-level category in sidebar order.
    private var groups: [Group] {
        let all = model.categories
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parents = Set(all.compactMap(\.parentId))
        let q = query.lowercased()
        var loose: [GiroCrabCore.Category] = []
        var order: [Int64] = []
        var byRoot: [Int64: [GiroCrabCore.Category]] = [:]
        for c in all where c.parentId != nil || !parents.contains(c.id) {
            if !q.isEmpty, !c.path.lowercased().contains(q) { continue }
            guard c.parentId != nil else { loose.append(c); continue }
            var root = c
            for _ in 0..<32 { guard let p = root.parentId, let parent = byID[p] else { break }; root = parent }
            if byRoot[root.id] == nil { order.append(root.id) }
            byRoot[root.id, default: []].append(c)
        }
        var out: [Group] = loose.isEmpty ? [] : [Group(root: nil, items: loose)]
        out += order.map { Group(root: byID[$0], items: byRoot[$0] ?? []) }
        return out
    }

    /// Chip label: the path below the top-level category ("Restaurant › Lieferdienst"),
    /// so deeper levels stay recognisable inside their group.
    private func title(for c: GiroCrabCore.Category) -> String {
        guard c.depth > 1 else { return c.name }
        var names = [c.name]
        var next = c.parentId
        while let id = next, names.count < 32, let p = model.categories.first(where: { $0.id == id }), p.parentId != nil {
            names.insert(p.name, at: 0)
            next = p.parentId
        }
        return names.joined(separator: " › ")
    }

    var body: some View {
        let groups = groups
        let first = groups.first?.items.first
        VStack(alignment: .leading, spacing: 12) {
            if model.isMultiSelection {
                let many = model.selectedBookings
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(many.count) Buchungen kategorisieren").appFont(.headline)
                    Text(Money.format(many.reduce(0) { $0 + $1.amountCents })).appFont(.caption, monospacedDigit: true).foregroundStyle(Theme.secondary)
                }
            } else if let b = model.selectedBooking {
                HStack(spacing: 10) {
                    MerchantSignet(merchant: b.merchant, categorySymbol: b.categorySymbol)
                    VStack(alignment: .leading) {
                        Text(b.merchant.name).appFont(.headline)
                        Text(Money.format(b.amountCents)).appFont(.caption, monospacedDigit: true).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                }
            }
            TextField("Kategorie suchen …", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first { pick(first.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let root = group.root {
                                Label(root.name, systemImage: root.sfSymbol)
                                    .appFont(.caption, weight: .semibold)
                                    .foregroundStyle(Theme.secondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                                ForEach(group.items) { c in
                                    CategoryChip(category: c, selected: currentCategory == c.id, title: title(for: c)) { pick(c.id) }
                                        .help(c.path)
                                        .accessibilityLabel(c.path)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Button("Kategorie entfernen") { pick(nil) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .macFrame(width: 560)
        .onAppear { focused = true }
    }

    /// The category all selected bookings share (marked), else none.
    private var currentCategory: Int64? {
        let ids = Set((model.isMultiSelection ? model.selectedBookings : model.selectedBooking.map { [$0] } ?? []).map(\.categoryId))
        return ids.count == 1 ? ids.first! : nil
    }

    private func pick(_ id: Int64?) {
        if model.isMultiSelection {
            model.setCategory(id, for: model.selectedBookings)
        } else if let b = model.selectedBooking {
            model.setCategory(id, for: b)
        }
        dismiss()
    }
}
