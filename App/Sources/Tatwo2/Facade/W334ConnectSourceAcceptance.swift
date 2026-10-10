#if DEBUG
import AppKit
import Foundation
import TatwoCEFBridge

extension HandsConnectAcceptance {
    @MainActor final class W334Surface: ChatGPTPodSurface {
        var onMainFrame: ((String?, UInt64, Bool, Int) -> Void)?
        var onPopup: ((TatwoCEFBrowserView) -> Void)?
        var onLoad: ((URL) -> Void)?
        var hello: (() -> Void)?
        var loads: [URL] = []
        var generation: UInt64 = 1
        var url = "https://chatgpt.com/g/project/c/conversation"
        func address(_ value: String, loading: Bool = false, status: Int = 200) {
            url = value
            onMainFrame?(url, generation, loading, status)
        }
        func loadMain(_ target: URL) {
            loads.append(target)
            if let onLoad { onLoad(target); return }
            // CEF first publishes the previous committed URL at the new generation.
            generation += 1
            onMainFrame?(url, generation, true, 0)
            address(target.absoluteString, loading: true, status: 0)
            address(target.absoluteString)
            hello?()
        }
    }

    @MainActor final class W334Transport: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        var commands: [String] = []
        var onReconnect: (() -> Void)?
        var onPress: (() -> Void)?
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func hello() { onEvent?(#"{"type":"hello","loggedIn":true}"#) }
        func run(_ script: String) {
            guard let open = script.range(of: ".command("), script.hasSuffix(")"),
                  let data = String(script[open.upperBound..<script.index(before: script.endIndex)]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = payload["cmd"] as? String, let id = payload["id"] as? String else { return }
            commands.append(cmd)
            let reply: [String: Any]
            switch cmd {
            case "account": reply = ["name": account, "email": "fixture-mail"]
            case "connectorAccount": reply = ["user": "fixture", "workspace": "ws-fixture", "email": "fixture-mail"]
            case "connectorScan": reply = ["loggedIn": true, "listKnown": true, "devMode": true,
                "matches": [["id": "w334-fixture", "name": "TATWO（Primary One）", "auth": "oauth",
                             "serverURL": "https://\(publicHost)/mcp", "connected": false]]]
            case "connectorReconnect": onReconnect?(); reply = ["status": "armed", "form": "fw33412345678"]
            case "connectorPress": reply = ["status": "pressed"]
            default: reply = ["ok": true]
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["type": "result", "id": id, "ok": true, "data": reply]) else { return }
            Task { @MainActor [weak self] in
                self?.onEvent?(String(decoding: body, as: UTF8.self))
                if cmd == "connectorPress" {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self?.onPress?()
                }
            }
        }
    }

    @MainActor static func w334ConnectSource(_ check: Checker, _ base: URL) async throws {
        let plugins = FakePod.plugins
        for (index, path) in ["/g/project/c/conversation", "/g/project/project", "/", "/settings/plugins-settings"].enumerated() {
            let world = try World(base, "w334-accepted-\(index)")
            let transport = W334Transport(), surface = W334Surface()
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let driver = ChatGPTConnectorPod(tap: tap, surface: { surface })
            driver.connectLog = nil
            driver.attach()
            surface.address("https://chatgpt.com" + path)
            surface.hello = { transport.hello() }
            let chat = FakeChatGPT(service: world.service)
            var authorizationFrame: HandsPodFrame?
            driver.onDisplayFrame = { frame in if frame.url?.host == publicHost { authorizationFrame = frame } }
            transport.onReconnect = { surface.address("https://chatgpt.com/settings/plugins-settings/w334-fixture") }
            transport.onPress = {
                _ = try? chat.register(); _ = chat.begin()
                surface.generation += 1
                surface.address(chat.authorizeURL.absoluteString)
            }
            var timeouts = HandsConnectFlow.Timeouts()
            timeouts.exclusive = 1; timeouts.authorizeAppears = 3; timeouts.firstMCP = 3
            let flow = HandsConnectFlow(dependencies: .init(link: { (HandsConnectLocalLink(host: world.host, ownerID: hostID), nil) },
                pod: { driver }, presenter: { world.presenter }, localDeviceID: { hostID }, copy: { _ in }, pollInterval: 0.05, timeouts: timeouts))
            flow.offer()
            _ = await waitUntil(3) { isConfirm(flow.card) }
            flow.connect()
            let paired = await waitUntil(5) { if case .pairing? = flow.card { return true }; return false }
            check(paired && surface.loads == [plugins] && authorizationFrame?.source?.path == "/settings/plugins-settings/w334-fixture"
                  && transport.commands.contains("connectorScan") && transport.commands.filter { $0 == "connectorPress" }.count == 1,
                  "W334 \(path)：先整頁載入外掛頁；SPA 開設定後的來源為外掛設定頁；主機接受", "\(flow.debugLog.suffix(4))")
            if case .pairing(let view)? = flow.card {
                let access = try chat.token(try chat.submit(view.pairingCode ?? ""))
                try chat.tools(access)
                let connected = await waitUntil(5) { flow.phase == .connected }
                check(connected, "W334 \(path)：原有主機核對、兌換 token、首次 MCP、帳號確認通過")
            }
            flow.cancel(reason: "test_done")
            _ = await waitUntil(3) { tap.connectorHold == nil }
        }

        for earlyPopup in [false, true] {
            let transport = W334Transport(), surface = W334Surface()
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let driver = ChatGPTConnectorPod(tap: tap, surface: { surface })
            driver.connectLog = nil; driver.attach()
            surface.address(surface.url); surface.hello = { transport.hello() }
            let acquired = await driver.acquireExclusive(timeout: 1)
            if earlyPopup { driver.simulateNativePopup(key: 334, openerIsMain: true) }
            var anchor: HandsPressAnchor?
            driver.onPressDispatch = { anchor = $0 }
            driver.pressOperation = "w334-negative"
            _ = await driver.reconnect(url: "https://\(publicHost)/mcp", connectorID: "w334-fixture", acknowledged: nil)
            var frame: HandsPodFrame?
            driver.onFrame = { frame = $0 }
            if !earlyPopup {
                surface.address("https://chatgpt.com/g/project/c/answer-link")
                driver.simulateNativePopup(key: 334, openerIsMain: true)
            }
            driver.simulatePopupState(key: 334, url: "https://\(publicHost)/authorize", generation: 1, loading: false)
            let reason = frame.flatMap { f in anchor.flatMap { HandsConnectFlow.anchorProblem(f, anchor: $0, leftChatGPT: false) }
                ?? HandsConnectFlow.provenanceProblem(f, since: anchor?.at ?? .distantFuture) }
            check(acquired && reason == (earlyPopup ? "popup_before_press" : "conversation"),
                  earlyPopup ? "W334 按之前已開的 popup：仍 refused" : "W334 對話裡的連結開授權 popup：仍 refused", reason ?? "nil")
            driver.releaseExclusive()
            _ = await waitUntil(3) { tap.connectorHold == nil }
        }

        for mode in ["timeout", "blocked", "http", "no_hello", "same_document", "cancelled"] {
            let transport = W334Transport(), surface = W334Surface()
            let tap = ChatGPTTap(transport: transport, connection: .ready)
            let driver = ChatGPTConnectorPod(tap: tap, surface: { surface })
            let log = HandsConnectLog(url: base.appendingPathComponent("w334-\(mode)-connect-log.txt"))
            driver.connectLog = log; driver.restoreTimeout = 0.15; driver.attach()
            surface.address(surface.url)
            surface.onLoad = { target in
                switch mode {
                case "blocked": surface.address(surface.url, status: 0)
                case "http": surface.generation += 1; surface.address(target.absoluteString, status: 403); transport.hello()
                case "no_hello": surface.generation += 1; surface.address(target.absoluteString)
                case "same_document": surface.address(target.absoluteString); transport.hello()
                default: surface.address(surface.url, loading: true, status: 0)
                }
            }
            let task = Task { @MainActor in await driver.acquireExclusive(timeout: 1) }
            if mode == "cancelled" { _ = await waitUntil(1) { !surface.loads.isEmpty }; task.cancel() }
            let acquired = await task.value
            check(!acquired && tap.connectorHold == nil && transport.commands.allSatisfy { $0 == "connectorNavigated" }
                  && log.tail().contains { $0.contains("reason=plugins_load_unconfirmed") || mode == "cancelled" },
                  "W334 \(mode)：載入未確認即停止、釋放獨占、不 scan 不按鈕；connect-log 有原因碼")
            surface.onLoad = nil; surface.hello = { transport.hello() }
            let retried = await driver.acquireExclusive(timeout: 1)
            check(retried && surface.loads.last == plugins, "W334 \(mode)：同一 Pod 可重試整頁載入")
            driver.releaseExclusive()
            _ = await waitUntil(3) { tap.connectorHold == nil }
        }

        let failed = try World(base, "w334-failed-flow")
        let transport = W334Transport(), surface = W334Surface()
        let tap = ChatGPTTap(transport: transport, connection: .ready)
        let driver = ChatGPTConnectorPod(tap: tap, surface: { surface })
        driver.restoreTimeout = 0.1; driver.connectLog = nil; driver.attach()
        surface.address(surface.url); surface.onLoad = { _ in }
        let flow = HandsConnectFlow(dependencies: .init(link: { (HandsConnectLocalLink(host: failed.host, ownerID: hostID), nil) },
            pod: { driver }, presenter: { failed.presenter }, localDeviceID: { hostID }, copy: { _ in }, pollInterval: 0.05))
        flow.offer(); _ = await waitUntil(3) { isConfirm(flow.card) }; flow.connect()
        let stopped = await waitUntil(3) { flow.phase == .failed }
        check(stopped && flow.problem?.contains("外掛頁") == true && tap.connectorHold == nil
              && failed.service.auth.windowExpiresAt == nil && !transport.commands.contains("connectorScan")
              && !transport.commands.contains("connectorPress"), "W334 載入失敗：流程顯示可重試原因、主機窗口不開、無按鈕")
        flow.cancel(reason: "test_done")
    }
}
#endif
