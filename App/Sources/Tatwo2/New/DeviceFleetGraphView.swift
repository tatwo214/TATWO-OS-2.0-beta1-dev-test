import SwiftUI

/// Geometry is shared with the screenshot checks. One route per enabled roster edge.
struct DeviceFleetGraphLayout {
    struct Module: Identifiable {
        var group: DeviceFleetGroup
        var frame: CGRect
        var id: String { group.id }
    }
    struct Card: Identifiable {
        var member: DeviceFleetMember
        var frame: CGRect
        var id: String { member.id }
    }
    struct Arrow: Identifiable {
        var id: Int
        var edge: DeviceFleetEdge
        var points: [CGPoint]
        var label: CGPoint { points[points.count / 2] }
        var headCount: Int { edge.direction == .mutual ? 2 : 1 }
    }
    var modules: [Module] = []
    var cards: [Card] = []
    var arrows: [Arrow] = []
    var size = CGSize(width: 960, height: 320)
    let gap: CGFloat = 14

    init(_ snapshot: DeviceFleetUISnapshot) {
        var y: CGFloat = 12
        for group in snapshot.groups {
            let members = snapshot.devices.filter { $0.groupID == group.id && $0.role != .sandbox }
            let secondaries = members.filter { $0.id != group.primaryDeviceID }
            let height = max(220, CGFloat(secondaries.count) * 108 + 56)
            let box = CGRect(x: 12, y: y, width: 608, height: height)
            modules.append(.init(group: group, frame: box))
            if let primary = members.first(where: { $0.id == group.primaryDeviceID }) {
                cards.append(.init(member: primary, frame: CGRect(x: 36, y: y + height / 2 - 22, width: 196, height: 76)))
            }
            for (index, device) in secondaries.enumerated() {
                cards.append(.init(member: device, frame: CGRect(x: 368, y: y + 52 + CGFloat(index) * 108, width: 220, height: 76)))
            }
            for (index, device) in snapshot.devices.filter({ $0.groupID == group.id && $0.role == .sandbox }).enumerated() {
                cards.append(.init(member: device, frame: CGRect(x: 724, y: y + 52 + CGFloat(index) * 108, width: 220, height: 76)))
            }
            let sandboxBottom = cards.filter { $0.member.groupID == group.id }.map(\.frame.maxY).max() ?? box.maxY
            y = max(box.maxY, sandboxBottom) + 100
        }
        // A sandbox projection may contain no group metadata.
        for member in snapshot.devices where !cards.contains(where: { $0.id == member.id }) {
            cards.append(.init(member: member, frame: CGRect(x: 36, y: y, width: 220, height: 76)))
            y += 100
        }
        size.height = max(260, y - 70)
        size.width = max(660, (cards.map(\.frame.maxX) + modules.map(\.frame.maxX)).max().map { $0 + 16 } ?? 660)
        func frame(_ endpoint: DeviceFleetEndpoint) -> CGRect? {
            endpoint.kind == .group ? modules.first { $0.id == endpoint.id }?.frame : cards.first { $0.id == endpoint.id }?.frame
        }
        for (index, edge) in snapshot.edges.enumerated() where edge.direction != .none {
            guard let a = frame(edge.from), let b = frame(edge.to) else { continue }
            var points: [CGPoint]
            if edge.from.kind == .group && edge.to.kind == .group {
                let downward = b.midY > a.midY
                let x = a.midX + CGFloat(index % 3) * 12
                points = [CGPoint(x: x, y: downward ? a.maxY + gap : a.minY - gap),
                          CGPoint(x: x, y: downward ? b.minY - gap : b.maxY + gap)]
            } else if abs(a.midX - b.midX) < 20 {
                // Route sibling edges beside their column, clear of intervening cards.
                let x = max(a.maxX, b.maxX) + 16 + CGFloat(index % 4) * 5
                points = [CGPoint(x: a.maxX + gap, y: a.midY), CGPoint(x: x, y: a.midY),
                          CGPoint(x: x, y: b.midY), CGPoint(x: b.maxX + gap, y: b.midY)]
            } else if edge.from.kind == .group && b.minX > a.maxX && (a.minY...a.maxY).contains(b.midY) {
                points = [CGPoint(x: a.maxX + gap, y: b.midY), CGPoint(x: b.minX - gap, y: b.midY)]
            } else {
                // Separate ports for each diagonal: no shared arrowheads or hidden branch.
                func port(_ rect: CGRect, toward other: CGRect) -> CGPoint {
                    let expanded = rect.insetBy(dx: -gap, dy: -gap)
                    let dx = other.midX - rect.midX, dy = other.midY - rect.midY
                    let t = min(dx == 0 ? CGFloat.infinity : expanded.width / 2 / abs(dx),
                                dy == 0 ? CGFloat.infinity : expanded.height / 2 / abs(dy))
                    return CGPoint(x: rect.midX + dx * t, y: rect.midY + dy * t)
                }
                points = [port(a, toward: b), port(b, toward: a)]
            }
            // Remove zero-length segments before drawing arrowheads.
            points = points.enumerated().filter { $0.offset == 0 || $0.element != points[$0.offset - 1] }.map(\.element)
            arrows.append(.init(id: index, edge: edge, points: points))
        }
    }
}

