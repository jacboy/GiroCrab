import SwiftUI
import GiroCrabCore

/// Column 1: collapsible account sections with subtotals, then categories.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The one sidebar dialog on screen (group dialogs live in `model.groupDialog`).
    @State private var dialog: SidebarDialog?
    @State private var budgetCategory: IDBox?
    /// Where a drop would land: a thin line above or below one row.
    @State private var dropLine: DropLine?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.interactiveSidebarSelection) {
            if !model.allAccounts.isEmpty {
                AccountsSectionHeader()
            }
            // the root of the account tree, like MoneyMoney's „Alle Konten“
            AllAccountsRow()
                .badge(model.newCount) // system sidebar badge (hidden at 0)
                .tag(SidebarItem.allAccounts)
                .contextMenu {
                    Button("Alle als gelesen markieren", systemImage: "checkmark.circle") { model.markAllChecked(accountIDs: model.allAccounts.map(\.id)) }
                        .disabled(model.newCount == 0)
                }
            if model.showsAccountTree {
                Group {
                    switch model.accountView {
                    case .byGroup: userGroupRows
                    case .byBank: bankGroupRows
                    case .byKind: kindGroupRows
                    }
                }
                // one step right of „Alle Konten“
                .padding(.leading, 14)
            }
            // „Neue Umsätze“ (#352): a page across all accounts, like „Belege & PostBox“
            HStack(spacing: 8) {
                Image(systemName: "tray.full").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Neue Umsätze").fontWeight(.medium).appDefaultFont()
                Spacer()
            }
            .badge(model.newCount)
            .tag(SidebarItem.newBookings)
            .contextMenu {
                Button("Alle als gelesen markieren", systemImage: "checkmark.circle") { model.markAllChecked(accountIDs: model.allAccounts.map(\.id)) }
                    .disabled(model.newCount == 0)
            }
            // „Geplant“ (#240): ordered at the bank, not booked yet
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Geplant").fontWeight(.medium).appDefaultFont()
                Spacer()
            }
            .tag(SidebarItem.planned)
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.secondary).frame(width: 20)
                Text("Belege & PostBox").fontWeight(.medium).appDefaultFont()
                Spacer()
            }
            .tag(SidebarItem.documents)
            // The MoneyMoney import is an action, not a place: it lives in
            // Ablage › Aus MoneyMoney importieren …, the command palette and
            // the welcome card (HIG: sidebar rows are navigation destinations).


            let pending = model.connections.filter { c in !model.allAccounts.contains { $0.connectionId == c.id } }
            if !pending.isEmpty {
                Section("Neue Bankzugänge") {
                ForEach(pending) { c in
                    HStack(spacing: 9) {
                        SymbolTile(symbol: c.sfSymbol, tint: c.tint, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.displayName).lineLimit(1).appDefaultFont()
                            Text(model.missingSettings(for: c).isEmpty ? "Noch nicht abgerufen" : "Einrichtung fehlt")
                                .appFont(.caption2)
                                .foregroundStyle(model.missingSettings(for: c).isEmpty ? Theme.secondary : Theme.warning)
                        }
                        Spacer()
                        Button(model.missingSettings(for: c).isEmpty ? "Abrufen" : "Einrichten") { model.requestSync(c) }
                            .controlSize(.small)
                            .disabled(model.bankingGate(for: c) != nil)
                            .help(model.bankingGate(for: c)?.message ?? "")
                    }
                    .contextMenu {
                        Button("Bankzugang entfernen …", systemImage: "trash", role: .destructive) { dialog = .removeConnection(c.id) }
                    }
                }
                }
            }

            // a plain row styled like the group headers (not a List section
            // header, whose small caption style can't match them)
            CategoriesHeader()
                .padding(.top, 10)
            if !model.categoriesCollapsed {
                Group {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.folder").foregroundStyle(Theme.warning).frame(width: 20)
                        Text("Ohne Kategorie").appDefaultFont()
                        Spacer()
                    }
                    .badge(model.uncategorizedCount)
                    .tag(SidebarItem.uncategorized)
                    categoryRows(model.categoryTree)
                }
                // one step right of their header, like the groups under „Alle Konten“
                .padding(.leading, 14)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refreshCurrentView() }
        .background(Theme.sidebar)
        .navigationTitle("GiroCrab")
        #if os(macOS)
        // Keep traffic lights / sidebar toggle clear of the first row.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 28) }
        #endif
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                // Marketing screenshots (`--screenshot`) look like a real vault: no demo banner.
                if model.isDemo && LaunchOptions.current.screenshotPath == nil {
                    Image(systemName: "theatermasks")
                    Text("Demo-Daten – keine echte Bank verbunden")
                    Button(model.hasOwnVault ? "Eigener Tresor" : "Tresor öffnen") { model.showOwnVault() }
                        .buttonStyle(.borderless)
                } else {
                    Image(systemName: "lock.fill")
                    Text("Verschlüsselt · \(model.lastSyncText)")
                }
                Spacer(minLength: 0)
                Button { model.showAddBank = true } label: {
                    Image(systemName: "plus").frame(width: 24, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Bank hinzufügen …")
                .accessibilityLabel("Bank hinzufügen")
                .disabled(!model.isUnlocked)
            }
            .appFont(.caption)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .confirmationDialog(
            dialog?.title ?? Text(verbatim: ""),
            isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }),
            titleVisibility: .visible,
            presenting: dialog
        ) { d in
            switch d {
            case .archiveAccount(let a): Button("Archivieren") { model.setAccountArchived(a, true) }
            case .deleteAccount(let a): Button("Endgültig löschen", role: .destructive) { model.deleteAccount(a.id) }
            case .removeConnection(let id): Button("Entfernen", role: .destructive) { model.removeConnection(id) }
            case .deleteCategory(let c): Button("„\(c.name)“ löschen", role: .destructive) { model.deleteCategory(c.id) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { d in
            switch d {
            case .archiveAccount(let a):
                Text("„\(a.name)“ wird nicht mehr abgerufen, von Regeln nicht mehr verändert und zählt nicht mehr zur Gesamtsumme. Buchungen, Kategorien, Belege und die Gruppe bleiben erhalten. Das Konto lässt sich jederzeit reaktivieren.")
            case .deleteAccount(let a):
                Text("„\(a.name)“ wird samt \(a.transactionCount) Buchungen, Belegen und Depotpositionen unwiderruflich gelöscht – auch aus Auswertungen und Kategoriesummen. Ist es das letzte Konto seines Bankzugangs, wird auch der Bankzugang mit den gespeicherten Zugangsdaten entfernt.")
            case .removeConnection:
                Text("Alle Konten dieses Bankzugangs werden samt Buchungen, Belegen und gespeicherten Zugangsdaten aus dem Tresor gelöscht. Das lässt sich nicht widerrufen.")
            default: EmptyView()
            }
        }
        .sheet(item: $budgetCategory) { box in BudgetEditorSheet(categoryID: box.id).environment(model) }
    }

    /// "Nach Kontoart": the fixed kind sections.
    @ViewBuilder
    private var kindGroupRows: some View {
        ForEach(model.groups) { group in
            let listed = group.accounts.filter(isShown)
            // While searching, hide empty kind sections so only hits remain.
            if !model.isSidebarAccountSearching || !listed.isEmpty {
            let open = model.isKindGroupOpen(group.id)
            let toggle = {
                withAnimation(Motion.animation(.easeInOut(duration: 0.15))) {
                    if open { model.collapsedGroups.insert(group.id) } else { model.collapsedGroups.remove(group.id) }
                }
            }
            // Plain rows instead of List sections: macOS would otherwise
            // restore its own saved collapse state for sidebar sections.
            SectionHeader(
                name: group.name, sfSymbol: group.sfSymbol, balanceCents: group.balanceCents,
                selected: model.sidebarSelection == .group(group.id),
                isLoanGroup: !group.accounts.isEmpty && group.accounts.allSatisfy { $0.kind == .loan },
                open: open, toggle: toggle
            )
                .padding(.top, 10)
                .groupHeaderTap(SidebarItem.group(group.id), toggle: toggle)
                #if os(iOS)
                .contextMenu {
                    Button("Gruppenübersicht", systemImage: "list.bullet.rectangle") { model.interactiveSidebarSelection = .group(group.id) }
                }
                #endif
            ForEach(open ? listed : []) { account in
                accountRow(account)
            }
            }
        }
    }

    /// "Nach Bank": one section per bank name / connection.
    @ViewBuilder
    private var bankGroupRows: some View {
        ForEach(model.bankGroups) { group in
            let listed = group.accounts.filter(isShown)
            if !model.isSidebarAccountSearching || !listed.isEmpty {
                let open = model.isBankGroupOpen(group.id)
                let toggle = {
                    withAnimation(Motion.animation(.easeInOut(duration: 0.15))) {
                        model.toggleCollapsedBank(group.id)
                    }
                }
                SectionHeader(
                    name: group.name, sfSymbol: group.sfSymbol, balanceCents: group.balanceCents,
                    selected: model.sidebarSelection == .bank(group.id),
                    isLoanGroup: !group.accounts.isEmpty && group.accounts.allSatisfy { $0.kind == .loan },
                    nameRedaction: [],
                    open: open, toggle: toggle
                )
                .padding(.top, 10)
                .groupHeaderTap(SidebarItem.bank(group.id), toggle: toggle)
                #if os(iOS)
                .contextMenu {
                    Button("Bankübersicht", systemImage: "list.bullet.rectangle") { model.interactiveSidebarSelection = .bank(group.id) }
                }
                #endif
                ForEach(open ? listed : []) { account in
                    accountRow(account)
                }
            }
        }
    }

    /// "Nach Gruppe": user groups, then "Ohne Gruppe".
    @ViewBuilder
    private var userGroupRows: some View {
        // a flattened tree: subgroups follow their group, indented by depth
        ForEach(model.userGroups.filter(model.isUserGroupListed)) { group in
            let open = model.isUserGroupOpen(group)
            let toggle = { withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.toggleCollapsed(group) } }
            let indent = CGFloat(group.depth) * 14
            UserGroupHeader(group: group, open: open, toggle: toggle)
                // an account goes to the top of this group; a group above it
                // (upper half) or into it as a subgroup (lower half)
                .modifier(DropSlot(key: "g:" + group.uuid, inset: 0, line: $dropLine, edge: { half in
                    guard let dragged = GroupDrag.draggedGroup else { return .below }
                    let into = half == .below && !group.isUngrouped
                    return model.canDropGroup(dragged, on: group, into: into) ? (into ? .into : .above) : nil
                }, perform: { items, edge in
                    handleDrop(items, into: group, row: nil, edge: edge)
                }, freeLeading: 12))  // the expand/collapse arrow
                .padding(.top, group.depth == 0 ? 10 : 4)
                .padding(.leading, indent)
                .groupHeaderTap(SidebarItem.userGroup(group.uuid), toggle: toggle)
                .contextMenu {
                    UserGroupMenu(group: group)
                }
                .popover(isPresented: model.iconColorBinding(.group(group.uuid)), arrowEdge: .trailing) {
                    IconColorPopover(target: .group(group.uuid)).environment(model)
                }
                // no custom preview: the drag shows the row itself, like MoneyMoney
                .draggable(GroupDrag.group(group.uuid))
            if open {
                if !model.isSidebarAccountSearching,
                   group.accounts.isEmpty && !group.isUngrouped && model.userGroupSubtree(group.uuid).count == 1 {
                    Text(emptyHint)
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 33 + indent)
                        // an account goes here; a group into the group (header lights up)
                        .modifier(DropSlot(key: "e:" + group.uuid, inset: 33 + indent, line: $dropLine, edge: { _ in
                            if let dragged = GroupDrag.draggedGroup {
                                return model.canDropGroup(dragged, on: group, into: true) ? .into : nil
                            }
                            return .above
                        }, perform: { items, edge in
                            handleDrop(items, into: group, row: nil, edge: edge)
                        }, intoKey: "g:" + group.uuid))
                }
                // offsets of the full list: a drop position counts hidden archived accounts too
                ForEach(Array(group.accounts.enumerated()).filter { isShown($0.element) }, id: \.element.id) { i, account in
                    // an account: the line follows the half of the row under the pointer,
                    // also over the dragged row itself so it shows from the start;
                    // a group: into this group, its header lights up
                    accountRow(account, drop: DropSlot(key: "a:\(account.id)", inset: 0, line: $dropLine, edge: { half in
                        if let dragged = GroupDrag.draggedGroup {
                            return model.canDropGroup(dragged, on: group, into: true) ? .into : nil
                        }
                        return half
                    }, perform: { items, edge in
                        handleDrop(items, into: group, row: i, edge: edge)
                    }, intoKey: "g:" + group.uuid))
                        // one step right of their group, at every nesting level
                        .padding(.leading, indent + 14)
                        .draggable(GroupDrag.account(account.id))
                }
            }
        }
    }

    private var emptyHint: LocalizedStringKey {
        #if os(macOS)
        "Konten hierher ziehen"
        #else
        "Keine Konten – Konto lange drücken, um es zuzuordnen"
        #endif
    }

    /// A drop next to or onto a sidebar row. An account lands at the line
    /// next to row `row` (`row` nil = a header: top of the group). A group goes
    /// into `group` (`.into`, becomes its subgroup) or right above it as its
    /// sibling; onto "Ohne Gruppe" it moves to the top level, at the end.
    private func handleDrop(_ items: [String], into group: UserGroup, row: Int?, edge: DropLine.Edge = .above) -> Bool {
        var handled = false
        for item in items {
            if let id = GroupDrag.accountID(item) {
                let from = group.accounts.firstIndex { $0.id == id }
                let index = row.map { GroupDrag.insertionIndex(row: $0, below: edge == .below, from: from) } ?? 0
                model.moveAccount(id, to: group.uuid, at: index)
                handled = true
            } else if let uuid = GroupDrag.groupUUID(item) {
                handled = model.dropUserGroup(uuid, onto: group, before: edge != .into) || handled
            }
        }
        return handled
    }

    /// Archived accounts can be hidden; the sidebar search filters by name,
    /// Kontoinhaber, IBAN and account number (spaces ignored).
    private func isShown(_ account: Account) -> Bool {
        model.isSidebarAccountListed(account)
    }

    /// `drop` sits inside the context menu (and the caller's drag), so its drop
    /// zones don't cover the row for clicks.
    private func accountRow(_ account: Account, drop: DropSlot? = nil) -> some View {
        AccountRow(account: account, syncing: model.syncingConnectionID != nil && model.syncingConnectionID == account.connectionId)
            .dropSlot(drop)
            .tag(SidebarItem.account(account.id))
            .contextMenu { accountMenu(account) }
            .popover(isPresented: model.iconColorBinding(.account(account.id)), arrowEdge: .trailing) {
                IconColorPopover(target: .account(account.id)).environment(model)
            }
            #if os(iOS)
            .swipeActions(edge: .trailing) {
                Button("Gruppe …", systemImage: "folder") { model.groupDialog = .moveAccount(account) }
                    .tint(Theme.accent)
            }
            #endif
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        // same order as a group's menu: rename, look, place – then what only
        // accounts have – then archive / delete
        Button("Umbenennen …", systemImage: "pencil") { model.groupDialog = .renameAccount(account) }
        Button("Symbol & Farbe …", systemImage: "paintpalette") { model.iconColorTarget = .account(account.id) }
        AccountGroupMenu(account: account)
        Divider()
        Button("Alle als gelesen markieren", systemImage: "checkmark.circle") { model.markAllChecked(accountIDs: [account.id]) }
        ManualLoanAccountMenu(model: model, account: account)
        OpeningBalanceMenuItem(model: model, account: account)
        if !account.isArchived, let cid = account.connectionId, let conn = model.connections.first(where: { $0.id == cid }) {
            Button("\(conn.displayName) abrufen", systemImage: "arrow.triangle.2.circlepath") { model.requestSync(conn) }
                .disabled(model.bankingGate(for: conn) != nil)
        }
        AccountCopyMenu(account: account)
        Button("Belege anzeigen", systemImage: "doc.text.magnifyingglass") {
            model.documentsAccountFilter = account.id
            model.interactiveSidebarSelection = .documents
        }
        Divider()
        if account.isArchived {
            Button("Reaktivieren", systemImage: "arrow.uturn.backward") { model.setAccountArchived(account, false) }
            // only archived accounts can be deleted (GiroCrab/GiroCrab#43)
            Button("Konto löschen …", systemImage: "trash", role: .destructive) { dialog = .deleteAccount(account) }
        } else {
            Button("Konto archivieren …", systemImage: "archivebox") { dialog = .archiveAccount(account) }
        }
    }

    /// The category tree at any depth (#101): a node with sub-categories is a
    /// disclosure group whose content recurses into its children.
    private func categoryRows(_ nodes: [CategoryNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let kids = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expandedCategories.contains(node.id) },
                    set: { if $0 { model.expandedCategories.insert(node.id) } else { model.expandedCategories.remove(node.id) } }
                )) {
                    categoryRows(kids)
                } label: {
                    CategoryRow(category: node.category)
                        .contextMenu { categoryMenu(node.category) }
                        .modifier(CategoryIconColorPopover(id: node.id))
                }
                .tag(SidebarItem.category(node.id))
            } else {
                CategoryRow(category: node.category)
                    .tag(SidebarItem.category(node.id))
                    .contextMenu { categoryMenu(node.category) }
                    .modifier(CategoryIconColorPopover(id: node.id))
            }
        })
    }

    @ViewBuilder
    private func categoryMenu(_ category: GiroCrabCore.Category) -> some View {
        // same order as the menus of accounts and groups (#183): rename, look,
        // place – then what only categories have – then delete
        Button("Umbenennen …", systemImage: "pencil") { model.groupDialog = .renameCategory(category) }
        Button("Symbol & Farbe …", systemImage: "paintpalette") { model.iconColorTarget = .category(category.id) }
        Menu("Verschieben nach", systemImage: "arrow.turn.down.right") {
            Toggle(isOn: Binding(
                get: { category.parentId == nil },
                set: { _ in model.moveCategory(category.id, to: nil) }
            )) {
                Label("Oberste Ebene", systemImage: "arrow.up.to.line")
            }
            Divider()
            ForEach(model.categoryMoveTargets(for: category.id)) { c in
                Toggle(isOn: Binding(
                    get: { category.parentId == c.id },
                    set: { _ in model.moveCategory(category.id, to: c.id) }
                )) {
                    Label(String(repeating: "\u{2003}", count: Int(c.depth)) + c.name, systemImage: c.sfSymbol)
                }
            }
        }
        Divider()
        Button("Neue Unterkategorie …", systemImage: "plus") { model.newCategoryRequest = NewCategoryRequest(parent: category.id) }
        Button("Monatsbudget festlegen …", systemImage: "gauge.with.dots.needle.67percent") { budgetCategory = IDBox(id: category.id) }
        Divider()
        Button("Kategorie löschen …", systemImage: "trash", role: .destructive) { dialog = .deleteCategory(category) }
    }
}

