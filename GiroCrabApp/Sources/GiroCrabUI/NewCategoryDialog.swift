import SwiftUI
import GiroCrabCore

/// A pending "new category" sheet; `parent == nil` creates a main category.
struct NewCategoryRequest: Identifiable, Equatable {
    let id = UUID()
    var parent: Int64?
}

/// Sheet for a new category: name, symbol and colour (#168), driven by
/// `model.newCategoryRequest`. Changing an existing category goes through
/// its context menu, like accounts and groups (Umbenennen, Symbol & Farbe,
/// Verschieben nach).
struct NewCategoryDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.newCategoryRequest) { request in
                NewCategorySheet(request: request).environment(model)
            }
    }
}

struct NewCategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewCategoryRequest

    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var colorHex = "#7A808A"

    private static let palette = accountColorPalette()
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The palette plus the current colour, if that is not in it.
    private var colors: [String] {
        Self.palette.contains(colorHex.uppercased()) ? Self.palette : [colorHex.uppercased()] + Self.palette
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    SymbolPickerButton(selection: $symbol, tint: Color.readable(hex: colorHex))
                    LabeledContent("Farbe") {
                        HStack(alignment: .top, spacing: 10) {
                            ColorSwatches(colors: colors, selection: $colorHex)
                            // any other colour: the system colour well
                            ColorPicker("Eigene Farbe", selection: Binding(
                                get: { Color(hex: colorHex) },
                                set: { if let hex = $0.hexRGB { colorHex = hex } }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 28, height: 22)
                            .help("Eigene Farbe")
                        }
                    }
                } footer: {
                    if let path = model.categoryPath(request.parent) {
                        Text("Wird angelegt unter „\(path)“.").leadingFooter()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.parent == nil ? "Neue Hauptkategorie" : "Neue Unterkategorie")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .onAppear {
            // a sub-category starts with its main category's colour
            if let p = request.parent.flatMap({ p in model.categories.first { $0.id == p } }) {
                colorHex = p.colorHex.uppercased()
            }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        model.createCategory(name: trimmed, parent: request.parent, symbol: symbol, color: colorHex)
        dismiss()
    }
}

/// A row of colour circles with a ring around the chosen one – the colour
/// row of Reminders' list editor.
struct ColorSwatches: View {
    let colors: [String]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                let chosen = hex == selection.uppercased()
                Button { selection = hex } label: {
                    Circle()
                        .fill(Color.readable(hex: hex))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(Circle().strokeBorder(chosen ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text(AccountColorNames.names[hex] ?? LocalizedStringKey(hex)))
                .accessibilityLabel(Text(AccountColorNames.names[hex] ?? LocalizedStringKey(hex)))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .frame(maxWidth: 200)
    }
}

extension View {
    func newCategoryDialog() -> some View { modifier(NewCategoryDialog()) }
}
