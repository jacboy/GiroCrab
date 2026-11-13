import SwiftUI
import GiroCrabCore

// MARK: - Drag payloads (plain strings, so no custom UTType is needed)

enum GroupDrag {
    static let accountPrefix = "girocrab-account:"
    static let groupPrefix = "girocrab-group:"

    static func account(_ id: Int64) -> String { accountPrefix + String(id) }
    static func group(_ uuid: String) -> String { groupPrefix + uuid }

    static func accountID(_ s: String) -> Int64? {
        s.hasPrefix(accountPrefix) ? Int64(s.dropFirst(accountPrefix.count)) : nil
    }

    static func groupUUID(_ s: String) -> String? {
        s.hasPrefix(groupPrefix) ? String(s.dropFirst(groupPrefix.count)) : nil
    }

    /// The group the drag in progress carries (nil = an account), read from
    /// the drag pasteboard so a row knows where it shows the drop line.
    /// iOS has no drag pasteboard: there it counts as an account.
    static var draggedGroup: String? {
        #if os(macOS)
        NSPasteboard(name: .drag).string(forType: .string).flatMap(groupUUID)
        #else
        nil
        #endif
    }

    /// The drop line above (`below` false) or below row `row` as an index for
    /// `moveAccount`, which counts without the moved account. `from` is the
    /// account's own row when it is dragged within its group.
    static func insertionIndex(row: Int, below: Bool, from: Int?) -> Int {
        let at = below ? row + 1 : row
        if let from, from < at { return at - 1 }
        return at
    }
}

// MARK: - Sidebar pieces

/// "Konten" title with visible group actions and the view switch.
/// The switch is a segmented control (a choice of how the list is
/// organised, not a filter); new group and editing are buttons, not
/// hidden in a menu.
struct AccountsSectionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("Konten")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if model.hasArchivedAccounts {
                    Button { withAnimation(Motion.animation(.easeInOut(duration: 0.15))) { model.showArchivedAccounts.toggle() } } label: {
                        Image(systemName: model.showArchivedAccounts ? "archivebox.fill" : "archivebox")
                            .frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .help(model.showArchivedAccounts ? "Archivierte Konten ausblenden" : "Archivierte Konten einblenden")
                    .accessibilityLabel(model.showArchivedAccounts ? "Archivierte Konten ausblenden" : "Archivierte Konten einblenden")
                }
                if model.accountView == .byGroup {
                    // folder symbols: these act on groups, not on accounts
                    Button { model.groupDialog = .create() } label: {
                        Image(systemName: "folder.badge.plus").frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .help("Neue Gruppe …")
                    .accessibilityLabel("Neue Gruppe")
                    Button { model.openGroupSettings() } label: {
                        Image(systemName: "folder.badge.gearshape").frame(width: 24, height: 18).contentShape(Rectangle())
                    }
                    .help("Gruppen bearbeiten …")
                    .accessibilityLabel("Gruppen bearbeiten")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            Picker("Konten anzeigen nach", selection: $model.accountView) {
                Text("Gruppen").tag(AccountSidebarMode.byGroup)
                Text("Kontoart").tag(AccountSidebarMode.byKind)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.top, 12)
    }
}

/// Header of a user group: chevron, symbol, name, sum.
struct UserGroupHeader: View {
    @Environment(AppModel.self) private var model
    /// Selected header: hierarchical styles so macOS can draw them light on the
    /// accent-coloured selection (fixed theme colours stay dark there).
    private var selected: Bool { model.sidebarSelection == SidebarItem.userGroup(group.uuid) }
    let group: UserGroup
    var open: Bool = true
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(open ? "Gruppe einklappen" : "Gruppe ausklappen")
            Image(systemName: group.sfSymbol)
                .font(.body.weight(.semibold))
                // the group's colour, like an account's icon (white when selected)
                .foregroundStyle(selected || group.colorHex.isEmpty
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.readable(hex: group.colorHex)))
                .frame(width: 20)
            Text(group.name).lineLimit(1)
            if !group.inTotal {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Nicht in der Gesamtsumme")
                    .accessibilityLabel("Nicht in der Gesamtsumme")
            }
            Spacer()
            Text(Money.format(group.balanceCents))
                .font(.callout.weight(.semibold)) // same size as the account balances
                .monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(group.balanceCents < 0 ? Theme.negative : Theme.secondary))
                .opacity(group.inTotal ? 1 : 0.6)
        }
        .font(.body.weight(.semibold)) // as big as the account names
        .foregroundStyle(.secondary)
    }
}