struct SectionHeader: View {
    /// Selected header: hierarchical styles so macOS can draw them light on the
    /// accent-coloured selection (fixed theme colours stay dark there).
    let name: String
    let sfSymbol: String
    let balanceCents: Int64
    var selected: Bool = false
    var isLoanGroup: Bool = false
    /// Bug report screenshot (#301): category-like group names hide on request, bank names stay visible.
    var nameRedaction: ReportRedaction = .labels
    var open: Bool = true
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .appFont(.caption, weight: .bold)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(open ? "„\(name)“ einklappen" : "„\(name)“ ausklappen")
            .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
            // styled like the "Gruppen" headers (UserGroupHeader), so both
            // views read the same and no header is smaller than its accounts (#171)
            Image(systemName: sfSymbol)
                .appFont(.body, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(name)
                .sensitive(nameRedaction)
            Spacer()
            Text(Money.format(balanceCents))
                .sensitive()
                .appFont(.callout, weight: .semibold) // same size as the account balances
                .monospacedDigit()
                .fixedSize() // the name truncates, never the balance (#343)
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(balanceCents < 0 && isLoanGroup ? Theme.loan : (balanceCents < 0 ? Theme.negative : Theme.secondary)))
        }
        .appFont(.body, weight: .semibold) // as big as the account names
        .foregroundStyle(.secondary)
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    /// Selected row: the amount uses the hierarchical `.primary` style, which
    /// macOS turns white on the accent-coloured selection (fixed theme colours
    /// stay dark there). `backgroundProminence` is not set in a macOS sidebar.
    private var onSelection: Bool { model.sidebarSelection == .account(account.id) }
    let account: Account
    var syncing: Bool = false

    private var repaid: Double? {
        guard account.kind == .loan, let p = account.initialBalanceCents, p > 0 else { return nil }
        return max(0, min(1, 1 - Double(-account.balanceCents) / Double(p)))
    }

    var body: some View {
        HStack(spacing: 9) {
            // tinted like the account's marker in the booking list
            AccountSignet(account: account, size: 24, color: model.accountColor(account.id), onSelection: onSelection)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.name).lineLimit(1).sensitive()
                    if account.accessRevoked {
                        Image(systemName: "lock.slash")
                            .appFont(.caption2)
                            .foregroundStyle(.orange)
                            .help("Zugriff entzogen: Die Bank liefert dieses Konto nicht mehr. Buchungen bleiben erhalten.")
                    }
                    if account.newCount > 0 {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                }
                if let repaid {
                    // in a line as tall as the bank name of other accounts, so
                    // loan rows don't sit higher than their neighbours (#171)
                    ZStack(alignment: .leading) {
                        Text(verbatim: " ").appFont(.caption2).hidden()
                        ProgressView(value: repaid)
                            .progressViewStyle(.linear)
                            .tint(Theme.loan.opacity(0.7))
                            .controlSize(.mini)
                            .frame(maxWidth: 110)
                    }
                    .help("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt")
                } else if let date = account.archivedDate {
                    Text("Archiviert \(date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)))")
                        .appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Archiviert – wird nicht mehr abgerufen")
                } else {
                    Text(searchAwareSubtitle)
                        .sensitive(searchAwareSubtitle == account.bankName ? [] : .personal) // owner / IBAN hits
                        .appFont(.caption2, design: ibanSubtitle ? .monospaced : .default)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if syncing {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Money.format(account.balanceCents, currency: account.currency))
                    .sensitive()
                    .appFont(.callout, monospacedDigit: true)
                    .fixedSize() // the name truncates, never the balance (#343)
                    .foregroundStyle(onSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(account.kind == .loan ? Theme.loan : (account.balanceCents < 0 ? Theme.negative : Theme.text)))
                if let repaid {
                    Text("\(repaid.formatted(.percent.precision(.fractionLength(0)))) getilgt").appFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
        .opacity(account.isArchived ? 0.55 : 1)
    }

    /// While searching, prefer Kontoinhaber or IBAN so the hit is obvious.
    private var searchAwareSubtitle: String {
        guard model.isSidebarAccountSearching else { return account.bankName }
        let q = model.sidebarAccountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = q.filter { !$0.isWhitespace }.lowercased()
        if !account.owner.isEmpty {
            let terms = q.split(whereSeparator: \.isWhitespace)
            if !terms.isEmpty, terms.allSatisfy({ account.owner.localizedCaseInsensitiveContains($0) }) {
                return account.owner
            }
        }
        if !compact.isEmpty, compact.count >= 3,
           account.compactAccountIds.contains(where: { $0.contains(compact) }) {
            return account.iban.isEmpty ? account.accountNumber : formatIBAN(account.iban)
        }
        return account.bankName
    }

    private var ibanSubtitle: Bool {
        model.isSidebarAccountSearching && searchAwareSubtitle == formatIBAN(account.iban)
    }
}

struct CategoryRow: View {
    let category: GiroCrabCore.Category

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.sfSymbol)
                .foregroundStyle(Color.readable(hex: category.colorHex).opacity(0.85))
                .frame(width: 20)
            Text(category.name).lineLimit(1).appDefaultFont().sensitive(.labels)
            Spacer(minLength: 4)
            if category.totalCents != 0 {
                Text(Money.format(category.totalCents))
                    .sensitive()
                    .appFont(.caption, monospacedDigit: true)
                    .fixedSize()
                    .foregroundStyle(.secondary) // follows selection, Dark Mode, Increase Contrast
            }
        }
    }
}

