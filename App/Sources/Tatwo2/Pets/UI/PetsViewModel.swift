import SwiftUI
import AppKit

@MainActor final class PetsViewModel: ObservableObject {
    enum Page: String, CaseIterable { case teams = "隊伍", stage = "舞台", profile = "個資", exchange = "交換", backpack = "背包", hall = "冠軍殿堂" }
    let chat: PetChat
    @Published var store: PetStore?
    @Published var profiles: [UUID: PetProfile] = [:]
    @Published var page = Page.teams
    @Published var selected: UUID?
    @Published var thread: UUID?
    @Published var sessionsFor: UUID?
    @Published var swap: (UUID, UUID)?
    @Published var search = ""
    @Published var draft = ""
    @Published var notice = ""
    @Published var undelivered: [UUID: String] = [:]
    @Published var hallDraft: PetHallEntry?
    @Published var avatarsOpen = false
    @Published var renameID: UUID?
    @Published var renameDraft = ""
    func newConversation(_ pet: UUID) {
        guard let session = chat.newSession(projectID: pet) else { notice = "無法建立新對話；請稍後再試。"; return }
        open(pet, session: session); refresh()
    }
    init(model: ChatPageModel, scheduleEvents: Bool = true) { chat = PetChat(model: model); refresh(scheduleEvents: scheduleEvents) }
    @Published private(set) var experienceUnavailable = false
    func hasProgress(_ id: UUID) -> Bool { eventProfiles[id] != nil && !experienceUnavailable }
    private var eventRevisions: [UUID: String] = [:], metadata: [String] = []
    private var eventProfiles: [UUID: (PetProgress, [PetSkill])] = [:]
    private(set) var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    @Published var customDrafts: [UUID: String] = [:]
    private var personalityTasks: [UUID: Task<Void, Never>] = [:]
    func refresh(scheduleEvents: Bool = true) {
        do { let snapshot = try chat.store(); profiles = try Dictionary(uniqueKeysWithValues: snapshot.pets.values.map { ($0.id, try chat.profile(projectID: $0.id, eventProfile: eventProfiles[$0.id] ?? (PetProgress(creditedTokens: 0), []))) }); store = snapshot; metadata = chat.profileRevision }
        catch { notice = "寵物資料暫時無法讀取。" }
        if scheduleEvents { refreshEvents() }
    }
    func refreshEvents() {
        guard refreshTask == nil else { refreshPending = true; return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil; if refreshPending { refreshPending = false; refreshEvents() } }
            do {
                let changed = try await chat.eventProfiles(since: eventRevisions)
                for (id, value) in changed { eventRevisions[id] = value.0; eventProfiles[id] = (value.1, value.2) }
                experienceUnavailable = false
                if !changed.isEmpty || metadata != chat.profileRevision { refresh(scheduleEvents: false) }
            } catch { experienceUnavailable = true }
        }
    }
    func editCustom(_ pet: UUID, text: String) {
        customDrafts[pet] = text; personalityTasks.removeValue(forKey: pet)?.cancel()
        personalityTasks[pet] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.commitCustom(pet)
        }
    }
    func commitCustom(_ pet: UUID) {
        personalityTasks.removeValue(forKey: pet)?.cancel()
        guard let text = customDrafts[pet], var value = store?.pet(pet)?.personality else { return }
        value.custom = text
        perform { try store?.updatePersonality(pet, value); customDrafts[pet] = nil }
    }
    func perform(_ work: () throws -> Void) { do { try work(); notice = ""; refresh() } catch { notice = "操作未完成；資料已保留。" } }
    func editTeams(_ change: (inout PetTeams) -> Void) { guard let store else { return }; var value = store.teams; change(&value); perform { try store.saveTeams(value) } }
    func open(_ pet: UUID, session: UUID? = nil) { selected = pet; thread = session ?? chat.latestThread(projectID: pet); draft = ""; page = .stage; sessionsFor = nil }
    func send() {
        guard let selected else { return }; let text = draft; var sentThread = thread
        if chat.send(projectID: selected, threadID: thread, text: text, onDelivered: { [weak self] in self?.refresh() }, onUndelivered: { [weak self] hint in
            guard let self, let sentThread else { return }
            if self.selected == selected && self.thread == sentThread && self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.draft = text }
            else { self.undelivered[sentThread] = (self.undelivered[sentThread].map { $0 + "\n" } ?? "") + text }
            if self.selected == selected && self.thread == sentThread { self.notice = hint }
        }) {
            draft = ""; if thread == nil { thread = chat.latestThread(projectID: selected) }; sentThread = thread; refresh()
        } else { notice = "訊息未送出；請確認對話可用與引擎登入狀態。" }
    }
    func restoreUndelivered() {
        guard let thread, let text = undelivered.removeValue(forKey: thread) else { return }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : text + "\n" + draft
    }
    func move(_ pet: UUID, to team: UUID?) {
        guard let store else { return }
        if let team, let target = store.teams.teams.first(where: { $0.id == team }), target.members.count == 6, !target.members.contains(pet) { swap = (pet, team); return }
        perform { try store.move(pet, to: team) }
    }
    func replace(_ outgoing: UUID) {
        guard let store, let (incoming, team) = swap else { return }; var value = store.teams
        for i in value.teams.indices { value.teams[i].members.removeAll { $0 == incoming || $0 == outgoing } }
        guard let i = value.teams.firstIndex(where: { $0.id == team }) else { return }; value.teams[i].members.append(incoming)
        perform { try store.saveTeams(value) }; swap = nil
    }
    func deleteDepartment(_ id: UUID) {
        guard store?.teams.teams.filter({ $0.departmentID == id }).allSatisfy({ $0.members.isEmpty }) == true else { return }
        editTeams { $0.teams.removeAll { $0.departmentID == id }; $0.departments.removeAll { $0.id == id }; $0.links.removeAll { $0.from == id || $0.to == id } }
    }
    func chooseFolder(_ action: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { result in Task { @MainActor in if result == .OK, let url = panel.url { action(url) } } }
    }
    func upload(_ pet: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
        panel.begin { result in Task { @MainActor in if result == .OK, let url = panel.url { self.perform { try self.store?.uploadAvatar(pet, data: Data(contentsOf: url)) } } } }
    }
}
