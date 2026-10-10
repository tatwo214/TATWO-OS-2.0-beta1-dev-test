#if DEBUG
import SwiftUI
import AppKit
import Vision

@MainActor enum DeviceFleetUIAcceptance {
    static func fixture() -> DeviceFleetUISnapshot {
        let ids = (0..<8).map { String(format: "%08x-2222-4222-8222-222222222222", $0 + 1) }
        let groups = [
            DeviceFleetGroup(id: "main", name: "example 開發", type: .main, primaryDeviceID: ids[0], managerDisplayName: "example"),
            DeviceFleetGroup(id: "sub", name: "example 公司", type: .sub, primaryDeviceID: ids[3], parentGroupID: "main", managerDisplayName: "example")
        ]
        let devices = ids.enumerated().map { index, id in
            DeviceFleetMember(id: id, name: "fixture-\(index)", factionID: (3...5).contains(index) ? "sub" : "main",
                              role: index >= 6 ? .sandbox : ([0, 3].contains(index) ? .primary : .secondary),
                              clientKeyFingerprint: "SHA256:fixture\(index)", hostKeyFingerprint: nil,
                              clientPublicKey: nil, hostPublicKey: nil,
                              endpoints: [.init(kind: .lan, host: "192.0.2.\(index + 10)", port: 22)], user: "fixture", legacy: true)
        }
        let roster = DeviceFleetRoster(version: 1, primaryID: ids[0], epoch: 1, groups: groups,
                                       devices: devices, edges: DeviceFleetRoster.defaults(groups: groups, devices: devices))
        var graph = DeviceFleetUISnapshot(payload: .init(roster: roster), localID: ids[1])
        for (index, member) in devices.enumerated() {
            let emptyDate = Date()
            let status = DeviceStatusSnapshot(identity: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"),
                appVersion: .init(value: "v2.0.21.050", acquiredAt: emptyDate, reason: nil),
                code: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"),
                constitution: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"),
                skillet: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"),
                rules: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"),
                gbrain: .init(value: nil, acquiredAt: emptyDate, reason: "fixture"))
            graph.status[member.id] = .init(connection: index == 5 ? .sshUnavailable : .reachable,
                                          snapshot: index == 5 ? nil : status, acquiredAt: emptyDate, reason: nil)
        }
        return graph
    }