private extension View {
    /// macOS: clicking the header selects the group (the chevron collapses).
    /// iOS: the whole header collapses/expands – a bigger target than the
    /// chevron; the group overview is in the long-press menu.
    @ViewBuilder
    func groupHeaderTap(_ item: SidebarItem, toggle: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.tag(item)
        #else
        self.contentShape(Rectangle()).onTapGesture(perform: toggle)
        #endif
    }
}

/// The insertion line a drag shows: above or below one sidebar row.
private struct DropLine: Equatable {
    /// `into`: onto the row itself (a group becoming a subgroup).
    enum Edge { case above, below, into }
    /// The row that draws the mark.
    let key: String
    let edge: Edge
    /// The drop zone under the pointer (one row half; may mark another row).
    let zone: String
}

/// A sidebar row as drop target. Like MoneyMoney and Finder it marks the
/// spot with a thin line between rows instead of outlining the row. The row
/// gets two drop zones, its upper and lower half, so the line can follow the
/// pointer while every drop still goes through `dropDestination` (a
/// `DropDelegate` here left the sidebar list unable to start a second drag).
private struct DropSlot: ViewModifier {
    let key: String
    /// Where the line starts, so it lines up with the row's content.
    let inset: CGFloat
    @Binding var line: DropLine?
    /// The line's edge for the pointer over the given half; nil = no drop here.
    let edge: (_ half: DropLine.Edge) -> DropLine.Edge?
    let perform: (_ items: [String], _ edge: DropLine.Edge) -> Bool
    /// The row that lights up for `.into` (default: this one), e.g. the
    /// group's header while a group hovers over its accounts.
    var intoKey: String?
    /// Leading strip the drop zones leave free, so a button there still gets
    /// its clicks (the zones lie on top of the row).
    var freeLeading: CGFloat = 0

