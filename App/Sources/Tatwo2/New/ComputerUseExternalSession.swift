import AppKit
import Combine

/// Revocation dispatches directly to the native epoch gate; it never waits for MainActor/AX/network.
final class HandsComputerRevocations: @unchecked Sendable {
    static let shared = HandsComputerRevocations()
    private let lock = NSLock()
    private var revoked: Set<String> = []
    private var current: (String, ComputerUseSession, ComputerUseSession.Grant)?
    func isRevoked(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return revoked.contains(id) }
    func register(_ id: String, session: ComputerUseSession, grant: ComputerUseSession.Grant) {
        lock.lock(); defer { lock.unlock() }
        if revoked.contains(id) { session.stop(ifCurrent: grant) }
        else { current = (id, session, grant) }
    }
    func revoke(grants: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        revoked.formUnion(grants)
        if let current, grants.contains(current.0) { current.1.stop(ifCurrent: current.2); self.current = nil }
    }
    func stopCurrent() {
        lock.lock(); defer { lock.unlock() }
        if let current { current.1.stop(ifCurrent: current.2); self.current = nil }
    }
}

@MainActor
protocol HandsComputerBackend: AnyObject {
    var session: ComputerUseSession { get }
    func application(_ id: String) throws -> ComputerUseExternalPolicy.Application
    func start(owner: UUID, scope: String, app: String, consent: ComputerUseController.ExternalConsent,
               valid: @escaping @MainActor () -> Bool) async throws -> ComputerUseSession.Grant
    func perform(_ method: String, params: [String: Any], grant: ComputerUseSession.Grant,
                 valid: @escaping @MainActor () -> Bool) async throws -> [String: Any]
    func stop(owner: UUID)
}

extension HandsComputerBackend {
    func application(_ id: String) throws -> ComputerUseExternalPolicy.Application {
        try ComputerUseExternalPolicy.Application.read(ComputerUseTarget.requested(id, allowSelf: false).resolve().url)
    }
}

@MainActor
final class HandsNativeComputerBackend: HandsComputerBackend {
    var session: ComputerUseSession { ComputerUseController.shared.session }
    func start(owner: UUID, scope: String, app: String, consent: ComputerUseController.ExternalConsent,
               valid: @escaping @MainActor () -> Bool) async throws -> ComputerUseSession.Grant {
        let target = try ComputerUseExternalPolicy.target(app)
        _ = try await ComputerUseController.shared.startExternal(caller: owner, scope: scope, target: target,
                                                                 consent: consent, contextIsCurrent: valid)
        guard let grant = ComputerUseController.shared.externalGrant(owner: owner) else { throw ComputerUseFailure("expired") }
        return grant
    }
    func perform(_ method: String, params: [String: Any], grant: ComputerUseSession.Grant,
                 valid: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        try await ComputerUseController.shared.perform(method, params: params, caller: grant.owner, scope: grant.scope,
            workspace: URL(fileURLWithPath: "/"), allowSelfTarget: false, requestIsConnected: { true },
            contextIsCurrent: valid)
    }
    func stop(owner: UUID) { ComputerUseController.shared.stop(owner: owner) }
}

@MainActor
final class HandsComputerUse: ObservableObject {
    static let shared = HandsComputerUse()
    enum State: String { case pending, allowed, denied, expired }
    struct Request {
        let id: UUID
        let owner: UUID
        let grantID: String
        let app: String
        let appDisplayName: String
        let minutes: Int
        let landing: HandsProjectLanding
        weak var service: HandsService?
        var state: State
        var native: ComputerUseSession.Grant?
    }
    @Published private(set) var current: Request?
    private let backend: HandsComputerBackend
    private var timer: Timer?
    private var task: Task<Void, Never>?
    var isOperating: Bool { current?.state == .allowed }

    init(backend: HandsComputerBackend? = nil) { self.backend = backend ?? HandsNativeComputerBackend() }

    func landing(grant: String, service: HandsService) -> HandsProjectLanding {
        guard let current, current.grantID == grant, current.service === service else {
            return HandsProjectLanding(projectID: nil, workspaceID: nil, reminder: nil)
        }
        return current.landing
    }
    private func valid(_ request: Request) -> Bool {
        if backend is HandsNativeComputerBackend {
            guard IslandNotice.shared.hostAvailable, ComputerUseSettings.isEnabled,
                  !BrowserSensitivePageGate.isActive else { return false }
        }
        guard current?.id == request.id, let service = request.service,
              !HandsComputerRevocations.shared.isRevoked(request.grantID),
              service.admissionProblem(grantID: request.grantID, level: 2, projectID: request.landing.projectID,
                                       workspaceID: nil, forWrite: false) == nil else { return false }
        if current?.state == .allowed {
            let folder = service.roomJournal.url.deletingPathExtension()
                .appendingPathComponent(request.landing.projectID?.uuidString ?? "unclassified")
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isWritableFile(atPath: folder.path) else { return false }
        }
        return current?.state == .pending || current?.state == .allowed
    }

