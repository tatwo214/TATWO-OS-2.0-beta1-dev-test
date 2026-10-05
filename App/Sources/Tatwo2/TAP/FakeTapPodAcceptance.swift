#if DEBUG
import Foundation

/// Shared in-memory TAP transport. Responders use the native wire shape; no CEF or network.
@MainActor class FakeTapPod: ChatGPTPodTransport {
    var onEvent: ((String) -> Void)?
    var onDisplayFrame: ((String?, UInt64, Bool, Int) -> Void)?
    var isRunning: Bool
    var pagePresented = false, spaceVisible = false, workActive = false
    var isHosted: Bool { pagePresented }
    var hidden: Bool { TapWebPod.shouldHide(spaceVisible: spaceVisible, workActive: workActive, pagePresented: pagePresented) }
    var displayGeneration: UInt64 = 0
    var starts = 0
    var commands: [[String: Any]] = []
    var sends: [[String: Any]] { commands.filter { $0["cmd"] as? String == "send" } }
    var responder: ((String, [String: Any]) -> [String: Any]?)?
    init(running: Bool = false, responder: ((String, [String: Any]) -> [String: Any]?)? = nil) {
        isRunning = running; self.responder = responder
    }
    func start() throws { isRunning = true; starts += 1 }
    func stop() { isRunning = false }
    func setSpaceVisible(_ visible: Bool) { spaceVisible = visible }
    func setBackgroundWorkActive(_ active: Bool) { workActive = active }
    func displayPage(_ javascript: String) throws { throw TapPodError.profileUnavailable }
    func restoreDisplayedPage(_ url: URL) {}
    func run(_ script: String) {
        guard let range = script.range(of: ".command("), script.hasSuffix(")"),
              let data = String(script[range.upperBound...].dropLast()).data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = command["id"] as? String, let cmd = command["cmd"] as? String else { return }
        commands.append(command)
        respond(command, id: id, cmd: cmd)
    }
    func respond(_ command: [String: Any], id: String, cmd: String) {
        guard let data = responder?(cmd, command) else { return }
        emit(["type": "result", "id": id, "ok": true, "data": data])
    }
    func stream(_ kind: String, _ fields: [String: Any] = [:]) {
        guard let id = sends.last?["id"] as? String else { return }
        emit(fields.merging(["type": "stream", "id": id, "kind": kind]) { _, new in new })
    }
    func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        onEvent?(String(decoding: data, as: UTF8.self))
    }
}

class DispatchTapPod: FakeTapPod {
    var autoHello = true
    var hiddenCommands = 0
    var stops: [String] = []
    var renames: [String] = []
    var projectName = ""
    var projectDescription = ""
    var projects: [[String: Any]] = []
    override func start() throws {
        starts += 1; isRunning = true
        if autoHello { Task { @MainActor in self.emit(["type": "hello", "loggedIn": true]) } }
    }

    override func respond(_ command: [String: Any], id: String, cmd: String) {
        if hidden { hiddenCommands += 1 }

        if cmd == "send" { return }
        if cmd == "stop" {
            stops.append(command["requestID"] as! String)
            emit(["type": "result", "id": id, "ok": true]); return
        }
        let result: [String: Any]
        switch cmd {
        case "models": result = ["models": [["slug": "fixture-model", "title": "Fixture Model"]]]
        case "projects": result = ["items": projects]
        case "createProject":
            projectName = command["name"] as! String; projectDescription = command["description"] as! String
            let projectID = projects.isEmpty ? "g-p-fixture" : "g-p-fixture-" + String(projects.count)
            let folder: [String: Any] = ["id": projectID, "title": projectName, "kind": "project", "description": projectDescription]
            projects.append(folder); result = folder
        case "projectDetails": result = projects.first { $0["id"] as? String == command["projectID"] as? String } ?? [:]
        case "rename": renames.append(command["title"] as! String); result = [:]
        default: result = ["items": [], "messages": []]
        }
        emit(["type": "result", "id": id, "ok": true, "data": result])
    }

}

#endif
