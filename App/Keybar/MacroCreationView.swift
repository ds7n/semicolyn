// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// A compact human label for one macro event, used in chip previews
/// (modifier glyphs + the key).
func macroEventLabel(_ event: MacroEvent) -> String {
    let base: String
    switch event.key {
    case .char(let c):     base = c == " " ? "␣" : String(c)
    case .enter:           base = "⏎"
    case .tab:             base = "⇥"
    case .escape:          base = "esc"
    case .backspace:       base = "⌫"
    case .arrow(let d):    base = ["up": "↑", "down": "↓", "left": "←", "right": "→"][d.rawValue] ?? "?"
    case .function(let n): base = "F\(n)"
    }
    var mods = ""
    if event.modifiers.control { mods += "⌃" }
    if event.modifiers.option { mods += "⌥" }
    if event.modifiers.shift { mods += "⇧" }
    return mods + base
}

/// Macro authoring: name + a Template or Record body. Template mode parses
/// `{Ctrl+R}docker{Enter}` syntax live; Record mode builds a chip sequence from a
/// text field + special-key buttons (the v1 record surface — live-keybar capture
/// during a session is a follow-up). On Save the macro is persisted to the
/// library and handed to `onSaved`. (keybar-customization spec "Macro creation".)
struct MacroCreationView: View {
    @ObservedObject var store: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss
    /// Receives the saved (already-persisted) macro — e.g. to pre-assign it to a
    /// slot binding the caller is editing.
    var onSaved: (Macro) -> Void = { _ in }

    enum Mode: String, CaseIterable, Identifiable {
        case template = "Template", record = "Record"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var mode: Mode = .template
    @State private var templateText = ""
    @State private var recorder = MacroRecorder()
    @State private var pendingText = ""

    /// The parsed body for the current mode, or nil if the template is malformed.
    private var parsedBody: [MacroEvent]? {
        switch mode {
        case .template: return try? MacroTemplate.parse(templateText)
        case .record:   return recorder.events
        }
    }

    private var templateErrorText: String? {
        guard mode == .template, !templateText.isEmpty else { return nil }
        do { _ = try MacroTemplate.parse(templateText); return nil }
        catch { return describe(error) }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !(parsedBody ?? []).isEmpty
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Deploy", text: $name)
            }
            Section("Mode") {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if mode == .template { templateSection } else { recordSection }
            previewSection
        }
        .navigationTitle("New macro")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
    }

    // MARK: - Template

    @ViewBuilder private var templateSection: some View {
        Section {
            TextField("{Ctrl+R}docker{Enter}", text: $templateText)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Template")
        } footer: {
            if let err = templateErrorText {
                Text(err).foregroundStyle(.red)
            } else {
                Text("Literal text plus {Enter}, {Tab}, {Esc}, {F1}–{F12}, and chords like {Ctrl+R}.")
            }
        }
    }

    // MARK: - Record

    @ViewBuilder private var recordSection: some View {
        Section("Add to sequence") {
            HStack {
                TextField("type literal text", text: $pendingText)
                    .autocorrectionDisabled()
                Button("Add") { appendPending() }
                    .disabled(pendingText.isEmpty)
            }
            specialKeyButtons
        }
        Section("Sequence") {
            if recorder.isEmpty {
                Text("Nothing recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(recorder.events.enumerated()), id: \.offset) { idx, event in
                    Text(macroEventLabel(event)).font(.system(.body, design: .monospaced))
                        .accessibilityLabel("event \(idx + 1)")
                }
                .onDelete { $0.forEach { recorder.removeEvent(at: $0) } }
                .onMove { recorder.moveEvent(from: $0.first ?? 0, to: $1) }
            }
        }
    }

    private var specialKeyButtons: some View {
        let keys: [(String, KeyInput)] = [
            ("⏎", .enter), ("⇥", .tab), ("esc", .escape), ("⌫", .backspace),
            ("␣", .char(" ")), ("↑", .arrow(.up)), ("↓", .arrow(.down)),
            ("←", .arrow(.left)), ("→", .arrow(.right)),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, pair in
                    Button(pair.0) { recorder.record(MacroEvent(key: pair.1)) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder private var previewSection: some View {
        if let body = parsedBody, !body.isEmpty {
            Section("Preview") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(body.enumerated()), id: \.offset) { _, event in
                            Text(macroEventLabel(event))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func appendPending() {
        for ch in pendingText { recorder.record(MacroEvent(key: .char(ch))) }
        pendingText = ""
    }

    private func save() {
        guard let body = parsedBody, !body.isEmpty else { return }
        let macro = Macro(id: store.mintMacroID(),
                          name: name.trimmingCharacters(in: .whitespaces), body: body)
        store.saveMacro(macro)
        onSaved(macro)
        dismiss()
    }

    private func describe(_ error: Error) -> String {
        switch error as? MacroTemplateError {
        case .unterminatedPlaceholder: return "Unclosed “{” — every placeholder needs a “}”."
        case .emptyPlaceholder:        return "Empty “{}” placeholder."
        case .unexpectedCloseBrace:    return "Stray “}” — use “}}” for a literal brace."
        case .danglingModifier:        return "A modifier needs a key, e.g. {Ctrl+R}."
        case .unknownModifier(let m):  return "Unknown modifier “\(m)”."
        case .unknownKey(let k):       return "Unknown key “\(k)”."
        case .unterminatedParameter:   return "Unclosed “${” — every parameter needs a “}”."
        case .emptyParameter:          return "Empty “${}” parameter."
        case .invalidParameterName(let n): return "Invalid parameter name “\(n)” — use letters, digits, or “_”."
        case nil:                      return "Invalid template."
        }
    }
}