struct DeviceFleetGraphView: View {
    let snapshot: DeviceFleetUISnapshot
    var initiallyExpanded: Int? = nil
    @State private var selected: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layout = DeviceFleetGraphLayout(snapshot)
        let expanded = selected ?? initiallyExpanded
        let panelY = max(300, (layout.cards.filter { $0.member.role == .sandbox }.map(\.frame.maxY).max() ?? 0) + 24)
        let graphSize = CGSize(width: expanded == nil ? layout.size.width : max(960, layout.size.width),
                               height: expanded == nil ? layout.size.height : max(layout.size.height, panelY + 360))
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.modules) { module in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(module.group.name).font(.system(size: 15, weight: .bold))
                                DeviceFleetBadge(title: module.group.type.rawValue)
                            }.padding(14)
                            Spacer()
                        }
                        .frame(width: module.frame.width, height: module.frame.height, alignment: .topLeading)
                        .background(DeviceFleetStyle.surface(scheme).opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.3)))
                        .offset(x: module.frame.minX, y: module.frame.minY)
                    }
                    Canvas { context, _ in
                        for arrow in layout.arrows {
                            let color = arrow.edge.direction == .mutual ? DeviceFleetStyle.green : DeviceFleetStyle.terra
                            var path = Path(); path.addLines(arrow.points)
                            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            drawHead(context, tip: arrow.points.last!, toward: arrow.points[arrow.points.count - 2], color: color)
                            if arrow.headCount == 2 { drawHead(context, tip: arrow.points[0], toward: arrow.points[1], color: color) }
                        }
                    }.allowsHitTesting(false)
                    ForEach(layout.cards) { card in
                        DeviceFleetDeviceCard(device: card.member, snapshot: snapshot)
                            .frame(width: card.frame.width, height: card.frame.height)
                            .offset(x: card.frame.minX, y: card.frame.minY)
                    }
                    ForEach(layout.arrows) { arrow in
                        // The hit area follows every segment, including its two arrowheads.
                        FleetArrowHitShape(points: arrow.points)
                            .stroke(Color.clear, style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round))
                            .contentShape(FleetArrowHitShape(points: arrow.points).stroke(style: StrokeStyle(lineWidth: 22)))
                            .onTapGesture { selected = selected == arrow.id ? nil : arrow.id }
                            .accessibilityElement()
                            .accessibilityLabel("\(snapshot.name(arrow.edge.from)) \(arrow.headCount == 2 ? "↔" : "→") \(snapshot.name(arrow.edge.to))；看詳細權限")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("fleet-edge-\(arrow.id)")
                            .accessibilityAction { selected = selected == arrow.id ? nil : arrow.id }
                    }
                    if let index = expanded, snapshot.edges.indices.contains(index) {
                        DeviceFleetPermissionPanel(edge: snapshot.edges[index], snapshot: snapshot)
                            .frame(width: 304).offset(x: 652, y: panelY)
                    }
                }.frame(width: graphSize.width, height: graphSize.height)
            }
            if !snapshot.isStaff && snapshot.groups.contains(where: { $0.type == .sub }) {
                Text(DeviceFleetDefaults.staffRoleExplanation).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Text("↔ 綠＝互通").foregroundStyle(DeviceFleetStyle.green)
                Text("→ 赤陶＝單向").foregroundStyle(DeviceFleetStyle.terra)
                Text("點箭頭看詳細權限").foregroundStyle(.secondary)
            }.font(.caption)
        }
    }

    private func drawHead(_ context: GraphicsContext, tip: CGPoint, toward: CGPoint, color: Color) {
        let angle = atan2(toward.y - tip.y, toward.x - tip.x)
        var path = Path()
        path.move(to: CGPoint(x: tip.x + cos(angle - 0.5) * 9, y: tip.y + sin(angle - 0.5) * 9))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + cos(angle + 0.5) * 9, y: tip.y + sin(angle + 0.5) * 9))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

private struct FleetArrowHitShape: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path { var path = Path(); path.addLines(points); return path }
}

struct DeviceFleetPermissionPanel: View {
    let edge: DeviceFleetEdge
    let snapshot: DeviceFleetUISnapshot
    @Environment(\.colorScheme) private var scheme
    private var capabilities: [(String, String)] { DeviceFleetCapabilities.all.map { ($0, DeviceFleetCapabilities.labels[$0] ?? $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(snapshot.name(edge.from)) \(edge.direction == .mutual ? "↔" : "→") \(snapshot.name(edge.to))")
                .font(.headline)
            Text("方向：\(edge.direction == .mutual ? "↔ 互通" : "→ 單向；只有起點能控制終點")")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Text("這條箭頭能做什麼").font(.subheadline.weight(.semibold))
            if Set(edge.capabilities) == Set(DeviceFleetCapabilities.all), !snapshot.isStaff,
               snapshot.isMAIN(edge.from), snapshot.isMAIN(edge.to) {
                Text(DeviceFleetCapabilities.unrestrictedOwnerExplanation).font(.system(size: 12))
            }
            ForEach(capabilities, id: \.0) { key, label in
                HStack(spacing: 10) {
                    Text(edge.capabilities.contains(key) ? "✓" : "—")
                        .foregroundStyle(edge.capabilities.contains(key) ? DeviceFleetStyle.green : Color.secondary)
                    Text(label)
                }.font(.system(size: 12))
            }
            if edge.direction == .oneway {
                Text("🔒 反方向（\(snapshot.name(edge.to)) → \(snapshot.name(edge.from))）一律不給")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            Text("要改這條，跟 TATWO 助理說").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(DeviceFleetStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DeviceFleetStyle.terra.opacity(0.6)))
    }
}