    func request(app: String, reason: String, minutes: Int, landing: HandsProjectLanding,
                 grant: String, service: HandsService) throws -> [String: Any] {
        guard reason.count <= 500 else { throw HandsToolError.invalid("computer_request_arguments") }
        let reason = ComputerUseExternalPolicy.reasonLine(reason)
        guard (1...15).contains(minutes), !reason.isEmpty, reason.count <= 500 else {
            throw HandsToolError.invalid("computer_request_arguments")
        }
        let application = try backend.application(app)
        _ = try ComputerUseExternalPolicy.validateApplication(app, name: application.name, category: application.category)
        guard current?.state != .pending, current?.state != .allowed else { throw HandsToolError.invalid("computer_busy") }
        let safeReason = HandsRedactor.redact(reason, context: service.redactionContext(workspace: nil))
        let value = Request(id: UUID(), owner: UUID(), grantID: grant, app: app, appDisplayName: application.name, minutes: minutes,
                            landing: landing, service: service, state: .pending)
        guard service.journal(tool: "computer_request", summary: "等待主機使用者決定", landing: landing, grant: grant,
                              approval: "pending", app: app, minutes: minutes, requestID: value.id) else {
            throw HandsToolError.invalid("chatgpt_room_unavailable")
        }
        current = value
        startTimer()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var consent = ComputerUseController.ExternalConsent(requestID: value.id, reason: safeReason, minutes: minutes)
                let admissionReceiptID = UUID()
                consent.admission = { [weak service] in
                    guard let service, !HandsComputerRevocations.shared.isRevoked(grant) else { return false }
                    guard service.admissionProblem(grantID: grant, level: 2, projectID: landing.projectID,
                                                   workspaceID: nil, forWrite: false) == nil else { return false }
                    // One durable metadata checkpoint, updated in place; every dispatch also retains
                    // the gateway's separate call receipt. No typed text or screenshot is stored.
                    return service.journal(tool: "computer_request", summary: "已核准工作階段安全檢查",
                        landing: landing, grant: grant, approval: "allowed", app: app, minutes: minutes,
                        requestID: value.id, id: admissionReceiptID)
                }
                let native = try await backend.start(owner: value.owner, scope: "chatgpt:" + value.id.uuidString, app: app,
                    consent: consent, valid: { [weak self] in self?.valid(value) == true })
                guard valid(value), current?.state == .pending else { backend.stop(owner: value.owner); return }
                current?.native = native
                current?.state = .allowed
                HandsComputerRevocations.shared.register(grant, session: backend.session, grant: native)
                guard record(value, state: "allowed", summary: "使用者在主機核准 \(minutes) 分鐘") else {
                    stop(reason: "核准紀錄未存成")
                    return
                }
                IslandExceptionsNavigation.shell?.holdOpen(true)
            } catch {
                guard current?.id == value.id, current?.state == .pending else { return }
                let denied = (error as? ComputerUseFailure)?.code == "computer_external_denied"
                current?.state = denied ? .denied : .expired
                backend.stop(owner: value.owner)
                record(value, state: denied ? "denied" : "expired", summary: denied ? "使用者拒絕" : "核准未成立或已失效")
                finishTimer()
            }
        }
        return ["status": "pending", "request_id": value.id.uuidString,
                "note": "Only the user at the host machine can allow this request in Island. Tools cannot approve it."]
    }

    func status(grant: String, service: HandsService) -> [String: Any] {
        tick()
        guard let current, current.grantID == grant, current.service === service else { return ["status": "expired"] }
        var reply: [String: Any] = ["status": current.state.rawValue, "app": current.app]
        if current.state == .allowed, let native = current.native {
            reply["remaining_minutes"] = max(0, (native.expiresAt - ProcessInfo.processInfo.systemUptime) / 60)
        }
        return reply
    }

    func tick() {
        guard let current, current.state == .allowed || current.state == .pending else { return }
        guard valid(current) else { stop(reason: "TATWO 核准失效"); return }
        if current.state == .allowed {
            guard let native = current.native, (try? backend.session.validate(native)) != nil else { stop(reason: "時間到或使用者接手／停止"); return }
            if backend is HandsNativeComputerBackend {
                guard let app = NSRunningApplication(processIdentifier: native.pid), !app.isTerminated,
                      ComputerUseController.shared.externalGrant(owner: current.owner) != nil,
                      ComputerUseSettings.isEnabled, !BrowserSensitivePageGate.isActive,
                      IslandNotice.shared.pendingRequestIDs.isEmpty else { stop(reason: "App 結束或敏感畫面開啟"); return }
            }
            IslandExceptionsNavigation.shell?.holdOpen(true)
        }
    }
    func stop(reason: String = "使用者按停止") {
        guard let current, current.state == .pending || current.state == .allowed else { return }
        if let native = current.native { backend.session.stop(ifCurrent: native) }
        self.current?.state = .expired
        task?.cancel()
        IslandNotice.shared.resolve(.cancel, id: current.id)
        backend.stop(owner: current.owner)
        record(current, state: "expired", summary: reason)
        finishTimer()
    }
    func stop(grant: String, service: HandsService) -> [String: Any] {
        guard current?.grantID == grant, current?.service === service else { return ["status": "expired"] }
        stop(reason: "ChatGPT 要求停止")
        return ["status": "expired"]
    }

    func perform(_ method: String, arguments: [String: Any], grant: String, service: HandsService) async throws -> [String: Any] {
        tick()
        guard let current, current.grantID == grant, current.service === service else { throw HandsToolError.invalid("expired") }
        guard current.state == .allowed, let native = current.native else { throw HandsToolError.invalid(current.state.rawValue) }
        var params = arguments
        params["sessionID"] = native.id.uuidString
        if method == "computer_action", let action = params["action"] as? String {
            if let text = params["text"] as? String,
               !ComputerUseExternalPolicy.safe(role: "", text: text)
                || ((text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("file:"))
                    && !ComputerUseExternalPolicy.documentAllowed(text, runtime: service.runtime)) {
                throw HandsToolError.invalid("computer_external_sensitive_input_denied")
            }
            params["action"] = ["type": "type_text", "key": "press_key"][action] ?? action
            if action == "scroll" { params["dx"] = params["dx"] ?? 0; params["dy"] = params["dy"] ?? 0 }
            let request = try ComputerUseNative.request(action: params["action"] as? String ?? "", params: params)
            try ComputerUseExternalPolicy.validateRequest(request)
        }
        do {
            let result = try await backend.perform(method, params: params, grant: native, valid: { [weak self] in self?.valid(current) == true })
            tick()
            guard self.current?.state == .allowed else { throw HandsToolError.invalid("expired") }
            return result
        } catch {
            tick()
            if self.current?.state != .allowed { throw HandsToolError.invalid("expired") }
            throw error
        }
    }

    @discardableResult
    private func record(_ value: Request, state: String, summary: String) -> Bool {
        guard let service = value.service else { return false }
        let saved = service.journal(tool: "computer_request", summary: summary, landing: value.landing, grant: value.grantID, approval: state,
                                    app: value.app, minutes: value.minutes, requestID: value.id)
        if let root = service.rootThread(projectID: value.landing.projectID) {
            service.record(thread: root, rowID: "hands-cu:" + UUID().uuidString, turn: "hands-cu:" + value.id.uuidString,
                           text: "〔外部資料・ChatGPT CU〕\(state)：\(summary)", status: "done|computer_request", subStatus: nil)
        }
        return saved
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func finishTimer() {
        timer?.invalidate(); timer = nil
        IslandExceptionsNavigation.shell?.holdOpen(!IslandNotice.shared.pendingRequestIDs.isEmpty)
    }
}

