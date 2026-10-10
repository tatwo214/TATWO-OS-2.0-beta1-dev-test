import SwiftUI
import AppKit

struct PetsRootView: View {
    @ObservedObject var model: ChatPageModel
    @StateObject var pets: PetsViewModel
    @ObservedObject private var theme = TatwoThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var inputHeight = PetSkin(dark: false).composerMin
    @State private var inputFocused = false
    @State private var dropTargets: Set<String> = []
    @FocusState private var renameFocused: UUID?
    @FocusState private var personalityFocused: Bool
    init(model: ChatPageModel, state: PetsViewModel? = nil) { self.model = model; _pets = StateObject(wrappedValue: state ?? PetsViewModel(model: model)) }
    private var skin: PetSkin { PetSkin(palette: theme.active.palette, dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            HStack(spacing: skin.gap) {
                Text("寵物").font(skin.title); Spacer()
                ForEach(ChatRunMode.visibleChatTabs) { mode in action(mode.displayName, "workspace.\(mode.rawValue)") { model.mode = mode } }
            }
            if let store = pets.store, !store.pets.isEmpty {
                HStack(spacing: skin.gap) { ForEach(PetsViewModel.Page.allCases, id: \.self) { page in Button { pets.page = page } label: { Text(page.rawValue).font(pets.page == page ? skin.selectedTab : skin.body).padding(.horizontal, skin.chipX).padding(.vertical, skin.chipY).chatGlassChip(isSelected: pets.page == page, tint: skin.accent) }.buttonStyle(.plain).accessibilityIdentifier("tatwo.pets.nav.\(page)").accessibilityAddTraits(pets.page == page ? .isSelected : []).disabled((page == .stage || page == .profile) && pets.selected == nil) } }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ForEach(store.reports, id: \.self) { Text($0).font(skin.detail).foregroundStyle(skin.muted) }
            } else if pets.store != nil {
                VStack(spacing: skin.gap) { Text("建立第一個專案，就會在這裡遇見你的寵物。"); action("到 Coder 建立專案", "empty.coder") { model.mode = .chat } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.empty")
            } else { action("重新讀取寵物", "retry") { pets.refresh() } }
            if !pets.notice.isEmpty { Text(pets.notice).foregroundStyle(skin.muted).accessibilityIdentifier("tatwo.pets.notice") }
        }.padding(skin.inset).font(skin.body).foregroundStyle(skin.ink).tint(skin.accent).background(skin.canvas)
            .accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.root").onReceive(model.objectWillChange) { _ in pets.refreshEvents() }
            .sheet(isPresented: Binding(get: { pets.swap != nil }, set: { if !$0 { pets.swap = nil } })) { swapView }
            .sheet(item: $pets.hallDraft) { entry in hallEditor(entry) }
    }
    @ViewBuilder private var content: some View {
        switch pets.page {
        case .teams: teamsView
        case .stage: stageView
        case .profile: profileView
        case .exchange: exchangeView
        case .backpack: backpackView
        case .hall: hallView
        }
    }
    private func action(_ title: String, _ id: String, _ work: @escaping () -> Void) -> some View {
        Button(title, action: work).font(skin.body).buttonStyle(.plain).padding(.horizontal, skin.chipY).padding(.vertical, skin.compactGap).chatGlassChip(tint: skin.accent).accessibilityIdentifier("tatwo.pets." + id)
    }
    private func avatar(_ id: UUID, large: Bool = false) -> some View {
        Group { if let data = try? pets.store?.avatarPNG(id), let image = NSImage(data: data) { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } }
            .frame(width: large ? skin.portrait : skin.avatar, height: large ? skin.portrait : skin.avatar)
            .background(skin.accent.opacity(skinAvatarOpacity)).clipShape(RoundedRectangle(cornerRadius: skin.avatarRadius))
            .accessibilityIdentifier("tatwo.pets.avatar.\(id)")
    }
    private var skinAvatarOpacity: Double { PetSkin.avatarOpacity }
    private func progress(_ profile: PetProfile) -> some View {
        VStack(alignment: .leading, spacing: skin.compactGap) {
            HStack(spacing: skin.compactGap) { Text(profile.name).font(skin.heading).lineLimit(1).truncationMode(.tail).help(profile.name); Text(pets.hasProgress(profile.pet.id) ? "Lv \(profile.progress.level)" : "Lv —").font(skin.detail).foregroundStyle(skin.muted).fixedSize() }
            if pets.hasProgress(profile.pet.id) {
                ProgressView(value: profile.progress.levelFraction)
                    .accessibilityLabel("經驗 \(profile.progress.levelExperience) / \(profile.progress.nextLevelExperience)")
                Text("\(profile.progress.levelExperience.formatted()) / \(profile.progress.nextLevelExperience.formatted())").font(skin.detail).foregroundStyle(skin.faint)
            } else {
                Text("經驗 —").font(skin.detail).foregroundStyle(skin.faint)
                if pets.experienceUnavailable { Text("經驗暫時讀不到").font(skin.detail).foregroundStyle(skin.muted) }
            }
        }
    }
    private func petRow(_ id: UUID) -> some View {
        Button { pets.open(id) } label: {
            HStack(spacing: skin.gap) { avatar(id); if let profile = pets.profiles[id] { progress(profile) }; Spacer(minLength: skin.zero) }
                .padding(.trailing, skin.iconSize).frame(maxWidth: .infinity, alignment: .leading).petCard(skin).contentShape(RoundedRectangle(cornerRadius: skin.radius))
        }.buttonStyle(.plain).accessibilityIdentifier("tatwo.pets.pet.\(id)").contextMenu { sessions(id) }.onDrag { NSItemProvider(object: id.uuidString as NSString) }
            .overlay(alignment: .trailing) {
                Menu {
                    action("對它說話", "talk.\(id)") { pets.open(id) }; action("看 session", "sessions.\(id)") { pets.open(id); pets.sessionsFor = id }
                    action("個資", "profile.\(id)") { pets.selected = id; pets.page = .profile }; destinations(id)
                } label: { Image(systemName: "ellipsis").frame(width: skin.iconSize, height: skin.iconSize) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, skin.gap).help("寵物操作").accessibilityIdentifier("tatwo.pets.actions.\(id)")
            }
    }
    private func destinations(_ id: UUID) -> some View {
        Group {
            action("放進背包", "move.backpack.\(id)") { pets.move(id, to: nil) }
            Menu("換隊伍") { ForEach(pets.store?.teams.teams ?? []) { team in action("加入 \(team.name)", "move.\(team.id).\(id)") { pets.move(id, to: team.id) } } }
        }
    }
    private var teamsView: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: skin.gap) {
                    ForEach(pets.store?.teams.departments ?? []) { department in
                        VStack(alignment: .leading, spacing: skin.gap) {
                            HStack(spacing: skin.compactGap) {
                                editableTitle(department.name, id: department.id, binding: departmentName(department), kind: "department"); Spacer(minLength: skin.zero); linkMenu(department)
                                Menu { action("改名", "department.rename.\(department.id)") { beginRename(department.id, department.name) }; action("刪除空部門", "department.delete.\(department.id)") { pets.deleteDepartment(department.id) }.disabled(pets.store?.teams.teams.contains { $0.departmentID == department.id && !$0.members.isEmpty } == true) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("部門操作")
                            }
                            action("新增隊伍", "team.add.\(department.id)") { pets.editTeams { $0.teams.append(PetTeam(departmentID: department.id, name: "新隊伍")) } }
                            linkChips(department)
                            ForEach((pets.store?.teams.teams ?? []).filter { $0.departmentID == department.id }) { team in
                                VStack(alignment: .leading, spacing: skin.gap) {
                                    HStack { editableTitle(team.name, id: team.id, binding: teamName(team), kind: "team"); Spacer(); Menu { action("改名", "team.rename.\(team.id)") { beginRename(team.id, team.name) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("隊伍操作") }
                                    Text("\(team.members.count) / 6").font(skin.detail).foregroundStyle(skin.muted)
                                    ForEach(team.members, id: \.self) { petRow($0) }
                                    Text("從背包拖入寵物").font(skin.detail).foregroundStyle(skin.muted)
                                }.petCard(skin).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.team.\(team.id)").petDropHighlight(skin, active: dropTargets.contains(team.id.uuidString)).dropDestination(for: String.self) { items, _ in drop(items, to: team.id) } isTargeted: { targeted($0, key: team.id.uuidString) }
                            }
                        }.frame(width: skin.column).petCard(skin)
                    }
                    Button { pets.editTeams { $0.departments.append(PetDepartment(name: "新部門")) } } label: { Label("部門", systemImage: "plus").frame(width: skin.column, height: skin.portrait) }.buttonStyle(.plain).overlay(RoundedRectangle(cornerRadius: skin.radius).stroke(skin.dashedBorder, style: StrokeStyle(lineWidth: skin.stroke, dash: skin.dash))).accessibilityIdentifier("tatwo.pets.department.add")
                }.padding(skin.gap)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.teams")
    }
    private func departmentName(_ department: PetDepartment) -> Binding<String> { Binding(get: { pets.store?.teams.departments.first { $0.id == department.id }?.name ?? department.name }, set: { name in pets.editTeams { if let i = $0.departments.firstIndex(where: { $0.id == department.id }) { $0.departments[i].name = name } } }) }
    private func teamName(_ team: PetTeam) -> Binding<String> { Binding(get: { pets.store?.teams.teams.first { $0.id == team.id }?.name ?? team.name }, set: { name in pets.editTeams { if let i = $0.teams.firstIndex(where: { $0.id == team.id }) { $0.teams[i].name = name } } }) }
    private func beginRename(_ id: UUID, _ name: String) { pets.renameDraft = name; pets.renameID = id; renameFocused = id }
    private func finishRename(_ id: UUID, _ binding: Binding<String>, cancel: Bool = false) {
        guard pets.renameID == id else { return }; pets.renameID = nil; renameFocused = nil
        let name = pets.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines); if !cancel && !name.isEmpty { binding.wrappedValue = name }
    }
    @ViewBuilder private func editableTitle(_ name: String, id: UUID, binding: Binding<String>, kind: String) -> some View {
        if pets.renameID == id {
            TextField("名稱", text: $pets.renameDraft).textFieldStyle(.plain).font(skin.heading).focused($renameFocused, equals: id).onAppear { renameFocused = id }
                .onSubmit { finishRename(id, binding) }.onExitCommand { finishRename(id, binding, cancel: true) }
                .onChange(of: renameFocused) { _, focus in if focus != id { finishRename(id, binding) } }.accessibilityIdentifier("tatwo.pets.\(kind).name.\(id)")
        } else { Text(name).font(skin.heading).lineLimit(1).help(name).onTapGesture(count: 2) { beginRename(id, name) }.accessibilityIdentifier("tatwo.pets.\(kind).title.\(id)") }
    }
    private func linked(_ a: UUID, _ b: UUID) -> Bool { pets.store?.teams.links.contains { Set([$0.from, $0.to]) == Set([a,b]) } == true }
    private func linkMenu(_ department: PetDepartment) -> some View {
        Menu { ForEach((pets.store?.teams.departments ?? []).filter { $0.id != department.id }) { other in
            Toggle(other.name, isOn: Binding(get: { linked(department.id, other.id) }, set: { enabled in pets.editTeams { value in value.links.removeAll { Set([$0.from, $0.to]) == Set([department.id, other.id]) }; if enabled { value.links.append(PetLink(from: department.id, to: other.id)) } } })).accessibilityIdentifier("tatwo.pets.link.add.\(department.id).\(other.id)")
        } } label: { Label("連線", systemImage: "link").font(skin.detail) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("tatwo.pets.links.\(department.id)")
    }
    private func linkChips(_ department: PetDepartment) -> some View {
        HStack(spacing: skin.compactGap) { ForEach((pets.store?.teams.departments ?? []).filter { linked(department.id, $0.id) }) { other in
            action("↔ \(other.name) ×", "link.remove.\(department.id).\(other.id)") { pets.editTeams { $0.links.removeAll { Set([$0.from, $0.to]) == Set([department.id, other.id]) } } }
        } }
    }
    private func sessions(_ id: UUID) -> some View {
        Group {
            action("新的對話", "session.new.\(id)") { pets.newConversation(id) }
            ForEach(pets.chat.sessions(projectID: id)) { session in
                action("\(session.title) · \(session.updatedAt.formatted())\(session.isArchived ? "（封存）" : "")", "session.\(session.id)") { pets.open(id, session: session.id) }
            }
        }
    }
    private var stageView: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            if let id = pets.selected, let profile = pets.profiles[id] {
                HStack(spacing: skin.gap) { avatar(id, large: true); progress(profile); Spacer(); icon("bubble.left.and.bubble.right", "對話紀錄", "sessions.open") { pets.sessionsFor = id }.popover(isPresented: Binding(get: { pets.sessionsFor == id }, set: { if !$0 { pets.sessionsFor = nil } })) { VStack(alignment: .leading, spacing: skin.gap) { sessions(id) }.petCard(skin).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.sessions") }; icon("person.crop.circle", "個資", "stage.profile") { pets.page = .profile } }
                if let thread = pets.thread {
                    GlobalDMMessageList(bubbles: GlobalDMBubble.rows(model.dmTranscript(for: thread), running: model.dmSessionIsRunning(thread)), emptyText: "對寵物說一句話吧。")
                        .accessibilityIdentifier("tatwo.pets.stage.messages")
                } else { Text("對寵物說一句話吧。").frame(maxHeight: .infinity) }
                composer(profile)
            }
        }.petCard(skin).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.stage")
    }
    private func icon(_ symbol: String, _ label: String, _ id: String, _ work: @escaping () -> Void) -> some View {
        Button(action: work) { Image(systemName: symbol).frame(width: skin.iconSize, height: skin.iconSize).chatGlassChip(tint: skin.accent) }.buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityIdentifier("tatwo.pets." + id)
    }
    private func composer(_ profile: PetProfile) -> some View {
        let running = pets.thread.map { model.dmSessionIsRunning($0) } ?? false
        let canSend = !profile.pet.missing && !running && (pets.thread.map { model.dmSessionCanSend($0) } ?? true)
        return VStack(alignment: .leading, spacing: skin.compactGap) {
            if let thread = pets.thread, let text = pets.undelivered[thread] { action("上一句沒送到：" + ChatPageModel.undeliveredPreview(text) + " · 放回輸入框", "stage.restore") { pets.restoreUndelivered() } }
            ChatComposerTextView(text: $pets.draft, contentHeight: $inputHeight, isFocused: inputFocused, placeholder: "對寵物說話…", isMonospaced: false, minimumHeight: skin.composerMin, maximumHeight: skin.composerMax, onSubmit: { if canSend { pets.send() } }, onFocusChange: { inputFocused = $0 }, accessibilityTextLabel: "對寵物說話", pointSize: skin.messageSize, slashCommands: []).frame(height: min(skin.composerMax, max(skin.composerMin, inputHeight))).accessibilityIdentifier("tatwo.pets.stage.input")
            HStack { Text(running ? "正在回覆…" : "Enter 送出 · Shift-Enter 換行").font(skin.detail).foregroundStyle(skin.muted); Spacer(); if running { ProgressView().controlSize(.small).accessibilityIdentifier("tatwo.pets.stage.running") } else { icon("arrow.up", "送出", "stage.send") { pets.send() }.disabled(!canSend || pets.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }.padding(skin.inset).liquidGlassPanelSurface(cornerRadius: skin.radius)
    }
    private var profileView: some View {
        ScrollView { if let id = pets.selected, let profile = pets.profiles[id] {
            VStack(alignment: .leading, spacing: skin.gap) {
                HStack(spacing: skin.gap) { Button { pets.avatarsOpen = true } label: { avatar(id, large: true).overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").foregroundStyle(skin.accent) } }.buttonStyle(.plain).help("選擇頭像").accessibilityIdentifier("tatwo.pets.avatar.open").popover(isPresented: $pets.avatarsOpen) { avatarGrid(id) }; progress(profile) }
                Text(pets.hasProgress(id) ? "徽章 \(profile.progress.badges) · 累計經驗 \(profile.progress.experience.formatted())" : "徽章 — · 累計經驗 —")
                personality(profile)
                Text("常用技能").font(skin.heading); if profile.skills.isEmpty { Text("還沒有記錄").foregroundStyle(skin.muted) }; ForEach(profile.skills, id: \.name) { Text("\($0.name) · \($0.count)") }
                Text("記憶").font(skin.heading); if profile.sessions.allSatisfy({ $0.summaries.isEmpty }) { Text("還沒有記錄").foregroundStyle(skin.muted) }; ForEach(profile.sessions.filter { !$0.summaries.isEmpty }) { session in VStack(alignment: .leading, spacing: skin.gap) { Text(session.title); ForEach(session.summaries, id: \.self) { Text($0).foregroundStyle(skin.muted) } } }
                if let path = profile.workdir { Text("資料：\(compactPath(path))").lineLimit(1).truncationMode(.middle).help(compactPath(path)); action("在 Finder 顯示", "profile.finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                Text("相遇時間：\(profile.encounteredAt?.formatted() ?? profile.pet.createdAt.formatted())")
                action("匯出這隻寵物", "profile.export") { pets.chooseFolder { folder in pets.perform { _ = try pets.chat.export(projectID: id, to: folder) }; if pets.notice.isEmpty { pets.notice = "寵物已匯出。" } } }
            }.petCard(skin)
        } }.accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.profile")
    }
    private func personality(_ profile: PetProfile) -> some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            HStack(spacing: skin.gap) { ForEach(["加強", "收斂"], id: \.self) { label in Picker(label, selection: Binding<String>(get: { let value = pets.profiles[profile.pet.id]?.pet.personality; return (label == "加強" ? value?.strengthen : value?.restrain) ?? "" }, set: { selection in var value = profile.pet.personality; if label == "加強" { value.strengthen = selection.isEmpty ? nil : selection } else { value.restrain = selection.isEmpty ? nil : selection }; pets.perform { try pets.store?.updatePersonality(profile.pet.id, value) } })) { Text("未指定").tag(""); ForEach(PetPersonality.presets, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("tatwo.pets.personality.\(label)") } }.frame(maxWidth: skin.sheetWidth)
            Text("自訂性格（最多 200 字）").font(skin.detail).foregroundStyle(skin.muted)
            TextEditor(text: Binding<String>(get: { pets.customDrafts[profile.pet.id] ?? pets.profiles[profile.pet.id]?.pet.personality.custom ?? "" }, set: { custom in pets.editCustom(profile.pet.id, text: custom) })).coderScrollIndicators().scrollContentBackground(.hidden).frame(maxWidth: skin.sheetWidth).frame(height: skin.customHeight).padding(skin.compactGap).background(skin.canvas, in: RoundedRectangle(cornerRadius: skin.avatarRadius)).accessibilityIdentifier("tatwo.pets.personality.custom").focused($personalityFocused).onKeyPress(keys: [.return]) { key -> KeyPress.Result in if key.modifiers.contains(.shift) { return .ignored }; pets.commitCustom(profile.pet.id); return .handled }.onChange(of: personalityFocused) { _, focused in if !focused { pets.commitCustom(profile.pet.id) } }.onDisappear { pets.commitCustom(profile.pet.id) }
        }
    }
    private var backpackView: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            HStack(spacing: skin.compactGap) { Image(systemName: "magnifyingglass"); ChatChipTextField(title: "搜尋背包", text: $pets.search).textFieldStyle(.plain).accessibilityIdentifier("tatwo.pets.backpack.search"); if !pets.search.isEmpty { icon("xmark", "清除搜尋", "backpack.clear") { pets.search = "" } } }.padding(skin.chipY).chatGlassChip(tint: skin.accent)
            if pets.store?.backpack.isEmpty == true { Text("背包裡還沒有寵物。").foregroundStyle(skin.muted) }
            ScrollView { LazyVStack(spacing: skin.gap) { ForEach((pets.store?.backpack ?? []).filter { pets.search.isEmpty || (pets.profiles[$0.id]?.name ?? "").localizedCaseInsensitiveContains(pets.search) }) { petRow($0.id) } } }
            Text("拖到這裡放進背包").foregroundStyle(skin.muted)
        }.petCard(skin).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.backpack").petDropHighlight(skin, active: dropTargets.contains("backpack")).dropDestination(for: String.self) { items, _ in drop(items, to: nil) } isTargeted: { targeted($0, key: "backpack") }
    }
    private func targeted(_ active: Bool, key: String) { if active { dropTargets.insert(key) } else { dropTargets.remove(key) } }
    private func compactPath(_ path: String) -> String { let home = NSHomeDirectory(); return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
    private func avatarGrid(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            Text("選擇頭像").font(skin.heading)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: skin.gap), count: skin.avatarColumns), spacing: skin.gap) { ForEach(PetAvatars.catalog, id: \.self) { item in
                Button { pets.perform { try pets.store?.chooseAvatar(id, avatar: item) }; pets.avatarsOpen = false } label: {
                    Group { if let data = try? PetAvatars.png(item), let image = NSImage(data: data) { Image(nsImage: image).resizable().interpolation(.none).scaledToFit() } }.frame(width: skin.avatar, height: skin.avatar).padding(skin.compactGap).chatGlassChip(isSelected: pets.profiles[id]?.pet.avatar == item, tint: skin.accent)
                }.buttonStyle(.plain).accessibilityLabel("頭像 " + item).accessibilityIdentifier("tatwo.pets.avatar.choose.\(item)")
            } }
            action("上傳圖片", "avatar.upload") { pets.avatarsOpen = false; pets.upload(id) }
        }.frame(width: skin.avatarGridWidth).petCard(skin).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.avatars")
    }
    private func drop(_ items: [String], to team: UUID?) -> Bool { guard items.count == 1, let id = items.first.flatMap(UUID.init(uuidString:)), pets.store?.pet(id) != nil else { return false }; pets.move(id, to: team); return true }
    private var exchangeView: some View {
        HStack(alignment: .top, spacing: skin.gap) { ScrollView { VStack(spacing: skin.gap) { ForEach(pets.store?.teams.teams ?? []) { team in VStack(spacing: skin.gap) { Text(team.name).font(skin.heading); ForEach(team.members, id: \.self) { petRow($0) } }.petCard(skin).petDropHighlight(skin, active: dropTargets.contains(team.id.uuidString)).dropDestination(for: String.self) { items, _ in drop(items, to: team.id) } isTargeted: { targeted($0, key: team.id.uuidString) } } } }; backpackView }.accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.exchange")
    }
    private var swapView: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            Text("隊伍已滿，先選一隻放進背包。").font(skin.heading)
            if let (_, team) = pets.swap { ForEach(pets.store?.teams.teams.first { $0.id == team }?.members ?? [], id: \.self) { id in action(pets.profiles[id]?.name ?? "寵物", "swap.\(id)") { pets.replace(id) } } }
            action("取消", "swap.cancel") { pets.swap = nil }
        }.petCard(skin).frame(width: skin.sheetWidth).accessibilityIdentifier("tatwo.pets.swap")
    }
    private var hallView: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            action("登錄", "hall.add") { pets.hallDraft = PetHallEntry(name: "", date: Date(), participants: []) }
            ScrollView { VStack(spacing: skin.gap) { ForEach(pets.store?.hall ?? []) { entry in
                VStack(alignment: .leading, spacing: skin.gap) {
                    Text(entry.name).font(skin.heading); Text(entry.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(skin.muted)
                    ForEach(entry.participants, id: \.projectID) { Text("\(pets.profiles[$0.projectID]?.name ?? "找不到專案")：\($0.responsibility)") }
                    HStack { action("修改", "hall.edit.\(entry.id)") { pets.hallDraft = entry }; action("刪除紀錄", "hall.delete.\(entry.id)") { pets.perform { try pets.store?.saveHall((pets.store?.hall ?? []).filter { $0.id != entry.id }) } } }
                }.petCard(skin)
            } } }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.hall")
    }
    private func hallEditor(_ entry: PetHallEntry) -> some View { PetHallEditor(entry: entry, profiles: pets.profiles, skin: skin) { value in pets.perform { try pets.store?.saveHall((pets.store?.hall ?? []).filter { $0.id != value.id } + [value]) }; if pets.notice.isEmpty { pets.hallDraft = nil } } cancel: { pets.hallDraft = nil } }
}

struct PetHallEditor: View {
    @State var entry: PetHallEntry
    let profiles: [UUID: PetProfile], skin: PetSkin, save: (PetHallEntry) -> Void, cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: skin.gap) {
            ChatChipTextField(title: "名稱", text: $entry.name).padding(skin.chipY).chatGlassChip(tint: skin.accent).focusEffectDisabled().accessibilityIdentifier("tatwo.pets.hall.name")
            DatePicker("日期", selection: $entry.date, displayedComponents: .date).accessibilityIdentifier("tatwo.pets.hall.date")
            ScrollView { VStack(alignment: .leading, spacing: skin.gap) { ForEach(profiles.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                Toggle(profiles[id]?.name ?? "寵物", isOn: Binding(get: { entry.participants.contains { $0.projectID == id } }, set: { selected in entry.participants.removeAll { $0.projectID == id }; if selected { entry.participants.append(.init(projectID: id, responsibility: "")) } })).accessibilityIdentifier("tatwo.pets.hall.participant.\(id)")
                if let i = entry.participants.firstIndex(where: { $0.projectID == id }) { ChatChipTextField(title: "負責什麼", text: $entry.participants[i].responsibility).padding(skin.chipY).chatGlassChip(tint: skin.accent).focusEffectDisabled().accessibilityIdentifier("tatwo.pets.hall.responsibility.\(id)") }
            } } }
            HStack { Button("儲存") { save(entry) }.disabled(entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.participants.isEmpty).accessibilityIdentifier("tatwo.pets.hall.save"); Button("取消", action: cancel).accessibilityIdentifier("tatwo.pets.hall.cancel") }
        }.font(skin.body).foregroundStyle(skin.ink).tint(skin.accent).petCard(skin).frame(width: skin.sheetWidth, height: skin.sheetHeight).accessibilityElement(children: .contain).accessibilityIdentifier("tatwo.pets.hall.editor")
    }
}