/// "Gruppe ▸" submenu for an account (both sidebar views).
struct AccountGroupMenu: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        // named like the group menu's entry, so both menus read the same
        Menu("Verschieben nach", systemImage: "arrow.turn.down.right") {
            ForEach(model.namedUserGroups) { g in
                Toggle(isOn: Binding(
                    get: { account.userGroupUuid == g.uuid },
                    set: { _ in model.moveAccount(account.id, to: g.uuid) }
                )) {
                    Label(g.indentedName, systemImage: g.sfSymbol)
                }
            }
            Toggle(isOn: Binding(
                get: { account.userGroupUuid == nil },
                set: { _ in model.moveAccount(account.id, to: nil) }
            )) {
                Label("Ohne Gruppe", systemImage: "tray")
            }
            Divider()
            Button("Neue Gruppe …", systemImage: "folder.badge.plus") { model.groupDialog = .create(movingAccount: account.id) }
        }
    }
}

/// Names of the account colour palette (tooltips, accessibility).
enum AccountColorNames {
    static let names: [String: LocalizedStringKey] = [
        "#2563EB": "Blau", "#D97706": "Bernstein", "#059669": "Grün", "#DB2777": "Pink",
        "#7C3AED": "Violett", "#0891B2": "Cyan", "#DC2626": "Rot", "#65A30D": "Limette",
        "#C026D3": "Fuchsia", "#EA580C": "Orange", "#4F46E5": "Indigo", "#0D9488": "Petrol",
    ]
}

/// "Symbol & Farbe …" of an account, group or category: colour palette and
/// symbol grid in one popover, like MoneyMoney. A click applies immediately.
struct IconColorPopover: View {
    @Environment(AppModel.self) private var model
    let target: IconColorTarget

    private static let palette = accountColorPalette()
    private static let names = AccountColorNames.names

    private var account: Account? {
        if case .account(let id) = target { return model.account(for: id) }
        return nil
    }
    private var group: UserGroup? {
        if case .group(let uuid) = target { return model.userGroups.first { $0.uuid == uuid } }
        return nil
    }
    private var category: GiroCrabCore.Category? {
        if case .category(let id) = target { return model.categories.first { $0.id == id } }
        return nil
    }
    private var colorHex: String { (account?.colorHex ?? group?.colorHex ?? category?.colorHex ?? "").uppercased() }
    private var symbol: String { account?.sfSymbol ?? group?.sfSymbol ?? category?.sfSymbol ?? "" }
    /// The palette, plus the current colour first if it is not in it (e.g.
    /// from an import), so the current choice is always marked.
    private var swatches: [String] {
        colorHex.isEmpty || Self.palette.contains(colorHex) ? Self.palette : [colorHex] + Self.palette
    }
    /// The chosen colour, else the accent (also marks the current symbol).
    private var tint: Color {
        if let account { return model.accountColor(account.id) }
        return colorHex.isEmpty ? Theme.accent : Color.readable(hex: colorHex)
    }

