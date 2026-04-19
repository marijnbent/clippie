import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

/// Settings view for configuring clippie preferences
struct SettingsView: View {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var snippetStore = SnippetStore.shared
    @StateObject private var accessibilityPermission = AccessibilityPermissionViewModel()
    @State private var isRecording = false
    @State private var recordedKeyCode: UInt16 = 0
    @State private var recordedModifiers = HotkeyModifiers()
    @State private var showingTrimAlert = false
    @State private var pendingTier: HistoryLimit?
    @State private var editingSnippet: SnippetDraft?
    @State private var snippetErrorMessage: String?
    
    var body: some View {
        Form {
            keyboardSection
            systemSection
            snippetsSection
        }
        .formStyle(.grouped)
        .alert("Reduce History Retention?", isPresented: $showingTrimAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reduce & Delete", role: .destructive) {
                if let tier = pendingTier {
                    settings.historyLimit = tier
                    settings.save()
                }
            }
        } message: {
            Text("This will permanently delete clipboard history older than \(pendingTier?.label ?? "the selected period"). This action cannot be undone.")
        }
        .alert("Snippet", isPresented: Binding(
            get: { snippetErrorMessage != nil },
            set: { if !$0 { snippetErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(snippetErrorMessage ?? "")
        }
        .sheet(item: $editingSnippet) { draft in
            SnippetEditorSheet(draft: draft) { updatedDraft in
                saveSnippetDraft(updatedDraft)
            }
        }
        .background(KeyRecorder(isRecording: $isRecording) { keyCode, modifiers in
            settings.hotkeyKeyCode = keyCode
            settings.hotkeyModifiers = modifiers
            settings.save()
            isRecording = false
        })
        .onAppear {
            accessibilityPermission.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityPermission.refresh()
        }
        .frame(
            minWidth: ClippieSettingsWindowMetrics.width,
            idealWidth: ClippieSettingsWindowMetrics.width,
            maxWidth: ClippieSettingsWindowMetrics.width,
            minHeight: ClippieSettingsWindowMetrics.height,
            idealHeight: ClippieSettingsWindowMetrics.height,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var keyboardSection: some View {
        Section {
            LabeledContent {
                Button(isRecording ? "Cancel" : "Change") {
                    isRecording.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut")
                    Text(isRecording ? "Press shortcut..." : shortcutDisplay)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Use Change to record a new keyboard shortcut.")
        }
    }
    
    private var systemSection: some View {
        Group {
            Section {
                accessibilityPermissionRow
            } header: {
                Text("Permissions")
            }

            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { newValue in
                        SettingsManager.shared.toggleLaunchAtLogin(newValue)
                        DispatchQueue.main.async {
                            settings.launchAtLogin = SettingsManager.shared.launchAtLogin
                        }
                    }

                Picker("Keep history", selection: $settings.historyLimit) {
                    ForEach(HistoryLimit.allCases, id: \.self) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
                .onChange(of: settings.historyLimit) { newValue in
                    if newValue.rawValue < SettingsManager.shared.historyLimit.rawValue {
                        pendingTier = newValue
                        settings.historyLimit = SettingsManager.shared.historyLimit
                        showingTrimAlert = true
                    } else {
                        settings.historyLimit = newValue
                        settings.save()
                    }
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Choose how long clipboard history should be kept.")
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        LabeledContent {
            Button(accessibilityPermission.isTrusted ? "Open Settings" : "Request") {
                if accessibilityPermission.isTrusted {
                    accessibilityPermission.openSystemSettings()
                } else {
                    accessibilityPermission.requestAccess()
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text(accessibilityPermission.isTrusted ? "Granted" : "Not granted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Circle()
                    .fill(accessibilityPermission.isTrusted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    private var snippetsSection: some View {
        Section {
            if snippetStore.snippets.isEmpty {
                Text("No snippets yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snippetStore.snippets) { snippet in
                    snippetRow(snippet)
                }
            }
        } header: {
            Text("Snippets")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Button("Add Snippet") {
                    editingSnippet = SnippetDraft()
                }
                Text("Type : in any text field to search and insert snippets.")
            }
        }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Edit") {
                    editingSnippet = SnippetDraft(snippet: snippet)
                }
                .controlSize(.small)

                Button {
                    snippetStore.deleteSnippet(id: snippet.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Delete snippet")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(":\(snippet.trigger)")
                        .lineLimit(1)

                    Text(snippetSummary(snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var shortcutDisplay: String {
        "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
    }

    private func snippetSummary(_ snippet: Snippet) -> String {
        snippet.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func saveSnippetDraft(_ draft: SnippetDraft) -> Bool {
        do {
            try snippetStore.saveSnippet(
                id: draft.snippetID,
                title: "",
                trigger: draft.trigger,
                content: draft.content
            )
            return true
        } catch {
            snippetErrorMessage = error.localizedDescription
            return false
        }
    }
}

/// Records keyboard shortcuts when active
struct KeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt16, HotkeyModifiers) -> Void
    
    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        view.onRecord = onRecord
        return view
    }
    
    func updateNSView(_ nsView: KeyRecorderView, context: Context) {
        nsView.isRecording = isRecording
        nsView.updateWindowLevel()
        
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeKeyAndOrderFront(nil)
                nsView.window?.makeFirstResponder(nsView)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

class KeyRecorderView: NSView {
    var isRecording = false
    var onRecord: ((UInt16, HotkeyModifiers) -> Void)?
    private var previousWindowLevel: NSWindow.Level?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            // Use a tiny delay to allow the window to be properly added to the window list
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.isRecording {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
    
    func updateWindowLevel() {
        guard let window else { return }
        
        if isRecording {
            if previousWindowLevel == nil {
                previousWindowLevel = window.level
            }
            window.level = .floating
        } else if let previousWindowLevel {
            window.level = previousWindowLevel
            self.previousWindowLevel = nil
        }
    }
    
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        
        // Ignore modifier-only presses
        if event.keyCode == 56 || event.keyCode == 59 || event.keyCode == 58 || event.keyCode == 55 {
            return
        }
        
        let mods = HotkeyModifiers(
            shift: event.modifierFlags.contains(.shift),
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control)
        )
        
        // Require at least one modifier
        if mods.shift || mods.command || mods.option || mods.control {
            onRecord?(event.keyCode, mods)
        }
    }
}

/// ViewModel wrapper for SettingsManager to avoid crashes
class SettingsViewModel: ObservableObject {
    @Published var hotkeyModifiers: HotkeyModifiers
    @Published var hotkeyKeyCode: UInt16
    @Published var launchAtLogin: Bool
    @Published var historyLimit: HistoryLimit
    
    init() {
        self.hotkeyModifiers = SettingsManager.shared.hotkeyModifiers
        self.hotkeyKeyCode = SettingsManager.shared.hotkeyKeyCode
        self.launchAtLogin = SettingsManager.shared.launchAtLogin
        self.historyLimit = SettingsManager.shared.historyLimit
    }
    
    func save() {
        SettingsManager.shared.hotkeyModifiers = hotkeyModifiers
        SettingsManager.shared.hotkeyKeyCode = hotkeyKeyCode
        SettingsManager.shared.historyLimit = historyLimit
        SettingsManager.shared.save()
        
        NotificationCenter.default.post(name: .bufferHotkeyChanged, object: nil)
        NotificationCenter.default.post(name: .bufferHistoryLimitChanged, object: nil)
    }
}

@MainActor
final class AccessibilityPermissionViewModel: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    
    var statusText: String {
        if isTrusted {
            return "Granted. clippie can monitor and control text input where needed."
        }
        return "Not granted. Needed for Accessibility-based input features."
    }
    
    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }
    
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.refresh()
        }
    }
    
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        
        NSWorkspace.shared.open(url)
    }
}

private struct SnippetDraft: Identifiable {
    let id = UUID()
    var snippetID: UUID?
    var trigger: String
    var content: String
    
    init(snippetID: UUID? = nil, trigger: String = "", content: String = "") {
        self.snippetID = snippetID
        self.trigger = trigger
        self.content = content
    }
    
    init(snippet: Snippet? = nil) {
        self.snippetID = snippet?.id
        self.trigger = snippet?.trigger ?? ""
        self.content = snippet?.content ?? ""
    }
}

private struct SnippetEditorSheet: View {
    let draft: SnippetDraft
    let onSave: (SnippetDraft) -> Bool
    
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: SnippetEditorFocusedField?
    @State private var trigger: String
    @State private var content: String
    
    init(draft: SnippetDraft, onSave: @escaping (SnippetDraft) -> Bool) {
        self.draft = draft
        self.onSave = onSave
        _trigger = State(initialValue: draft.trigger)
        _content = State(initialValue: draft.content)
    }

    private func save() {
        let didSave = onSave(
            SnippetDraft(
                snippetID: draft.snippetID,
                trigger: trigger,
                content: content
            )
        )
        if didSave {
            dismiss()
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.snippetID == nil ? "Add Snippet" : "Edit Snippet")
                .font(.system(size: 15, weight: .semibold))
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Trigger")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("iban", text: $trigger)
                    .focused($focusedField, equals: .trigger)
                    .onSubmit {
                        save()
                    }
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .focused($focusedField, equals: .content)
                    .font(.system(size: 12))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .trigger
            }
        }
        .onPasteCommand(of: [UTType.plainText]) { providers in
            guard let provider = providers.first else { return }
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                Task { @MainActor in
                    switch focusedField {
                    case .trigger:
                        trigger += string
                    case .content:
                        content += string
                    case nil:
                        content += string
                    }
                }
            }
        }
    }
}

private enum SnippetEditorFocusedField: Hashable {
    case trigger
    case content
}
