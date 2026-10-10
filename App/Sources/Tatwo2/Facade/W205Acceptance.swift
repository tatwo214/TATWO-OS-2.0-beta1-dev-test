#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Synthetic native components, rendered through the same AppKit host as shipping UI.
@MainActor
enum W205Acceptance {
    static func contrast(_ check: (Bool, String) -> Void, coder: ChatPageModel) throws {
        let palette = TatwoActivePalette.current, appearance = NSApp.appearance
        defer { TatwoActivePalette.current = palette; NSApp.appearance = appearance }
        guard let path = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let out = URL(fileURLWithPath: path)
        let pod = DispatchTapPod(); pod.isRunning = true
        let tap = ChatGPTTap(transport: pod)
        let space = ChatGPTSpaceModel(testTap: tap)
        let webFlag = UserDefaults.standard.object(forKey: ChatGPTWebSpace.enabledKey)
        UserDefaults.standard.set(false, forKey: ChatGPTWebSpace.enabledKey)
        defer { UserDefaults.standard.set(webFlag, forKey: ChatGPTWebSpace.enabledKey) }
        check(!ChatGPTWebSpace.isEnabled, "W280 native sidebar screenshot uses web Space opt-out")
        defer { tap.sleep() }
        let failure = ChatGPTTurnFailure(message: "合成錯誤", reason: nil, draft: "合成草稿")
        for text in ["src/home/index.tsx", "/api/users/1", "src/Users/fixture/index.tsx", "1700000000", "2025550143"] {
            check(ChatGPTLocalText.clean(text, limit: 160) == text && ChatGPTDispatch.rejectionCategory(text) == nil,
                  "W205-6 native normal relative/API path or timestamp survives redaction and dispatch scan: " + text)
        }
        for text in ["12025550143", "120255501430000", "phone 2025550143", "file:///Users/fixture/private.txt", "file:///Volumes/fixture/private.txt", "/Users/fixture/private.txt", "/Volumes/fixture/private.txt", "/home/fixture/private.txt", "0912-345-678", "+886 912 345 678", "phone=2025550143", "電話：0912345678"] {
            check(ChatGPTLocalText.clean(text, limit: 160) != text && ChatGPTDispatch.rejectionCategory(text) != nil,
                  "W205-6 native true local path or protected phone form remains protected")
        }
        check(HandsRedactor.redact("src/Users/fixture/index.tsx") == "src/Users/fixture/index.tsx"
              && HandsRedactor.redact("file:///Users/fixture/private.txt") == "file:///Users/<user>/private.txt"
              && HandsRedactor.redact("/Users/fixture/private.txt") == "/Users/<user>/private.txt",
              "W205-6 shared redactor keeps real file URL and absolute user names private without relative-path false positives")
        let savedPrompt = coder.prompt
        coder.prompt = "合成現有草稿"
        coder.restoreChatGPTInput(failure, in: coder.selectedThreadID!)
        check(coder.prompt == "合成現有草稿\n\n合成草稿", "W205 optional Coder recovery appends without overwriting current draft")
        coder.prompt = savedPrompt
        space.draft = "合成現有草稿"; space.recover(failure)
        check(space.draft == "合成現有草稿\n\n合成草稿", "W205 optional Space recovery preserves existing draft")
        space.draft = "合成新問題"
        space.recover(ChatGPTTurnFailure(message: "合成", reason: "conversation_too_long", draft: "合成舊問題"))
        check(space.draft == "合成新問題\n\n合成舊問題", "W205 optional new-chat recovery carries both current and returned drafts")
        check(ChatGPTDraftRecovery.merge(current: "same", returning: "same") == "same",
              "W205 optional duplicate recovery does not duplicate the current draft")
        space.draft = ""
        let retainedForeground = ChatGlassChipModifier.chipForeground
        var table = "theme,scheme,control,contrast,kind,min_required\n"
        for theme in TatwoTheme.all {
            TatwoActivePalette.current = theme.palette
            for scheme in [ColorScheme.light, .dark] {
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let word = scheme == .dark ? "dark" : "light"
                let prefix = "w205-" + theme.id.rawValue + "-" + word
                let controls: [(String, AnyView, CGRect)] = [
                    ("top-mode", AnyView(WorkspaceSidebarModePicker(modes: [.chat, .chatgpt], selection: .chat, onSelect: { _ in })), CGRect(x: 30, y: 43, width: 138, height: 14)),
                    ("top-mode-unselected", AnyView(WorkspaceSidebarModePicker(modes: [.chat, .chatgpt], selection: .chat, onSelect: { _ in })), CGRect(x: 194, y: 43, width: 137, height: 14)),
                    ("input-model", AnyView(ChatComposerModelLabel(title: "合成模型", suffix: "fast", compact: false, selected: false)), CGRect(x: 133, y: 44, width: 90, height: 12)),
                    ("input-model-suffix", AnyView(ChatComposerModelLabel(title: "合成模型", suffix: "fast", compact: false, selected: false)), CGRect(x: 196, y: 45, width: 18, height: 10)),
                    ("input-mode", AnyView(ChatComposerModeChip(segments: [TatwoComposerMode.modelSegment(title: "合成模型", suffix: "fast", accessibilityTitle: "合成模型", identifier: "fixture.model")], selected: false, action: {})), CGRect(x: 140, y: 44, width: 72, height: 12)),
                    ("input-mode-disabled", AnyView(ChatComposerModeChip(segments: [TatwoComposerMode.modelSegment(title: "合成模型", suffix: "fast", accessibilityTitle: "合成模型", identifier: "fixture.model")], selected: false, action: {}).disabled(true)), CGRect(x: 140, y: 44, width: 72, height: 12)),
                    ("space-search", AnyView(ChatGPTSpaceSidebarList(model: space).frame(height: 500).offset(y: 185)), CGRect(x: 38, y: 33, width: 70, height: 13)),
                    ("error", AnyView(ChatGPTTurnFailureRow(failure: failure, recover: {})), CGRect(x: 148, y: 57, width: 64, height: 12)),
                    ("retry", AnyView(ChatGPTListStatusRow(state: .failed(""), empty: false, emptyText: "", identifier: "fixture", retry: {})), CGRect(x: 171, y: 44, width: 26, height: 12)),
                    ("notice-dismiss", AnyView(HandsConnectEntryPill(text: "合成", help: HandsConnectEntryState.partial(hosts: [], level: nil, text: "").help, dismiss: {}, action: {})), CGRect(x: 199, y: 44, width: 32, height: 12)),
                    ("destructive", AnyView(OSChipButton(title: "停止", role: .destructive, action: {})), CGRect(x: 170, y: 44, width: 20, height: 12)),
                    ("enabled", AnyView(OSChipButton(title: "停止", action: {})), CGRect(x: 170, y: 44, width: 20, height: 12)),
                    ("disabled", AnyView(OSChipButton(title: "停止", action: {}).disabled(true)), CGRect(x: 170, y: 44, width: 20, height: 12)),
                    ("disabled-destructive", AnyView(OSChipButton(title: "停止", role: .destructive, action: {}).disabled(true)), CGRect(x: 170, y: 44, width: 20, height: 12)),
                    ("retained-foreground", AnyView(Text("合成標籤").foregroundStyle(retainedForeground).frame(width: 130, height: 28).chatGlassChip()), CGRect(x: 151, y: 44, width: 58, height: 12)),
                    ("sources-count", AnyView(ChatGPTSourcesButton(model: space, sources: [])), CGRect(x: 192, y: 44, width: 12, height: 12)),
                    ("notice", AnyView(HandsConnectEntryPill(text: "合成連線需確認", help: HandsConnectEntryState.partial(hosts: [], level: nil, text: "").help, action: {})), CGRect(x: 147, y: 44, width: 84, height: 12))
                ]
                var ratios: [String: Double] = [:], inks: [String: (Double, Double, Double)] = [:]
                let enabledPair = ["input-mode-disabled": "input-mode", "disabled": "enabled", "disabled-destructive": "enabled"]   // 停用的危險鍵用中性字
                for (name, view, rect) in controls {
                    guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: CGSize(width: 360, height: 100), scheme: scheme) else {
                        check(false, "W205-1 render " + name); continue
                    }
                    defer { rendered.close() }
                    let ratio = contrastRatio(rendered, rect: rect)
                    print("W205 CONTRAST \(theme.id.rawValue) \(word) \(name) \(String(format: "%.2f", ratio)):1")
                    ratios[name] = ratio
                    if name == "enabled" || name == "destructive" { inks[name] = inkColor(rendered, rect: rect, dark: theme.palette.usesGlass && scheme == .dark) }
                    if let pair = enabledPair[name], let enabled = ratios[pair] {
                        check(ratio >= 3 && ratio <= enabled * 0.8, "W205-1 " + prefix + " " + name + " stays legible (>=3:1) and visibly fainter than " + pair)
                        table += "\(theme.id.rawValue),\(word),\(name),\(String(format: "%.2f", ratio)),disabled,3.0\n"
                    } else {
                        check(ratio >= 4.5, "W205-1 " + prefix + " " + name + " text contrast >=4.5:1")
                        table += "\(theme.id.rawValue),\(word),\(name),\(String(format: "%.2f", ratio)),text,4.5\n"
                    }
                    GlobalDMChatAcceptance.save(rendered, prefix + "-" + name + ".png", to: out)
                }
                // Claude .058：危險鍵的字要看得出紅；選中要有看得見的邊，不只差一級字重。
                if let danger = inks["destructive"], let plain = inks["enabled"] {
                    let red = { (c: (Double, Double, Double)) in c.0 - (c.1 + c.2) / 2 }
                    check(red(danger) >= 0.2 && red(danger) >= red(plain) + 0.15, "W205-1 " + prefix + " destructive ink is visibly red")
                }
                if let on = GlobalDMChatAcceptance.renderSync(Text("合成 chip").frame(width: 130, height: 28).chatGlassChip(isSelected: true),
                                                              size: CGSize(width: 360, height: 100), scheme: scheme),
                   let off = GlobalDMChatAcceptance.renderSync(Text("合成 chip").frame(width: 130, height: 28).chatGlassChip(),
                                                               size: CGSize(width: 360, height: 100), scheme: scheme) {
                    let edge = CGRect(x: 115, y: 47, width: 2, height: 6)
                    let (a, b) = (meanColor(on, rect: edge), meanColor(off, rect: edge))
                    check(max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 0.12, "W205-1 " + prefix + " selected chip edge differs from unselected")
                    GlobalDMChatAcceptance.save(on, prefix + "-chip-selected.png", to: out)
                    on.close(); off.close()
                } else { check(false, "W205-1 render selected chip") }
                if let rim = GlobalDMChatAcceptance.renderSync(
                    Text("合成 chip").frame(width: 130, height: 28).chatGlassChip(),
                    size: CGSize(width: 360, height: 100), scheme: scheme) {
                    let ratio = contrastRatio(rim, rect: CGRect(x: 110, y: 49, width: 9, height: 2))
                    check(ratio >= 1.3, "W205-1 " + prefix + " chip rim is visible against surrounding canvas")
                    table += "\(theme.id.rawValue),\(word),chip-rim,\(String(format: "%.2f", ratio)),rim,1.3\n"
                    GlobalDMChatAcceptance.save(rim, prefix + "-chip-rim.png", to: out)
                    rim.close()
                } else { check(false, "W205-1 render chip rim") }
                for (name, view, size) in [
                    ("coder", AnyView(ChatPage(model: coder, retainedLifecycle: TatwoRetainedChatLifecycle(initiallySelectedChat: true))), CGSize(width: 1120, height: 820)),
                    ("space-sidebar", AnyView(ChatGPTSpaceSidebarList(model: space)), CGSize(width: 260, height: 720)),
                    ("error-row", AnyView(ChatGPTTurnFailureRow(failure: failure, recover: {}).padding(20)), CGSize(width: 500, height: 120))
                ] {
                    guard let rendered = GlobalDMChatAcceptance.renderSync(view, size: size, scheme: scheme) else { check(false, "W205 screenshot " + name); continue }
                    if name == "space-sidebar" {
                        check(!GlobalDMChatAcceptance.identifiers(in: rendered).contains("chatgpt.dots"), "W280 native sidebar has no Dots row")
                    }
                    GlobalDMChatAcceptance.save(rendered, prefix + "-" + name + ".png", to: out)
                    rendered.close()
                }
            }
        }
        try table.write(to: out.appendingPathComponent("w205-contrast.csv"), atomically: true, encoding: .utf8)
    }

    private static func pixels(_ shot: GlobalDMChatAcceptance.Rendered, rect: CGRect) -> [(Double, Double, Double)] {
        let bitmap = shot.bitmap
        let sx = Double(bitmap.pixelsWide) / shot.size.width, sy = Double(bitmap.pixelsHigh) / shot.size.height
        return (Int(rect.minY * sy)..<Int(rect.maxY * sy)).flatMap { y in (Int(rect.minX * sx)..<Int(rect.maxX * sx)).compactMap { x in
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
        } }
    }
    private static func meanColor(_ shot: GlobalDMChatAcceptance.Rendered, rect: CGRect) -> (Double, Double, Double) {
        let all = pixels(shot, rect: rect), n = Double(max(all.count, 1))
        return (all.reduce(0) { $0 + $1.0 } / n, all.reduce(0) { $0 + $1.1 } / n, all.reduce(0) { $0 + $1.2 } / n)
    }
    /// 字的核心像素：深色底取最亮、淺色底取最暗。
    private static func inkColor(_ shot: GlobalDMChatAcceptance.Rendered, rect: CGRect, dark: Bool) -> (Double, Double, Double) {
        let brightness = { (c: (Double, Double, Double)) in c.0 + c.1 + c.2 }
        let all = pixels(shot, rect: rect)
        return (dark ? all.max { brightness($0) < brightness($1) } : all.min { brightness($0) < brightness($1) }) ?? (0, 0, 0)
    }
    private static func contrastRatio(_ shot: GlobalDMChatAcceptance.Rendered, rect: CGRect) -> Double {
        let bitmap = shot.bitmap
        let sx = Double(bitmap.pixelsWide) / shot.size.width, sy = Double(bitmap.pixelsHigh) / shot.size.height
        var darkest = 1.0, lightest = 0.0
        for y in Int(rect.minY * sy)..<Int(rect.maxY * sy) {
            for x in Int(rect.minX * sx)..<Int(rect.maxX * sx) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                func linear(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                let l = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                darkest = min(darkest, l); lightest = max(lightest, l)
            }
        }
        return (lightest + 0.05) / (darkest + 0.05)
    }
}
#endif