    private func setColor(_ hex: String?) {
        if let account { model.setAccountColor(account.id, hex: hex) }
        if let group { model.setUserGroupColor(group, hex: hex) }
        if let category, let hex { model.setCategoryColor(category.id, hex: hex) }
    }
    private func setSymbol(_ s: String) {
        if let account { model.setAccountSymbol(account.id, symbol: s) }
        if let group { model.updateUserGroup(group, symbol: s) }
        if let category { model.setCategorySymbol(category.id, symbol: s) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Farbe").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                ForEach(swatches, id: \.self) { hex in
                    Button { setColor(hex) } label: {
                        Circle().fill(Color.readable(hex: hex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: colorHex == hex ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled() // no focus ring on the first swatch
                    .help(Self.names[hex].map { Text($0) } ?? Text(verbatim: hex))
                }
                // a category always has a colour: no "none" for it
                if category == nil {
                    Button { setColor(nil) } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.title3)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusEffectDisabled()
                    .help(account != nil ? Text("Standardfarbe") : Text("Keine Farbe"))
                }
                // any other colour: the system colour well (like the category sheet)
                ColorPicker("Eigene Farbe", selection: Binding(
                    get: { colorHex.isEmpty ? Theme.accent : Color(hex: colorHex) },
                    set: { if let hex = $0.hexRGB { setColor(hex) } }
                ), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 26, height: 20)
                .help("Eigene Farbe")
            }
            .frame(maxWidth: .infinity, alignment: .leading) // under its heading, not centred
            Divider()
            HStack {
                Text("Symbol").font(.headline)
                Spacer()
                // an account's symbol can go back to the one of its kind
                if let account {
                    Button { model.resetAccountSymbol(account.id) } label: {
                        Label("Standardsymbol", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Symbol der Kontoart verwenden")
                }
            }
            // the shared, searchable picker (#167) instead of a fixed list;
            // a click applies the symbol and the popover stays open
            SymbolPicker(selection: Binding(get: { symbol }, set: setSymbol), tint: tint)
                .padding(.horizontal, -14) // full popover width for the grid
        }
        .padding(14)
        .frame(width: SymbolPicker.size.width)
    }
}

/// Context menu of a user group header.
struct UserGroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: UserGroup

    var body: some View {
        #if os(iOS)
        Button("Gruppenübersicht", systemImage: "list.bullet.rectangle") { model.interactiveSidebarSelection = .userGroup(group.uuid) }
        #endif
        if !group.isUngrouped {
            // same order as an account's menu: rename, look, place – then
            // what only groups have – then delete
            Button("Umbenennen …", systemImage: "pencil") { model.groupDialog = .rename(group) }
            Button("Symbol & Farbe …", systemImage: "paintpalette") { model.iconColorTarget = .group(group.uuid) }
            Menu("Verschieben nach", systemImage: "arrow.turn.down.right") {
                Toggle(isOn: Binding(
                    get: { group.parentUuid == nil },
                    set: { _ in model.setUserGroupParent(group, parent: nil) }
                )) {
                    Label("Oberste Ebene", systemImage: "arrow.up.to.line")
                }
                Divider()
                ForEach(model.parentCandidates(for: group)) { g in
                    Toggle(isOn: Binding(
                        get: { group.parentUuid == g.uuid },
                        set: { _ in model.setUserGroupParent(group, parent: g.uuid) }
                    )) {
                        Label(g.indentedName, systemImage: g.sfSymbol)
                    }
                }
            }
            Divider()
            fetchButton
            Toggle(isOn: Binding(
                get: { group.includeInTotal },
                set: { model.updateUserGroup(group, includeInTotal: $0) }
            )) {
                Label("In Gesamtsumme einbeziehen", systemImage: "sum")
            }
            Button("Neue Untergruppe …", systemImage: "folder.badge.plus") { model.groupDialog = .create(parent: group) }
            Divider()
            Button("Gruppe löschen …", systemImage: "trash", role: .destructive) { model.groupDialog = .delete(group) }
        } else {
            fetchButton
        }
    }

    /// Fetches every login behind the group's accounts, like "Alle abrufen".
    private var fetchButton: some View {
        Button("Konten abrufen", systemImage: "arrow.triangle.2.circlepath") { model.requestSyncGroup(group) }
            .disabled(model.syncingConnectionID != nil || model.groupSyncConnections(group).allSatisfy { model.bankingGate(for: $0) != nil })
    }
}

// MARK: - Dialogs (one place for all group dialogs)

/// Presents a group dialog (new / rename / delete / move account) from the
/// given state. The main window passes `model.groupDialog`; the settings
/// pane passes its own state, so each window shows its own dialogs.
struct AccountGroupDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var dialog: GroupDialog?
    @State private var text = ""