    static func run() async throws -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"] else {
            throw NSError(domain: "W187UI artifacts required", code: 1)
        }
        let out = URL(fileURLWithPath: raw)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var checks = 0
        func check(_ label: String, _ value: Bool) throws {
            guard value else { throw NSError(domain: "W187UI " + label, code: 1) }
            checks += 1; print("W187UI PASS \(label)")
        }
        let graph = fixture()
        var unknown = graph
        unknown.status = [:]
        try check("missing-status-is-unknown", unknown.connectionLabel(graph.devices[0]) == "尚未確認")
        unknown.status = graph.status
        unknown.status[graph.devices[0].id]?.acquiredAt = Date().addingTimeInterval(-61)
        try check("stale-status-is-unknown", unknown.connectionLabel(graph.devices[0]) == "尚未確認")
        let layout = DeviceFleetGraphLayout(graph)
        try check("one-route-per-enabled-edge", layout.arrows.count == graph.edges.filter { $0.direction != .none }.count)
        // Fifth ruling removes 1 mutual and 2 oneway SUB internal arrows.
        try check("mutual-single-route-two-heads", layout.arrows.filter { $0.edge.direction == .mutual }.count == 3 && layout.arrows.filter { $0.headCount == 2 }.count == 3)
        try check("oneway-single-head", layout.arrows.filter { $0.edge.direction == .oneway }.count == 3 && layout.arrows.filter { $0.headCount == 1 }.count == 3)
        for arrow in layout.arrows {
            for point in [arrow.points.first!, arrow.points.last!] {
                try check("edge-\(arrow.id)-endpoint-clear-of-all-cards", !layout.cards.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(point) })
            }
            let shape = arrow.edge.from.kind == .group ? layout.modules.first { $0.id == arrow.edge.from.id }?.frame
                : layout.cards.first { $0.id == arrow.edge.from.id }?.frame
            try check("edge-\(arrow.id)-source-clearance", shape?.insetBy(dx: -10, dy: -10).contains(arrow.points.first!) == false)
        }
        var stress = graph
        stress.groups.append(.init(id: "sample-sub", name: "sample", type: .sub, primaryDeviceID: "sample", parentGroupID: "main", managerDisplayName: "example"))
        stress.edges.append(.init(from: .group("main"), to: .group("sample-sub"), direction: .oneway, capabilities: []))
        let stressLayout = DeviceFleetGraphLayout(stress)
        try check("multiple-sub-modules-and-edges", stressLayout.modules.count == 3 && stressLayout.arrows.count == layout.arrows.count + 1)
        let mainPrimary = graph.devices.first { $0.role == .primary && $0.groupID == "main" }!
        func staff(_ show: Bool) -> DeviceFleetUISnapshot {
            var group = graph.groups.first { $0.type == .sub }!
            group.showMainPrimary = show
            let slice = DeviceFleetSlice(revision: 1, epoch: 1, targetID: group.primaryDeviceID,
                faction: group.faction, devices: graph.devices.filter { $0.groupID == group.id }, controllers: [],
                revoked: false, primary: show ? DeviceFleetPrimaryDisplay(mainPrimary) : nil, group: group,
                edges: graph.edges.filter { edge in
                    edge.from.kind == .device && edge.to.kind == .device &&
                    graph.devices.contains { $0.id == edge.from.id && $0.groupID == group.id } &&
                    graph.devices.contains { $0.id == edge.to.id && $0.groupID == group.id }
                })
            var result = DeviceFleetUISnapshot(payload: .init(slice: slice), localID: group.primaryDeviceID)
            result.status = graph.status
            return result
        }
        let hidden = staff(false), shown = staff(true)
        try check("staff-hidden-no-main-metadata", hidden.visibleMain == nil && hidden.groups.count == 1 && hidden.devices.allSatisfy { $0.groupID == "sub" })
        try check("staff-opt-in-main-only", shown.visibleMain?.name == mainPrimary.name && shown.devices == hidden.devices)
        // Even if a full roster reaches presentation, hide MAIN for a local SUB device.
        let full = DeviceFleetRoster(version: 1, primaryID: mainPrimary.id, epoch: 1, groups: graph.groups, devices: graph.devices, edges: graph.edges)
        let defensive = DeviceFleetUISnapshot(payload: .init(roster: full), localID: hidden.localID)
        try check("staff-full-roster-defense", defensive.visibleMain == nil && defensive.devices == hidden.devices && defensive.edges == hidden.edges)
        let sandbox = DeviceFleetUISnapshot(payload: .init(roster: full), localID: graph.devices[6].id)
        try check("sandbox-full-roster-defense", sandbox.devices.count == 1 && sandbox.devices[0].id == graph.devices[6].id && sandbox.visibleMain == nil && sandbox.groups.isEmpty)

        let previousTheme = TatwoThemeStore.shared.activeThemeID
        defer { TatwoThemeStore.shared.activeThemeID = previousTheme }
        var evidence: [[String: Any]] = []
        func capture<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false, click: CGPoint? = nil) async throws -> String {
            let scheme: ColorScheme = dark ? .dark : .light
            let host = NSHostingView(rootView: view.padding(24).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(DeviceFleetStyle.canvas(scheme)).environment(\.colorScheme, scheme))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
            if let click {
                let location = CGPoint(x: click.x, y: size.height - click.y)
                for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                        windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
                }
                for _ in 0..<8 { try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "W187UI bitmap", code: 1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), let image = bitmap.cgImage else { throw NSError(domain: "W187UI PNG", code: 1) }
            let url = out.appendingPathComponent(name + ".png")
            try png.write(to: url)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hant", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            try check(name + "-rendered-text", text.contains("fixture"))
            try check(name + "-no-obsolete-role-words", !text.contains("主機") && !text.contains("遙控器"))
            let labels = ["產生配對碼", "輸入配對碼", "改名字", "新增設備", "移交主權", "移除", "儲存"]
            try check(name + "-no-editing-controls", !labels.contains(where: text.contains))
            if name != "toolbar" { try check(name + "-assistant-footer-visible", text.contains("私訊框")) }
            try text.write(to: out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            // Sample the actual card fill in the relation graph, away from its text and border.
            if name.hasPrefix("graph-") {
                let px = Int((24 + layout.cards[0].frame.maxX - 8) * CGFloat(bitmap.pixelsWide) / size.width)
                let py = Int((24 + 64 + layout.cards[0].frame.minY + 8) * CGFloat(bitmap.pixelsHigh) / size.height)
                if let color = bitmap.colorAt(x: px, y: min(py, bitmap.pixelsHigh - 1))?.usingColorSpace(.deviceRGB) {
                    try check(name + "-surface-not-white", color.redComponent < 0.99 || color.greenComponent < 0.99 || color.blueComponent < 0.99)
                } else { try check(name + "-surface-sample", false) }
            }
            evidence.append(["file": url.path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
            print("W187UI PNG \(url.path)")
            return text
        }
        TatwoThemeStore.shared.activeThemeID = .fable5
        _ = try await capture("graph-light", DeviceFleetPage(snapshot: graph), size: CGSize(width: 1030, height: 940))
        let selected = graph.edges.firstIndex { $0.direction == .oneway && $0.from.kind == .group && $0.to.kind == .group }!
        let route = layout.arrows.first { $0.id == selected }!
        let arrowPoint = CGPoint(x: 24 + (route.points.first!.x + route.points.last!.x) / 2,
                                 y: 24 + 64 + (route.points.first!.y + route.points.last!.y) / 2)
        let permission = try await capture("graph-permissions", DeviceFleetPage(snapshot: graph), size: CGSize(width: 1030, height: 940), click: arrowPoint)
        try check("permission-panel-direction-capabilities-and-lock", permission.contains("反方向") && permission.contains("記憶") && permission.contains("TATWO"))
        try check("arrow-real-click-opens-permissions", permission.contains("反方向"))
        TatwoThemeStore.shared.activeThemeID = .aurora
        _ = try await capture("graph-dark", DeviceFleetPage(snapshot: graph), size: CGSize(width: 1030, height: 940), dark: true)
        TatwoThemeStore.shared.activeThemeID = .fable5
        _ = try await capture("list", DeviceFleetPage(snapshot: graph, initialList: true), size: CGSize(width: 930, height: 760))
        var refused = DeviceFleetUISnapshot(payload: .init(roster: full), localID: mainPrimary.id,
            deliveryProblems: [graph.devices[1].id: "projection_refused"])
        refused.status = graph.status
        let refusedText = try await capture("list-projection-refused", DeviceFleetPage(snapshot: refused, initialList: true), size: CGSize(width: 930, height: 820))
        try check("R7-CARDS-02-refusing-device-row-renders-update-action", refusedText.contains("需要更新") && refusedText.contains("新版權限"))
        try check("R8-UI-01-warning-renders-once-in-device-row", refusedText.components(separatedBy: "需要更新").count == 2)
        let toolbar = try await capture("toolbar", DeviceFleetToolbarView(snapshot: graph, initiallyExpanded: graph.devices[1].id), size: CGSize(width: 620, height: 850))
        try check("toolbar-expanded-readonly-details", toolbar.contains("192.0.2.11") && toolbar.contains("簽章") && toolbar.contains("版本"))
        let hiddenText = try await capture("staff-hidden", DeviceFleetPage(snapshot: hidden), size: CGSize(width: 1030, height: 770))
        let shownText = try await capture("staff-shown", DeviceFleetPage(snapshot: shown), size: CGSize(width: 1030, height: 880))
        try check("staff-hidden-render-no-main-name-address-version", !hiddenText.contains(mainPrimary.name) && !hiddenText.contains("192.0.2.10") && !hiddenText.contains("MAIN"))
        try check("staff-shown-render-main-name-no-address", shownText.contains(mainPrimary.name) && !shownText.contains("192.0.2."))
        let manifest: [String: Any] = ["pngs": evidence, "edges": layout.arrows.count,
            "mutual": layout.arrows.filter { $0.headCount == 2 }.count, "oneway": layout.arrows.filter { $0.headCount == 1 }.count,
            "checks": checks, "failures": 0]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("manifest.json"))
        print("W187UI SUMMARY checks=\(checks) failures=0")
        return true
    }
}
#endif
