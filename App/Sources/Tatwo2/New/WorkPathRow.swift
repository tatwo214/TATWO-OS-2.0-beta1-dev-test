import AppKit
import SwiftUI

struct WorkPathRow: View {
    var entry = TatwoEntry()
    var isSetup = false
    @State private var path = ""
    @State private var isDefault = true
    @State private var message: String?
    @State private var busy = false
    #if DEBUG
    var testFolder: URL?
    var testNotice: String?
    var testProbe: W284Acceptance.Probe?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作路徑").font(.system(size: 13.5, weight: .semibold))
                    if isSetup {
                        Text("施工房、預覽 App、建置產物放這裡。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSetup {
                    SetupStateChip(state: isDefault ? .defaulted : .done)
                        .accessibilityIdentifier(isDefault ? "workpath.state.default" : "workpath.state.done")
                }
                else if isDefault { Text("預設").font(.caption).foregroundStyle(.secondary) }
                OSChipButton(title: isSetup ? "更改 ›" : "更改…") { choose() }.accessibilityIdentifier("workpath.choose")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.frames["workpath.choose"] = $0 }
                    #endif
                if !isSetup && !isDefault {
                    OSChipButton(title: "還原預設") { save(nil) }.accessibilityIdentifier("workpath.reset")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.frames["workpath.reset"] = $0 }
                        #endif
                }
            }
            .disabled(busy)
            if !isSetup {
                Text(path.isEmpty ? WorkPath.defaultURL(entry).path : path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("施工房、預覽 App、建置產物與證據放在這裡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workpath.row")
        .task { refresh() }
    }
    private func choose() {
        #if DEBUG
        if let testFolder { save(testFolder); return }
        #endif
        let panel = NSOpenPanel()
        panel.title = "選擇工作路徑"; panel.prompt = "選擇"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? WorkPath.defaultURL(entry).path : path)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { save(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func refresh() { run(nil, writing: false) }
    private func save(_ url: URL?) { run(url, writing: true) }
    private func run(_ url: URL?, writing: Bool) {
        guard !busy else { return }; busy = true
        Task.detached {
            let result = Result<(URL, String?), Error> {
                let note = writing ? try WorkPath.set(url, entry: entry) : nil
                let current = try WorkPath.current(entry)
                if !writing {
                    do { return (current, try WorkPath.validate(current)) }
                    catch { return (current, error.localizedDescription) }
                }
                return (current, note)
            }
            await MainActor.run {
                busy = false
                switch result {
                case .success(let value):
                    path = value.0.path; isDefault = path == WorkPath.defaultURL(entry).path; message = value.1
                case .failure(let error): message = error.localizedDescription
                }
                #if DEBUG
                if !writing, let testNotice { message = testNotice }
                #endif
            }
        }
    }
}