    /// Shown while the dialog is of this kind; dismissing clears it unless
    /// an action already switched to another dialog.
    private func presented(text wantsText: Bool) -> Binding<Bool> {
        Binding(
            get: { dialog?.needsText == wantsText },
            set: { if !$0, dialog?.needsText == wantsText { dialog = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(dialog?.title ?? Text(verbatim: ""), isPresented: presented(text: true), presenting: dialog) { d in
                TextField("Name, z. B. „Privat“ oder „Geschäft“", text: $text)
                Button(d.isRename ? "Umbenennen" : "Anlegen") { submit(d) }
                Button("Abbrechen", role: .cancel) {}
            } message: { d in
                if case .create(let id?, _) = d, let a = model.account(for: id) {
                    Text("„\(a.name)“ wird in die neue Gruppe verschoben.")
                }
            }
            .confirmationDialog(
                dialog?.title ?? Text(verbatim: ""),
                isPresented: presented(text: false),
                titleVisibility: .visible,
                presenting: dialog
            ) { d in
                switch d {
                case .delete(let g):
                    Button("Löschen", role: .destructive) { model.deleteUserGroup(g) }
                case .moveAccount(let a):
                    ForEach(model.namedUserGroups) { g in
                        Button { model.moveAccount(a.id, to: g.uuid) } label: {
                            Text(verbatim: a.userGroupUuid == g.uuid ? "✓ \(g.indentedName)" : g.indentedName)
                        }
                    }
                    Button { model.moveAccount(a.id, to: nil) } label: {
                        a.userGroupUuid == nil ? Text(verbatim: "✓ ") + Text("Ohne Gruppe") : Text("Ohne Gruppe")
                    }
                    Button("Neue Gruppe …") {
                        // after this dialog has closed
                        DispatchQueue.main.async { dialog = .create(movingAccount: a.id) }
                    }
                case .merge(let from, let into):
                    Button("Zusammenführen") { model.mergeUserGroups(from, into: into) }
                case .create, .rename, .renameAccount, .renameCategory:
                    EmptyView()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { d in
                switch d {
                case .delete(let g): Text(deleteMessage(g, parent: model.userGroups.first { $0.uuid == g.parentUuid }, subgroups: model.userGroupSubtree(g.uuid).count - 1))
                case .merge(let from, let into):
                    Text("Die Konten aus „\(from.name)“ kommen nach „\(into.name)“. „\(from.name)“ wird entfernt.")
                default: EmptyView()
                }
            }
            .onChange(of: dialog?.initialText) { _, t in text = t ?? "" }
    }

    private func submit(_ d: GroupDialog) {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch d {
        case .create(let accountID, let parent): model.createUserGroup(name: name, moving: accountID, parent: parent?.uuid)
        case .rename(let g):
            // after the alert has closed
            if let next = model.renameUserGroup(g, to: name) { DispatchQueue.main.async { dialog = next } }
        case .renameAccount(let a): model.renameAccount(a.id, to: name)
        case .renameCategory(let c): model.renameCategory(c.id, to: name)
        case .delete, .moveAccount, .merge: break
        }
    }
}

extension View {
    func accountGroupDialogs(_ dialog: Binding<GroupDialog?>) -> some View { modifier(AccountGroupDialogs(dialog: dialog)) }
}

/// Settings › "Kontogruppen": list of groups with +/− below it (macOS:
/// details beside it; iOS: pushed). Changes apply immediately, like the
/// rest of Settings – no Done/Cancel.
struct AccountGroupsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    /// This window's own group dialog (not the main window's).
    @State private var dialog: GroupDialog?

    private var selectedGroup: UserGroup? {
        selection.flatMap { u in model.namedUserGroups.first { $0.uuid == u } }
    }

    var body: some View {
        content
            .onAppear {
                if selection == nil { selection = model.namedUserGroups.first?.uuid }
            }
            .onChange(of: model.namedUserGroups.map(\.uuid)) { old, new in
                // select a group just created here; leave a deleted one
                if let added = new.first(where: { !old.contains($0) }) {
                    selection = added
                } else if let s = selection, !new.contains(s) {
                    selection = new.first
                }
            }
            .accountGroupDialogs($dialog)
    }

    private var footer: LocalizedStringKey {
        model.hasUserGroups
            ? "Reihenfolge per Ziehen ändern, Untergruppen über „Übergeordnete Gruppe“. Konten ohne Gruppe erscheinen unter „Ohne Gruppe“."
            : "Mit Gruppen trennen Sie z. B. private und geschäftliche Konten oder die Konten von Familienmitgliedern."
    }

    #if os(macOS)
    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(model.namedUserGroups) { g in
                            GroupListRow(group: g).tag(g.uuid)
                        }
                        .onMove { model.moveUserGroups(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    Divider()
                    // add/remove square buttons beneath the list (HIG: Buttons › Square buttons)
                    HStack(spacing: 0) {
                        Button { dialog = .create() } label: {
                            Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle())
                        }
                        .help("Neue Gruppe …")
                        .accessibilityLabel("Neue Gruppe")
                        Divider().frame(height: 16)
                        Button { if let g = selectedGroup { dialog = .delete(g) } } label: {
                            Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle())
                        }
                        .disabled(selectedGroup == nil)
                        .help("Gruppe löschen …")
                        .accessibilityLabel("Gruppe löschen")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 2)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 240)
            Group {
                if let uuid = selectedGroup?.uuid {
                    GroupDetailEditor(uuid: uuid, ask: { dialog = $0 }, onGone: { selection = nil })
                        .id(uuid)
                } else {
                    ContentUnavailableView {
                        Label(model.hasUserGroups ? "Keine Gruppe ausgewählt" : "Noch keine Gruppen", systemImage: "folder")
                    } description: {
                        Text(model.hasUserGroups ? "Wählen Sie links eine Gruppe aus." : "Mit + legen Sie die erste Gruppe an.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }
    #else
    private var content: some View {
        List {
            Section {
                ForEach(model.namedUserGroups) { g in
                    NavigationLink(value: g.uuid) { GroupListRow(group: g) }
                }
                .onMove { model.moveUserGroups(from: $0, to: $1) }
                .onDelete { idx in dialog = idx.first.map { .delete(model.namedUserGroups[$0]) } }
            } footer: {
                Text(footer).leadingFooter()
            }
            Section {
                Button("Neue Gruppe …", systemImage: "folder.badge.plus") { dialog = .create() }
            }
        }
        .navigationDestination(for: String.self) { uuid in GroupDetailEditor(uuid: uuid, ask: { dialog = $0 }) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }
    #endif
}

/// A group in the settings list: symbol, name, account count, sum.
struct GroupListRow: View {
    let group: UserGroup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.sfSymbol).foregroundStyle(Theme.accent).frame(width: 22)
                .padding(.leading, CGFloat(group.depth) * 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1)
                Text(accountCountText(group.accounts.count))
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            if !group.inTotal {
                Image(systemName: "eye.slash").foregroundStyle(Theme.tertiary).help("Nicht in der Gesamtsumme")
            }
        }
        .padding(.vertical, 2)
    }
}

/// `parent`: the group `g` is in; `subgroups`: number of groups below it.
func deleteMessage(_ g: UserGroup, parent: UserGroup? = nil, subgroups: Int = 0) -> String {
    let target = parent?.name ?? String(localized: "Ohne Gruppe")
    var parts: [String] = []
    switch g.accounts.count {
    case 0: if subgroups == 0 { return String(localized: "Die Gruppe ist leer.") }
    case 1: parts.append(String(localized: "Das Konto wird nach „\(target)“ verschoben."))
    case let n: parts.append(String(localized: "\(n) Konten werden nach „\(target)“ verschoben."))
    }
    if subgroups > 0 {
        parts.append(parent == nil
            ? String(localized: "Die Untergruppen bleiben erhalten und rücken auf die oberste Ebene.")
            : String(localized: "Die Untergruppen bleiben erhalten und rücken nach „\(target)“."))
    }
    parts.append(String(localized: "Es werden keine Konten oder Buchungen gelöscht."))
    return parts.joined(separator: " ")
}

extension UserGroup {
    /// Name indented by nesting level, for menus and pickers.
    var indentedName: String { String(repeating: "\u{2003}", count: Int(depth)) + name }
}

/// "Keine Konten" / "1 Konto" / "3 Konten".
func accountCountText(_ n: Int) -> String {
    switch n {
    case 0: String(localized: "Keine Konten")
    case 1: String(localized: "1 Konto")
    default: String(localized: "\(n) Konten")
    }
}

/// One group: name, symbol, total switch and which accounts belong to it.
struct GroupDetailEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let uuid: String
    /// Shows a confirmation in the pane (delete, or merge on a name clash).
    var ask: (GroupDialog) -> Void
    /// Called when the group disappears (deleted here or via sync);
    /// default: pop back (iOS navigation).
    var onGone: (() -> Void)?
    @State private var name = ""
    @State private var iconColorOpen = false

    private var group: UserGroup? { model.userGroups.first { $0.uuid == uuid } }

    var body: some View {
        if let g = group {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                }
                Section {
                    // the same "Symbol & Farbe" popover as the sidebar's group menu
                    LabeledContent("Symbol & Farbe") {
                        Button { iconColorOpen = true } label: {
                            Image(systemName: g.sfSymbol)
                                .foregroundStyle(g.colorHex.isEmpty ? Theme.accent : Color.readable(hex: g.colorHex))
                                .frame(width: 24, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.12)))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Symbol & Farbe …"))
                        .popover(isPresented: $iconColorOpen, arrowEdge: .trailing) {
                            IconColorPopover(target: .group(g.uuid)).environment(model)
                        }
                    }
                }
                Section {
                    Picker("Übergeordnete Gruppe", selection: Binding(
                        get: { g.parentUuid ?? "" },
                        set: { model.setUserGroupParent(g, parent: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("Keine (oberste Ebene)").tag("")
                        ForEach(model.parentCandidates(for: g)) { c in
                            Text(verbatim: c.indentedName).tag(c.uuid)
                        }
                    }
                } footer: {
                    Text("Summe, Buchungsliste und Saldoverlauf einer Gruppe enthalten auch ihre Untergruppen.").leadingFooter()
                }
                Section {
                    Toggle("In Gesamtsumme einbeziehen", isOn: Binding(
                        get: { g.includeInTotal },
                        set: { model.updateUserGroup(g, includeInTotal: $0) }
                    ))
                } footer: {
                    Text(g.includeInTotal && !g.inTotal
                         ? "Diese Gruppe liegt in einer Gruppe, die nicht zur Gesamtsumme zählt – ihre Konten zählen deshalb ebenfalls nicht."
                         : "Ausgeschaltet zählen die Konten dieser Gruppe und ihrer Untergruppen nicht zu „Verfügbar“ und zum Saldoverlauf der Übersicht – z. B. für Geschäfts- oder Kinderkonten.")
                    .leadingFooter()
                }
                Section {
                    ForEach(model.allAccounts) { a in
                        let member = a.userGroupUuid == g.uuid
                        Button {
                            model.moveAccount(a.id, to: member ? nil : g.uuid)
                        } label: {
                            HStack(spacing: 9) {
                                AccountSignet(account: a, size: 22, color: model.accountColor(a.id))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name).foregroundStyle(Theme.text)
                                    if !member, let other = model.userGroup(of: a) {
                                        Text("Jetzt in „\(other.name)“").font(.caption2).foregroundStyle(Theme.secondary)
                                    } else {
                                        Text(a.bankName).font(.caption2).foregroundStyle(Theme.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(member ? Theme.accent : Theme.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(member ? .isSelected : [])
                    }
                } header: {
                    Text("Konten")
                } footer: {
                    Text("Ein Konto gehört zu höchstens einer Gruppe.").leadingFooter()
                }
                #if os(iOS)
                Section {
                    Button("Gruppe löschen …", role: .destructive) { ask(.delete(g)) }
                }
                #endif
            }
            .formStyle(.grouped)
            #if os(iOS)
            .navigationTitle(g.name)
            #endif
            .onAppear { name = g.name }
            .onDisappear { commitName() }
        } else {
            // deleted (here or via sync) → back to the list
            Color.clear.onAppear { if let onGone { onGone() } else { dismiss() } }
        }
    }

    /// Saves the edited name, if the group still exists.
    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let g = group, !n.isEmpty, n != g.name else { return }
        if let merge = model.renameUserGroup(g, to: n) {
            name = g.name
            ask(merge)
        }
    }
}