extension HandsService {
    @MainActor var computerUse: HandsComputerUse {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
           let computerUseForTesting { return computerUseForTesting }
        #endif
        return HandsComputerUse.shared
    }
    /// Hands runs on the bounded socket worker, not the UI actor. Screenshots are never ledger data.
    func computerPerform(_ method: String, arguments: [String: Any], grant: String) throws -> [String: Any] {
        guard !Thread.isMainThread else { throw HandsToolError.invalid("computer_worker_required") }
        let done = DispatchSemaphore(value: 0)
        let box = HandsComputerResult()
        Task { @MainActor in
            do { box.set(.success(try await computerUse.perform(method, arguments: arguments, grant: grant, service: self))) }
            catch {
                // Native refusal diagnostics can contain window titles; external errors disclose codes only.
                let code = (error as? ComputerUseFailure)?.code ?? (error as? HandsToolError)?.description ?? "computer_failed"
                let safe = String(code.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                box.set(.failure(HandsToolError.invalid(safe.isEmpty ? "computer_failed" : safe)))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 50) == .success else {
            DispatchQueue.main.async { self.computerUse.stop(reason: "操作逾時") }
            throw HandsToolError.invalid("computer_timeout")
        }
        return try box.get().get()
    }
}

private final class HandsComputerResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String: Any], Error> = .failure(HandsToolError.invalid("computer_result_missing"))
    func set(_ value: Result<[String: Any], Error>) { lock.lock(); result = value; lock.unlock() }
    func get() -> Result<[String: Any], Error> { lock.lock(); defer { lock.unlock() }; return result }
}
