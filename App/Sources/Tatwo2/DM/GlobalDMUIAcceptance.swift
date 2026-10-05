#if DEBUG
import AppKit
import Foundation

/// `TATWO2_SELFTEST=w179ui`：純邏輯驗收 W179 UI 的圖層與版面規則。不建視窗、不讀寫使用者資料。
/// A 蓋層與狀態機、B 停靠框擺位、C 框裡選單的範圍、D 頂列（W184 AB）、E 桌面圓鈕旁的框、F TATWO 輸入框、G 私訊框的訊息列。
enum GlobalDMUIAcceptance {
    @MainActor static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W179UI \(condition ? "PASS" : "FAIL") \(label)")
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { GlobalDMDockLayout.overlaps(a, b) }
        func inside(_ box: CGRect, _ area: CGRect) -> Bool {
            box.minX >= area.minX - 0.001 && box.maxX <= area.maxX + 0.001
                && box.minY >= area.minY - 0.001 && box.maxY <= area.maxY + 0.001
        }

        // MARK: A. 蓋層與狀態機
        check(!GlobalDMMainCover().isCovered, "A1 nothing over the main window is not covered")
        check(GlobalDMMainCover(overlays: ["chat"]).isCovered, "A1 a SwiftUI overlay (settings, search…) covers")
        check(GlobalDMMainCover(sheet: true).isCovered, "A1 a sheet covers")
        check(GlobalDMMainCover(appModal: true).isCovered, "A1 an app-modal confirm covers")
        check(!GlobalDMMainCover(appModal: true, approvalPending: true).isCovered,
              "A1 the tool-approval confirm does not fold the docked box (its 等你核准 row lives there)")
        check(GlobalDMMainCover(overlays: ["chat"], appModal: true, approvalPending: true).isCovered
              && GlobalDMMainCover(sheet: true, approvalPending: true).isCovered,
              "A1 a real cover still folds the docked box while an approval waits")
        check(!GlobalDMMainCover(approvalPending: true).isCovered, "A1 an approval without a modal is not a cover")

        let registry = GlobalDMCoverRegistry()
        registry.set("chat", active: true)
        registry.set("shell", active: true)
        registry.set("chat", active: false)
        check(registry.overlays == ["shell"], "A2 registry keeps each reporter separately")
        registry.set("chat", active: false)
        check(registry.overlays == ["shell"], "A2 clearing twice changes nothing")
        registry.set("shell", active: false)
        check(registry.overlays.isEmpty, "A2 registry empties when every cover is gone")
        let oldView = UUID(), newView = UUID()
        registry.set("chat", active: true, owner: oldView)
        registry.set("chat", active: true, owner: newView)
        registry.set("chat", active: false, owner: oldView)
        check(registry.overlays == ["chat"], "A2 a view rebuilt at launch: the old copy leaving does not clear the new copy's cover")
        registry.set("chat", active: false, owner: newView)
        check(registry.overlays.isEmpty, "A2 the cover goes away when the last copy clears it")