    /// Zones a drag is over right now. Not state: changing it must not redraw.
    @MainActor private static var hovered: Set<String> = []

    func body(content: Content) -> some View {
        content
            .overlay {
                VStack(spacing: 0) {
                    zone(.above)
                    zone(.below)
                }
                .padding(.leading, freeLeading)
            }
            .background {
                // dropping into the row: a highlight, like Finder on a folder
                if line?.key == key, line?.edge == .into {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.accent.opacity(0.18))
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                        .padding(.leading, inset - 4)
                        .padding(.vertical, -2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: line?.edge == .below ? .bottom : .top) {
                if line?.key == key, line?.edge != .into {
                    // a small ring, then a thin line, centred on the gap between two rows
                    HStack(spacing: 0) {
                        Circle().strokeBorder(Theme.secondary, lineWidth: 1.5).frame(width: 7, height: 7)
                        Rectangle().fill(Theme.secondary).frame(height: 1.5)
                    }
                    .padding(.leading, inset)
                    .offset(y: line?.edge == .below ? 3.5 : -3.5)
                    .allowsHitTesting(false)
                }
            }
    }

    private func zone(_ half: DropLine.Edge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                line = nil
                guard let edge = edge(half) else { return false }
                return perform(items, edge)
            } isTargeted: { targeted in
                // SwiftUI reports a quick off/on while the pointer moves within a
                // zone: write only real changes and clear a tick later, unless the
                // zone came back meanwhile, so the mark doesn't flicker.
                let zone = key + (half == .above ? "↑" : "↓")
                if targeted, let edge = edge(half) {
                    Self.hovered.insert(zone)
                    let next = DropLine(key: edge == .into ? intoKey ?? key : key, edge: edge, zone: zone)
                    if line != next { line = next }
                } else {
                    Self.hovered.remove(zone)
                    DispatchQueue.main.async {
                        if !Self.hovered.contains(zone), line?.zone == zone { line = nil }
                    }
                }
            }
    }
}