        let covered = GlobalDMDockedPresence.resolve(enabled: true, mainWindowVisible: true, covered: true, boxOpen: true)
        let back = GlobalDMDockedPresence.resolve(enabled: true, mainWindowVisible: true, covered: false, boxOpen: true)
        check(covered == .covered, "A3 covered main window folds the docked button and box away")
        check(back == .shown(boxOpen: true), "A3 when the cover goes away the docked box comes back as it was")
        check(GlobalDMDockedPresence.resolve(enabled: false, mainWindowVisible: true, covered: false, boxOpen: true) == .hidden
              && GlobalDMDockedPresence.resolve(enabled: true, mainWindowVisible: false, covered: false, boxOpen: true) == .hidden,
              "A3 master switch off or main window hidden: nothing docked")
        check(GlobalDMDockedPresence.takesFocus(from: .shown(boxOpen: false), to: .shown(boxOpen: true)),
              "A4 opening the box from the button takes keyboard focus")
        check(!GlobalDMDockedPresence.takesFocus(from: .covered, to: .shown(boxOpen: true))
              && !GlobalDMDockedPresence.takesFocus(from: .hidden, to: .shown(boxOpen: true))
              && !GlobalDMDockedPresence.takesFocus(from: .shown(boxOpen: true), to: .shown(boxOpen: true)),
              "A4 coming back after a cover or with the main window never steals focus")
        check(GlobalDMToggleAction.resolve(enabled: true, floatingOpen: false, appActive: true, mainWindowVisible: false)
              == .openFloating, "A5 ⌥⌘ while the main window is covered opens the floating box")
        check(GlobalDMOpenAction.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: true,
                                         mainWindowVisible: false) == .openFloating,
              "A5 a direct key while the main window is covered opens the floating box")
        // 設定頁「到私訊框設定」走同一個 open()：設定頁本身就是蓋層，所以開的是浮動框（停在直達鍵頁），不是被蓋著的停靠框。
        check(GlobalDMOpenAction.resolve(enabled: true, floatingOpen: false, dockedShowing: false, appActive: true,
                                         mainWindowVisible: !GlobalDMMainCover(overlays: ["chat"]).isCovered) == .openFloating,
              "A5 the settings-page key button opens the floating box while settings cover the main window")
        check(GlobalDMComposerSource.forMode(.chat) == .coder && GlobalDMComposerSource.forMode(.custom("x")) == .coder,
              "A6 chat and custom Spaces use the Coder composer")
        check(GlobalDMComposerSource.forMode(.tatwo) == .tatwo, "A6 TATWO uses its own composer")
        check(GlobalDMComposerSource.forMode(.chatgpt) == .chatgpt, "A6 ChatGPT Space reports its own composer")
        check([ChatRunMode?.some(.cli), .some(.bot), .some(.browser), nil]
              .allSatisfy { GlobalDMComposerSource.forMode($0) == nil },
              "A6 CLI, Bot, Browser and no mode report no composer")
        check(GlobalDMComposerFrames.windowRect(global: CGRect(x: 10, y: 20, width: 100, height: 50), hostHeight: 800,
                                                hostIsFlipped: false) == CGRect(x: 10, y: 730, width: 100, height: 50),
              "A7 SwiftUI global rect flips into an unflipped host")
        check(GlobalDMComposerFrames.windowRect(global: CGRect(x: 10, y: 20, width: 100, height: 50), hostHeight: 800,
                                                hostIsFlipped: true) == CGRect(x: 10, y: 20, width: 100, height: 50),
              "A7 flipped host keeps the rect as is")
        let frames = GlobalDMComposerFrames()
        frames.report(.coder, CGRect(x: 0, y: 0, width: 0.5, height: 40))
        check(frames.frames[.coder] == nil, "A7 a zero-width composer counts as none")
        frames.report(.coder, CGRect(x: 1, y: 2, width: 300, height: 90))
        frames.report(.coder, nil)
        check(frames.frames[.coder] == nil, "A7 a composer that goes away clears its frame")
        let oldComposer = UUID(), newComposer = UUID()
        let rebuilt = CGRect(x: 1, y: 2, width: 300, height: 90)
        frames.report(.coder, CGRect(x: 5, y: 5, width: 300, height: 90), owner: oldComposer)
        frames.report(.coder, rebuilt, owner: newComposer)
        frames.report(.coder, nil, owner: oldComposer)
        check(frames.frames[.coder] == rebuilt,
              "A7 composer rebuilt at launch: the old copy leaving keeps the new copy's frame (docked box stays above it)")
        frames.report(.coder, nil, owner: newComposer)
        check(frames.frames[.coder] == nil, "A7 the owner clearing its own frame removes it")

        // MARK: B. 停靠框擺位（螢幕座標，左下原點）
        let content = CGRect(x: 100, y: 50, width: 1220, height: 849)
        let restingButton = CGRect(x: 1264, y: 58, width: 44, height: 44)
        // B1–B11 驗的是擺位演算法，框大小固定用舊的 320×420 當量尺；實際大小另由 B0 驗。
        let ruler = CGSize(width: 320, height: 420)
        func place(_ area: CGRect, _ composer: CGRect?, mode: ChatRunMode? = .chat, open: Bool = true) -> GlobalDMDockLayout.Placement {
            GlobalDMDockLayout.place(content: area, composer: composer, mode: mode, boxOpen: open, boxSize: ruler)
        }
        // B0（W181）：停靠框＝iPhone Duo 外螢幕 466×678、圓角對照 iPhone 螢幕；放不下時寬高等比縮小，比例不變。
        let duoRatio: CGFloat = 466.0 / 678.0
        check(GlobalDMLayout.box == CGSize(width: 466, height: 678) && GlobalDMLayout.cornerRadius == 52,
              "B0 docked box is the iPhone Duo cover screen (466×678) with an iPhone-like 52pt corner")
        let b0Composer = CGRect(x: 429, y: 76, width: 815, height: 118)
        let tallContent = CGRect(x: 100, y: 50, width: 1220, height: 1000)
        if let box = GlobalDMDockLayout.place(content: tallContent, composer: b0Composer, mode: .chat, boxOpen: true).box {
            check(box.size == GlobalDMLayout.box, "B0 a tall window shows the full 466×678 box")
        } else { check(false, "B0 tall box exists") }
        if let box = GlobalDMDockLayout.place(content: content, composer: b0Composer, mode: .chat, boxOpen: true).box {
            check(box.height < 678 && abs(box.width / box.height - duoRatio) < 0.01
                  && box.minY >= b0Composer.maxY + 12 && box.maxY <= content.maxY - 42,
                  "B0 a MacBook-size window shrinks the box proportionally (\(Int(box.width))×\(Int(box.height))), above the composer")
        } else { check(false, "B0 box exists") }
        var boxes: [(CGRect, CGRect)] = []

        let coder = CGRect(x: 429, y: 76, width: 815, height: 118)
        let b1 = place(content, coder)
        if let box = b1.box {
            boxes.append((box, content))
            check(b1.button == restingButton, "B1 button stays at right 12, bottom 8 when the composer leaves room")
            check(box == CGRect(x: 988, y: 206, width: 320, height: 420), "B1 box is 320×420 above the Coder composer")
            check(box.minY >= coder.maxY + 12 && !overlaps(box, coder) && !overlaps(box, b1.button),
                  "B1 box clears the composer by 12 and never covers the button")
            check(near(box.maxX, b1.button.maxX) && near(box.maxX, content.maxX - 12), "B1 box right edge lines up with the button")
            check(box.maxY <= content.maxY - 42, "B1 box stays under the title band")
        } else { check(false, "B1 box exists") }

        let tatwo = CGRect(x: 429, y: 68, width: 815, height: 89)
        if let box = place(content, tatwo, mode: .tatwo).box {
            boxes.append((box, content))
            check(near(box.minY, 169) && near(box.height, 420) && !overlaps(box, tatwo), "B2 box sits above the TATWO composer")
        } else { check(false, "B2 box exists") }

        let tall = CGRect(x: 429, y: 76, width: 815, height: 300)
        if let box = place(content, tall).box {
            boxes.append((box, content))
            check(near(box.minY, 388) && near(box.height, 420) && !overlaps(box, tall), "B3 box follows a composer that grew")
        } else { check(false, "B3 box exists") }

        let shorter = CGRect(x: 100, y: 50, width: 1220, height: 600)
        if let box = place(shorter, coder).box {
            boxes.append((box, shorter))
            check(near(box.height, 402) && !overlaps(box, coder), "B4 shorter window shrinks the box before touching the composer")
        } else { check(false, "B4 box exists") }

        let short = CGRect(x: 100, y: 50, width: 1220, height: 420)
        let b5 = place(short, coder)
        if let box = b5.box {
            boxes.append((box, short))
            check(near(box.height, 280) && b5.overlapsComposer, "B5 a very short window keeps a 280pt box and only then overlaps")
            check(box.minY >= b5.button.maxY + 10 && box.maxY <= short.maxY - 42 && !overlaps(box, b5.button),
                  "B5 even then the box stays above the button and under the title band")
        } else { check(false, "B5 box exists") }

        let narrow = CGRect(x: 100, y: 50, width: 560, height: 849)
        let narrowComposer = CGRect(x: 112, y: 76, width: 536, height: 118)
        let b6 = place(narrow, narrowComposer)
        if let box = b6.box {
            boxes.append((box, narrow))
            check(near(b6.button.minY, 202), "B6 no room right of the composer: the button rises above it")
            check(near(box.minY, 256) && !overlaps(box, b6.button) && !overlaps(box, narrowComposer)
                  && !overlaps(b6.button, narrowComposer), "B6 box sits above the raised button, clear of the composer")
        } else { check(false, "B6 box exists") }

        let wide = CGRect(x: 100, y: 50, width: 1800, height: 849)
        if let box = place(wide, CGRect(x: 590, y: 76, width: 820, height: 118)).box {
            boxes.append((box, wide))
            check(near(box.minY, 112), "B7 composer not under the box: box sits 10 above the button")
        } else { check(false, "B7 box exists") }

        let b8 = place(content, nil, mode: .chatgpt)
        check(near(b8.button.minY, content.minY + GlobalDMLayout.bottomInset(contentWidth: 1220, mode: .chatgpt)),
              "B8 without a measured composer the button uses the estimate")
        if let box = b8.box { boxes.append((box, content)) }
        // ChatGPT Space（示意數字）：量到的輸入框卡片寬 760；圓鈕右側放得下就留在下 8，框在卡片上方。
        let chatGPT = CGRect(x: 461, y: 66, width: 760, height: 54)
        let b8b = place(content, chatGPT, mode: .chatgpt)
        if let box = b8b.box {
            boxes.append((box, content))
            check(b8b.button == restingButton && box.minY >= chatGPT.maxY + 12 && !overlaps(box, chatGPT),
                  "B8 ChatGPT Space: the box sits above the measured ChatGPT composer, clear of its send button")
        } else { check(false, "B8 ChatGPT box exists") }
        check(place(content, coder, open: false).box == nil, "B9 closed box places only the button")
        // App 剛啟動、輸入框位置還沒回報：框照估計的輸入框高度擺，不蓋上去；圓鈕照舊在下 8。
        let b10 = place(content, nil, mode: .chat)
        if let box = b10.box {
            check(box.minY >= content.minY + GlobalDMDockLayout.estimatedComposerHeight + GlobalDMDockLayout.composerGap
                  && !overlaps(box, coder) && b10.button.minY == restingButton.minY,
                  "B10 composer not reported yet: the box still clears the estimated composer; the button stays put")
        } else { check(false, "B10 box exists") }
        if let box = place(content, nil, mode: .cli).box {
            check(near(box.minY, restingButton.maxY + GlobalDMLayout.gap), "B10 a page without a composer keeps the box right above the button")
        } else { check(false, "B10 CLI box exists") }
        check(!boxes.isEmpty && boxes.allSatisfy { inside($0.0, $0.1) }, "B10 every docked box stays inside the content area")

        // B11：擺框當下用 AppKit 量輸入框（Coder／TATWO 的文字區），不靠 SwiftUI 回報的舊位置。
        let probeWindow = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 1000, height: 700),
                                   styleMask: [.borderless], backing: .buffered, defer: true)
        let probeRoot = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        probeWindow.contentView = probeRoot
        let probeScroll = NSScrollView(frame: NSRect(x: 300, y: 80, width: 600, height: 40))
        probeScroll.documentView = ChatComposerTextView.ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        probeRoot.addSubview(probeScroll)
        let probeContent = probeWindow.convertToScreen(probeRoot.convert(probeRoot.bounds, to: nil))
        if let card = GlobalDMComposerProbe.card(in: probeWindow, content: probeContent) {
            let text = probeWindow.convertToScreen(probeScroll.convert(probeScroll.bounds, to: nil))
            check(near(card.maxY, text.maxY + GlobalDMComposerProbe.cardTopPadding)
                  && near(card.minX, text.minX - GlobalDMComposerProbe.cardSidePadding) && near(card.minY, probeContent.minY),
                  "B11 AppKit probe: composer top = text top + 15, spanning down to the content bottom")
            if let box = GlobalDMDockLayout.place(content: probeContent, composer: card, mode: .chat, boxOpen: true).box {
                check(box.minY >= card.maxY + GlobalDMDockLayout.composerGap && !overlaps(box, card),
                      "B11 the box sits above the probed composer")
            } else { check(false, "B11 box exists") }
        } else { check(false, "B11 AppKit probe finds the composer text view") }
        probeScroll.isHidden = true
        check(GlobalDMComposerProbe.card(in: probeWindow, content: probeContent) == nil, "B11 a hidden composer is ignored")

        // MARK: C. 框裡選單的範圍
        // 選單疊在 GlobalDMBodyRegion（實際量到的「標題列以下、輸入列以上」那一塊）上，位置用 pickerFrame 從那一塊內縮；
        // 這裡驗 pickerFrame。那一塊本身夾在標題列與輸入列之間是畫面結構，由 tests/w179-ui.test.mjs 驗。
        check(GlobalDMMenuLayout.pickerFrame(bodySize: CGSize(width: 320, height: 304)) == CGRect(x: 8, y: 2, width: 304, height: 294),
              "C1 picker sits inside the body with 8pt sides")
        check(near(GlobalDMMenuLayout.pickerFrame(bodySize: CGSize(width: 320, height: 94)).height, 84),
              "C2 picker shrinks with a short body (then scrolls inside)")
        let bodies = [CGSize(width: 320, height: 304), CGSize(width: 320, height: 94), CGSize(width: 390, height: 684),
                      CGSize(width: 389, height: 640), CGSize(width: 320, height: 4)]
        check(bodies.allSatisfy { body in
            let frame = GlobalDMMenuLayout.pickerFrame(bodySize: body)
            return frame.maxY <= max(2, body.height - 8) + 0.001 && frame.minY >= 2 && near(frame.width, body.width - 16)
        }, "C3 picker never reaches the composer row or the header")

        // MARK: D. 頂列（W184 AB：左上目前頁面的圓鈕；✕ 與尺寸鈕拿掉；內橫同一條頂列跨兩欄。W184 F：右上 ⋯、⌄ 也拿掉，
        // 選單改在圓鈕的右鍵；真的畫出來「右上什麼都沒有」在 w184forms D6 驗，這裡只驗版面數字）
        check(DMPhone.headerTop == 14 && DMPhone.headerBottom == 10 && DMPhone.headerHeight == 68 && DMPhone.touch == 44
              && DMPhone.margin == 16 && DMPhone.wideMargin == 20,
              "D0 top bar: 14 on top, 10 below, 44pt buttons (68 high); 16 on the sides, 20 in inner landscape")
        let circle = GlobalDMTopBarLayout.stripFrame(open: false, count: 3, form: .outerPortrait).insetBy(dx: DMPhone.Strip.inset, dy: DMPhone.Strip.inset)
        check(circle == CGRect(x: 16, y: 14, width: 44, height: 44),
              "D1 the top bar keeps only the page circle, top-left 16 in and 14 from the top (⋯ and ⌄ top-right are gone)")
        let wideCircle = GlobalDMTopBarLayout.stripFrame(open: false, count: 3, form: .innerLandscape).insetBy(dx: DMPhone.Strip.inset, dy: DMPhone.Strip.inset)
        check(near(wideCircle.minX, 20) && near(wideCircle.minY, 14)
              && GlobalDMDuoLayout.topBarCount(form: .innerLandscape) == 1 && GlobalDMDuoLayout.topBarCount(form: .tent) == 0,
              "D2 inner landscape has one top bar across both columns (20 from the edge); the tent has none")
        let stripShut = GlobalDMTopBarLayout.stripFrame(open: false, count: 3, form: .outerPortrait)
        let stripOpen = GlobalDMTopBarLayout.stripFrame(open: true, count: 3, form: .outerPortrait)
        check(stripShut == CGRect(x: 12, y: 10, width: 52, height: 52) && near(stripOpen.width, 156) && stripOpen.minX == stripShut.minX,
              "D3 strip: a 52×52 clip (4 outside the 16 margin) shows only the current circle; hover opens it rightward to 156")
        let narrowest = GlobalDMLayout.minimumDockedBoxWidth
        check(stripOpen.maxX <= narrowest - DMPhone.margin,
              "D4 the open strip stays inside the box's right margin, even in the narrowest docked box (nothing top-right to run under)")
        var hover = GlobalDMStripHover()
        hover.hovering(true)
        let opened = hover.isOpen
        hover.picked()
        let pickedShut = !hover.isOpen
        hover.hovering(true)
        let staysShut = !hover.isOpen
        hover.hovering(false)
        hover.hovering(true)
        check(opened && pickedShut && staysShut && hover.isOpen,
              "D5 hover opens the strip, picking a circle folds it (until the pointer leaves), moving away folds it")

        // MARK: E. 桌面圓鈕旁的框
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let bubble = CGRect(origin: GlobalDMDeskLayout.defaultBubbleOrigin(visible: screen), size: CGSize(width: 44, height: 44))
        let small = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: GlobalDMForm.outerPortrait.size, visible: screen)
        check(small.size == GlobalDMForm.outerPortrait.size && near(small.minY, bubble.maxY + 12) && near(small.maxX, bubble.maxX),
              "E1 the outer portrait form opens 12pt above the bubble, right edges aligned")
        let big = GlobalDMDeskLayout.boxBeside(bubble: bubble, wanted: GlobalDMForm.innerLandscape.size, visible: screen)
        // W181：內橫（890×626）比舊的 780×844 矮，圓鈕上方放得下：開在上方、右緣對齊（放不下才去旁邊，見 desk 自測）。
        check(big.size == GlobalDMForm.innerLandscape.size && near(big.minY, bubble.maxY + 12) && near(big.maxX, bubble.maxX)
              && inside(big, screen.insetBy(dx: 8, dy: 8)),
              "E2 inner landscape (890×626) opens above the bubble at full size, on screen")
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: 0, y: 25, width: 1024, height: 640),
                       CGRect(x: 0, y: 0, width: 1728, height: 1080), CGRect(x: -2560, y: 0, width: 2560, height: 1415)]
        var gridCount = 0, gridBad: [String] = []
        for visible in screens {
            let side: CGFloat = 44
            let saved: [CGPoint?] = [
                nil,
                CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX - side, y: visible.minY),
                CGPoint(x: visible.minX, y: visible.maxY - side), CGPoint(x: visible.maxX - side, y: visible.maxY - side),
                CGPoint(x: visible.midX - side / 2, y: visible.minY), CGPoint(x: visible.midX - side / 2, y: visible.maxY - side),
                CGPoint(x: visible.minX, y: visible.midY - side / 2), CGPoint(x: visible.maxX - side, y: visible.midY - side / 2),
            ]
            for spot in saved {
                let origin = GlobalDMDeskLayout.placeBubble(saved: spot, visibleFrames: [visible], main: visible)
                let knob = CGRect(origin: origin, size: CGSize(width: side, height: side))
                for size in GlobalDMForm.allCases {
                    gridCount += 1
                    let wanted = size.size
                    let box = GlobalDMDeskLayout.boxBeside(bubble: knob, wanted: wanted, visible: visible)
                    let ok = !overlaps(box, knob.insetBy(dx: -12, dy: -12))
                        && inside(box, visible.insetBy(dx: 8, dy: 8))
                        && box.width <= wanted.width + 0.001 && box.height <= wanted.height + 0.001
                        && box.width >= 1
                        && abs(box.width / box.height - wanted.width / wanted.height) < 0.01
                    if !ok { gridBad.append("\(Int(visible.width))x\(Int(visible.height)) at \(Int(origin.x)),\(Int(origin.y)) \(size.rawValue) → \(box)") }
                }
            }
        }
        check(gridCount == 144 && gridBad.isEmpty,
              "E3 4 screens × 9 bubble spots × 4 forms: never under the bubble, on screen, scaled evenly"
                + (gridBad.isEmpty ? "" : " — " + gridBad.prefix(3).joined(separator: "; ")))

        // MARK: F. TATWO 輸入框
        let hintFirst = AssistantComposerStatus.resolve(hint: "這句沒送出", placementNote: "連不上", isConnecting: false,
                                                        isDelivering: true, isRunning: true)
        check(hintFirst.text == "這句沒送出" && hintFirst.tone == .hint && hintFirst.identifier == "tatwo-assistant-primary-hint",
              "F1 a send failure hint wins over everything")
        let connecting = AssistantComposerStatus.resolve(hint: nil, placementNote: "正在連主設備「Primary One」…", isConnecting: true,
                                                         isDelivering: false, isRunning: false)
        check(connecting.tone == .working && connecting.identifier == "tatwo-assistant-offline",
              "F2 connecting to the primary shows as in progress")
        let offline = AssistantComposerStatus.resolve(hint: nil, placementNote: "主設備「Primary One」連不上", isConnecting: false,
                                                      isDelivering: true, isRunning: false)
        check(offline.text == "主設備「Primary One」連不上" && offline.tone == .warning,
              "F3 unreachable or local-fallback note shows as a warning")
        check(AssistantComposerStatus.resolve(hint: nil, placementNote: nil, isConnecting: false, isDelivering: true, isRunning: true)
              == AssistantComposerStatus(text: "送到主設備…", tone: .working, identifier: "tatwo-assistant-status"),
              "F4 delivering to the primary shows as in progress")
        check(AssistantComposerStatus.resolve(hint: nil, placementNote: nil, isConnecting: false, isDelivering: false, isRunning: true)
              == AssistantComposerStatus(text: "工作中", tone: .working, identifier: "tatwo-assistant-status"),
              "F5 replying shows 工作中 like Coder")
        let quiet = AssistantComposerStatus.resolve(hint: nil, placementNote: nil, isConnecting: false, isDelivering: false, isRunning: false)
        check(quiet.text == nil && quiet.tone == .quiet, "F6 nothing to say: the drawer has no text (no permanent primary line)")
        check(near(AssistantSpacePane.columnWidth(paneWidth: 1200), 820) && near(AssistantSpacePane.columnWidth(paneWidth: 500), 464)
              && near(AssistantSpacePane.columnWidth(paneWidth: 300), 320),
              "F7 TATWO column width matches Coder (max 820, 18pt sides, min 320)")

        // 模型 chip 的系統選單：第一行說明在哪台跑（不能點）、每個品牌一段、選中打勾、停用反灰；點了回傳那個路由。
        let brandRoutes = ChatRouteBrandGroup.pickerOrder.compactMap { brand in ChatRouteChoice.all.first { $0.brandGroup == brand } }
        if brandRoutes.count >= 2 {
            let picked = PickedRoute()
            let options = [AssistantModelOption(route: brandRoutes[0], title: "Route A", isDisabled: false, isSelected: true),
                           AssistantModelOption(route: brandRoutes[1], title: "Route B", isDisabled: true, isSelected: false)]
            let menu = AssistantModelMenu.makeMenu(primaryName: "Primary One", options: options) { picked.id = $0 }
            let first = menu.items.first
            let routeA = menu.items.firstIndex { $0.title == "Route A" }
            let routeB = menu.items.first { $0.title == "Route B" }
            check(first?.title.hasPrefix("在主設備「Primary One」上跑") == true && first?.isEnabled == false
                  && menu.items.filter(\.isSectionHeader).count == 2,
                  "F8 model menu: primary line first and not clickable, one section per brand")
            check(routeA.map { menu.items[$0].state == .on && menu.items[$0].isEnabled } == true
                  && routeB?.state == .off && routeB?.isEnabled == false,
                  "F8 model menu: the chosen route is ticked, a disabled engine is greyed out")
            // 直接照選單項目的 target／action 送一次（無頭自測沒有跑中的選單，不用 performActionForItem）。
            if let routeA, let action = menu.items[routeA].action, let target = menu.items[routeA].target as? NSObject {
                _ = target.perform(action, with: menu.items[routeA])
            }
            check(picked.id == brandRoutes[0].id, "F8 model menu: picking a route sets the assistant's model")
        } else {
            check(false, "F8 model menu needs routes from two brands")
        }

        // MARK: G. 私訊框的訊息列（同 TATWO 助理頁：回覆中還沒出字時有打字點點、系統說明全部顯示）
        let asked = ChatMessage(id: "u1", role: .user, text: "幫我看一下")
        let waiting = GlobalDMBubble.rows([asked], running: true)
        check(waiting.map(\.kind) == [.mine, .typing] && waiting.last?.id == GlobalDMBubble.typingID,
              "G1 replying with no text yet: a typing row after the question")
        let emptyAnswer = ChatMessage(id: "a0", role: .assistant, text: "", modelID: "route-x")
        let earlier = ChatMessage(id: "a1", role: .assistant, text: "先前的回答", modelID: "route-x")
        let typing = GlobalDMBubble.rows([earlier, asked, emptyAnswer], running: true)
        // W184 C：回覆與打字列不畫頭像（對照稿）；模型仍跟著打字列，拿來說「誰在回覆」。
        check(typing.last?.kind == .typing && typing.last?.modelID == "route-x" && !typing.contains { $0.id == "a0" },
              "G2 the typing row knows the thread's model (says who is replying; no avatar since W184); the empty answer is not a row")
        let answering = ChatMessage(id: "a2", role: .assistant, text: "開始回答了", modelID: "route-x")
        check(GlobalDMBubble.rows([asked, answering], running: true).map(\.kind) == [.mine, .theirs],
              "G3 once the answer has text the typing row goes away")
        check(GlobalDMBubble.rows([asked], running: false).map(\.kind) == [.mine], "G4 not replying: no typing row")
        let notes = [ChatMessage(id: "n1", role: .system, text: "已允許 Bash", status: "info|權限"),
                     ChatMessage(id: "n2", role: .system, text: "PR 作業處理中，請等目前工作結束。", status: "info|PR"),
                     ChatMessage(id: "n3", role: .system, text: "完成", status: "done")]
        check(GlobalDMBubble.rows(notes).map(\.kind) == [.note, .note, .note],
              "G5 every system note shows like the TATWO page (not only PR notes)")
        let tapRows = GlobalDMBubble.rows([TapMessage(id: "t1", role: .user, text: "嗨"),
                                           TapMessage(id: "t2", role: .assistant, text: "")], answering: true)
        check(tapRows.map(\.kind) == [.mine, .typing] && !tapRows.contains { $0.text == "…" },
              "G6 ChatGPT uses the same typing row, not a literal …")

        print("W179UI SUMMARY failures=\(failed) passed=\(passed)")
        return failed == 0
    }

    /// F8：記住選單回傳的路由。
    @MainActor private final class PickedRoute {
        var id: String?
    }
}
#endif