extension View {
    @ViewBuilder
    fileprivate func dropSlot(_ slot: DropSlot?) -> some View {
        if let slot { modifier(slot) } else { self }
    }
}

/// Sidebar-only dialogs (account, bank login, category). One state instead
/// of one flag per dialog.
private enum SidebarDialog {
    case archiveAccount(Account)
    case deleteAccount(Account)
    case removeConnection(Int64)
    case deleteCategory(GiroCrabCore.Category)

    var title: Text {
        switch self {
        case .archiveAccount: Text("Konto archivieren?")
        case .deleteAccount: Text("Archiviertes Konto endgültig löschen?")
        case .removeConnection: Text("Bankzugang entfernen?")
        case .deleteCategory: Text("Kategorie löschen?")
        }
    }
}

/// The "Symbol & Farbe" popover of a category row, anchored to the row like
/// those of accounts and groups.
private struct CategoryIconColorPopover: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: Int64

    func body(content: Content) -> some View {
        content.popover(isPresented: model.iconColorBinding(.category(id)), arrowEdge: .trailing) {
            IconColorPopover(target: .category(id)).environment(model)
        }
    }
}

/// Header of the category tree: chevron, symbol and name like a group header
/// (`UserGroupHeader`), the „+“ for a new main category on the right.
private struct CategoriesHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let open = !model.categoriesCollapsed
        let toggle = { withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.categoriesCollapsed.toggle() } }
        HStack(spacing: 5) {
            // folds the category tree away (rarely used, takes room)
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .appFont(.caption, weight: .bold)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Kategorien einklappen" : "Kategorien ausklappen")
            .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
            Image(systemName: "tag")
                .appFont(.body, weight: .semibold)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Kategorien").lineLimit(1)
            Spacer()
            Button { model.newCategoryRequest = NewCategoryRequest(parent: nil) } label: {
                Image(systemName: "plus").frame(width: 24, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Neue Hauptkategorie …")
            .accessibilityLabel("Neue Hauptkategorie")
            .disabled(!model.isUnlocked)
        }
        .appFont(.body, weight: .semibold) // as big as the group headers
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
