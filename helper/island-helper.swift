// DSH native island v8: invisible protocol tests, compact production panel.
import AppKit
import SwiftUI

let isTestProtocol = CommandLine.arguments.contains("--test-protocol")
/// 空闲时也保留一枚很淡的胶囊，避免「没任务 = 什么都没显示」的错觉。
/// 设 DSH_ISLAND_IDLE=0 可关掉，退回「只在有任务时出现」。
let idlePresence = ProcessInfo.processInfo.environment["DSH_ISLAND_IDLE"] != "0"

struct IslandPending {
    var requestId: String
    var kind: String
    var toolName: String
    var reason: String
    var displayReason: String
    var questions: [[String: Any]]
}
struct IslandSession {
    var id: String
    var title: String
    var running: Bool
    var pending: IslandPending?
    var messages: [IslandMessage] = []
    var tokens: Int?
    var remaining: Int?
    var lastActivity: Date?
}
struct IslandMessage: Identifiable {
    let id: Int
    let role: String
    let text: String
    let nodeKey: String?
    var kind = "message"
    var turn: Int?
    var outcome: String?

    static func decode(_ value: Any?) -> [Self] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let seq = entry["seq"] as? Int, let text = entry["text"] as? String else { return nil }
            return Self(id: seq, role: entry["role"] as? String ?? "", text: text, nodeKey: entry["nodeKey"] as? String,
                        kind: entry["kind"] as? String ?? "message", turn: entry["turn"] as? Int, outcome: entry["outcome"] as? String)
        }
    }
}
struct IslandHistory {
    var messages: [IslandMessage] = []
    var before: Int?
    var requestID: String?
    var requestBefore: Int?
    var failedBefore: Int?
    var loaded = false
    var failed = false
}

struct IslandApproval: Identifiable {
    var session: IslandSession
    var pending: IslandPending
    var id: String { pending.requestId }
}
enum IslandMode: String { case compact, expanded }
enum IslandStatus: String { case idle, running, completed, approval }
enum IslandLayout {
    static let width: CGFloat = 392
    static let taskMaxWidth: CGFloat = 560
    static let maxHeight: CGFloat = 312
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22
    static let footerHeight: CGFloat = 34
    static let padding: CGFloat = 14
    static let compactNotchWing: CGFloat = 48
}

/// 当前应显示灵动岛的屏幕。
/// 优先鼠标所在的那块屏——外接显示器上也就能看到，而不是永远钉在内置刘海屏上。
/// 找不到鼠标位置时退回带刘海的屏，再退回主屏。
func islandScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    if let under = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return under }
    return NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main
}

/// 指定屏幕的刘海宽度；没有刘海的屏（外接显示器）给一个稳定的默认值。
func notchWidth(of screen: NSScreen?) -> CGFloat {
    guard let screen = screen, let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea else { return 185 }
    return screen.frame.width - left.width - right.width
}
func islandContentTopInset() -> CGFloat {
    let screen = islandScreen()
    let menuHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 33
    return max(menuHeight, 33) + 5
}
func islandNotchWidth() -> CGFloat {
    guard let screen = islandScreen(), let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea else { return 185 }
    return screen.frame.width - left.width - right.width
}
func stripEscalationPrefix(_ text: String) -> String {
    text.replacingOccurrences(of: "^escalate sandbox to [^:]*:\\s*", with: "", options: .regularExpression)
}
func approvalText(_ pending: IslandPending) -> String {
    if pending.kind == "ask_user_question" {
        return pending.questions.map { question in
            var parts: [String] = []
            if let title = question["header"] as? String, !title.isEmpty { parts.append(title) }
            if let body = question["question"] as? String, !body.isEmpty { parts.append(body) }
            for option in question["options"] as? [[String: Any]] ?? [] {
                let title = option["label"] as? String ?? option["title"] as? String ?? ""
                let detail = option["description"] as? String ?? ""
                parts.append([title, detail].filter { !$0.isEmpty }.joined(separator: "："))
            }
            if parts.isEmpty, let data = try? JSONSerialization.data(withJSONObject: question, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { parts.append(text) }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    let display = pending.displayReason.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = pending.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if display.isEmpty { return reason.isEmpty ? "此审批未提供操作说明，请在 DSH 查看原始请求。" : reason }
    if reason.isEmpty || display == reason { return display }
    return display + "\n\n" + reason
}

final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .compact
    @Published var metrics = islandMetrics(on: nil)
    @Published var sessions: [IslandSession] = []
    @Published var recent: [IslandSession] = []
    @Published var recentState = "loading"
    @Published var selectedSessionID: String?
    @Published var showingConversation = false
    @Published var histories: [String: IslandHistory] = [:]
    private var openedSession: IslandSession?
    @Published var drafts: [String: String] = [:]
    @Published var replyFeedback: [String: String] = [:]
    @Published var pendingReplies: [String: String] = [:]
    @Published var unreadDeliveries: [IslandSession] = []
    @Published var completedFlash: [IslandSession] = []
    @Published var selectedRequestID: String?
    @Published var submitting: Set<String> = []
    @Published var feedback: [String: String] = [:]
    var manualExpanded = false
    var notificationVisibleUntil = Date.distantPast
    private var knownPendingIDs: Set<String> = []
    var onModeChange: (() -> Void)?
    var eventSink: ([String: Any]) -> Void
    init(eventSink: @escaping ([String: Any]) -> Void) { self.eventSink = eventSink }

    var approvals: [IslandApproval] {
        sessions.compactMap { row in row.pending.map { IslandApproval(session: row, pending: $0) } }
    }
    var hasPending: Bool { !approvals.isEmpty }
    var consoleRows: [IslandSession] {
        var rows: [IslandSession] = []
        for active in sessions where active.pending != nil {
            var row = recent.first(where: { $0.id == active.id }) ?? active
            row.running = active.running
            row.pending = active.pending
            rows.append(row)
        }
        let deliveries = unreadDeliveries.map { delivery in
            recent.first(where: { $0.id == delivery.id }) ?? delivery
        }
        for var row in deliveries + recent + sessions + completedFlash where !rows.contains(where: { $0.id == row.id }) {
            let current = sessions.first(where: { $0.id == row.id })
            row.pending = current?.pending
            row.running = current?.running ?? false
            rows.append(row)
        }
        return Array(rows.prefix(3))
    }
    var selectedSession: IslandSession? {
        consoleRows.first(where: { $0.id == selectedSessionID }) ?? openedSession ?? consoleRows.first
    }
    var selectedApproval: IslandApproval? {
        guard let row = selectedSession, let pending = row.pending else { return nil }
        return IslandApproval(session: row, pending: pending)
    }

    func showConversation(_ row: IslandSession) {
        openedSession = row
        unreadDeliveries.removeAll { $0.id == row.id }
        selectedSessionID = row.id
        let keep = Set(consoleRows.map(\.id) + [row.id])
        histories = histories.filter { keep.contains($0.key) }
        showingConversation = true
    }

    func receiveDelivery(_ delivery: IslandSession) {
        if mode == .expanded && showingConversation && selectedSessionID == delivery.id { return }
        unreadDeliveries.removeAll { $0.id == delivery.id }
        unreadDeliveries.insert(delivery, at: 0)
        if unreadDeliveries.count > 24 { unreadDeliveries.removeLast() }
        guard !hasPending, !showingConversation else { return }
        manualExpanded = true
        notificationVisibleUntil = Date().addingTimeInterval(5)
        if mode != .expanded {
            mode = .expanded
            onModeChange?()
        }
    }

    func requestHistory(_ sessionID: String, before: Int? = nil) {
        guard showingConversation, selectedSessionID == sessionID,
              histories[sessionID]?.requestID == nil else { return }
        var state = histories[sessionID] ?? IslandHistory()
        let requestID = UUID().uuidString
        state.requestID = requestID
        state.requestBefore = before
        state.failed = false
        histories[sessionID] = state
        var event: [String: Any] = ["type": "history", "requestId": requestID, "sessionId": sessionID]
        if let before { event["beforeSeq"] = before }
        eventSink(event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.receiveHistory(sessionID, requestID: requestID, page: nil)
        }
    }

    func receiveHistory(_ sessionID: String, requestID: String, page: [String: Any]?) {
        guard var state = histories[sessionID], state.requestID == requestID else { return }
        let older = state.requestBefore != nil
        state.requestID = nil
        state.failedBefore = page == nil ? state.requestBefore : nil
        state.requestBefore = nil
        state.failed = page == nil
        if let page {
            let incoming = IslandMessage.decode(page["messages"])
            let reconnects = incoming.isEmpty || state.messages.isEmpty || incoming.contains { message in
                state.messages.contains { $0.id == message.id }
            }
            let merge = older || reconnects
            var byID: [Int: IslandMessage] = [:]
            if merge { for message in state.messages { byID[message.id] = message } }
            for message in incoming { byID[message.id] = message }
            state.messages = byID.values.sorted { $0.id < $1.id }
            if older || !state.loaded || !merge { state.before = page["nextBefore"] as? Int }
            state.loaded = true
        }
        histories[sessionID] = state
    }

    func sendReply(to row: IslandSession) {
        let text = drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000, pendingReplies[row.id] == nil else { return }
        let requestID = UUID().uuidString
        pendingReplies[row.id] = requestID
        replyFeedback[row.id] = "发送中…"
        eventSink(["type": "reply", "sessionId": row.id, "requestId": requestID, "text": text])
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self, self.pendingReplies[row.id] == requestID else { return }
            self.replyFeedback[row.id] = "请在 DSH 确认发送状态"
        }
    }

    func finishReply(sessionID: String, requestID: String, ok: Bool) {
        guard pendingReplies[sessionID] == requestID else { return }
        pendingReplies.removeValue(forKey: sessionID)
        if ok { drafts.removeValue(forKey: sessionID) }
        replyFeedback[sessionID] = ok ? "已提交" : "未能发送，请重试"
    }

    func answerQuestion(_ requestID: String, answers: [[String: Any]]) {
        guard selectedApproval?.id == requestID, !submitting.contains(requestID) else { return }
        submitting.insert(requestID)
        feedback[requestID] = "提交中…"
        eventSink(["type": "decision", "kind": "ask_user_question", "requestId": requestID, "answers": answers])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.submitting.remove(requestID) != nil else { return }
            self.feedback[requestID] = "尚未确认，请重试"
        }
    }

    var visibleTasks: [IslandSession] { hasPending ? [] : sessions }
    var visibleCompletions: [IslandSession] { hasPending ? [] : completedFlash }
    var activeApproval: IslandApproval? {
        approvals.first(where: { $0.id == selectedRequestID }) ?? approvals.first
    }
    var approvalIndex: Int { approvals.firstIndex(where: { $0.id == (selectedApproval ?? activeApproval)?.id }) ?? 0 }
    var status: IslandStatus {
        if hasPending { return .approval }
        if !completedFlash.isEmpty { return .completed }
        return runningCount > 0 ? .running : .idle
    }
    var runningCount: Int { hasPending ? 0 : sessions.filter { $0.running }.count }
    var hasContent: Bool { !sessions.isEmpty || !completedFlash.isEmpty }

    func toggleMode() {
        manualExpanded = true
        mode = mode == .expanded ? .compact : .expanded
        showingConversation = false
        onModeChange?()
    }
    func dismiss() {
        guard mode == .expanded else { return }
        manualExpanded = true
        mode = .compact
        showingConversation = false
        onModeChange?()
    }
    func selectApproval(offset: Int) {
        let items = approvals
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selectedApproval?.id }) ?? approvalIndex
        let selected = items[min(max(index + offset, 0), items.count - 1)]
        selectedRequestID = selected.id
        showConversation(selected.session)
        onModeChange?()
    }
    func autoExpandIfNeeded() {
        let ids = Set(approvals.map { $0.id })
        let previousPendingIDs = knownPendingIDs
        let hasNew = !ids.subtracting(previousPendingIDs).isEmpty
        knownPendingIDs = ids
        if let selected = selectedRequestID, !ids.contains(selected) { selectedRequestID = nil }
        if selectedRequestID == nil { selectedRequestID = approvals.first?.id }
        submitting.formIntersection(ids)
        feedback = feedback.filter { ids.contains($0.key) }
        if hasNew {
            if let request = approvals.first(where: { !previousPendingIDs.contains($0.id) }) {
                showConversation(request.session)
            }
            manualExpanded = false
            notificationVisibleUntil = Date().addingTimeInterval(5)
            if mode != .expanded { mode = .expanded; onModeChange?() }
        } else if (!hasContent && recent.isEmpty && unreadDeliveries.isEmpty) || (ids.isEmpty && !manualExpanded) {
            if mode != .compact { mode = .compact; showingConversation = false; onModeChange?() }
        }
    }
    func submit(_ id: String, outcome: String, send: (String, String) -> Void) {
        guard approvals.contains(where: { $0.id == id && $0.pending.kind == "permission" }),
              !submitting.contains(id), ["allowed-once", "rejected"].contains(outcome) else { return }
        submitting.insert(id)
        feedback[id] = "提交中…"
        send(id, outcome)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.submitting.contains(id) else { return }
            self.submitting.remove(id)
            self.feedback[id] = "尚未确认，请重试"
        }
    }
}

func approvalBodyHeight(_ text: String) -> CGFloat {
    // Text wraps within the full content width; the viewport, never the text, is capped.
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    let bounds = (text as NSString).boundingRect(
        with: CGSize(width: IslandLayout.width - IslandLayout.padding * 2 - 8, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph]
    )
    return max(24, ceil(bounds.height) + 8)
}
/// 刘海度量：直接问 macOS 要安全区与 aux 区域，比硬编码宽度准。
/// 非刘海屏（外接显示器）走 hasNotch = false 的胶囊形态。
struct IslandMetrics: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
}

func islandMetrics(on screen: NSScreen?) -> IslandMetrics {
    guard let s = screen else { return IslandMetrics(hasNotch: false, notchWidth: 200, notchHeight: 32) }
    let safeTop = s.safeAreaInsets.top
    if safeTop > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea,
       left.width > 0, right.width > 0 {
        return IslandMetrics(hasNotch: true,
                             notchWidth: right.minX - left.maxX,
                             notchHeight: safeTop)
    }
    return IslandMetrics(hasNotch: false, notchWidth: 200, notchHeight: 32)
}

/// 形状尺寸。收起态贴着刘海长出来，展开态向下铺内容。
func islandShapeSize(model: IslandModel, metrics: IslandMetrics, expanded: Bool,
                     maxHeight: CGFloat, availableWidth: CGFloat) -> CGSize {
    let baseW = metrics.notchWidth
    let baseH = metrics.notchHeight

    if !metrics.hasNotch {
        // 外接屏：用独立胶囊，尺寸不动
        if expanded {
            return CGSize(width: min(availableWidth, 500), height: min(maxHeight, 284))
        }
        if !model.hasContent { return CGSize(width: 44, height: 22) }
        return CGSize(width: model.hasPending ? 74 : 66, height: 28)
    }

    if !expanded {
        let wing = model.hasContent || idlePresence ? IslandLayout.compactNotchWing : 0
        // Keep the trailing edge inside the physical notch, including its stroke.
        return CGSize(width: baseW + wing - 2, height: baseH)
    }

    return CGSize(width: min(availableWidth, max(baseW + 80, 500)), height: min(maxHeight, baseH + 252))
}
func islandHorizontalOffset(model: IslandModel, metrics: IslandMetrics, expanded: Bool) -> CGFloat {
    if metrics.hasNotch && !expanded && (model.hasContent || idlePresence) {
        return -IslandLayout.compactNotchWing / 2
    }
    return 0
}

func islandContains(_ point: CGPoint, frame: CGRect, radius: CGFloat = 16) -> Bool {
    guard frame.contains(point) else { return false }
    let r = min(radius, frame.height / 2, frame.width / 2)
    if point.y < frame.minY + r {
        if point.x < frame.minX + r {
            return hypot(point.x - frame.minX - r, point.y - frame.minY - r) <= r
        }
        if point.x > frame.maxX - r {
            return hypot(point.x - frame.maxX + r, point.y - frame.minY - r) <= r
        }
    }
    return true
}

/// 顶部两角是「内凹」的二次曲线，能与物理刘海严丝合缝地续接；
/// 底部两角是外向圆角，正是 Dynamic Island 的经典剪影。
/// 参数参考 farouqaldori/claude-island：收起 6/14，展开 19/24。
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = min(topCornerRadius, rect.width / 2)
        let b = min(bottomCornerRadius, rect.height / 2)

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 左上：向内凹
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        // 左下：外圆角
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        // 右下：外圆角
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        // 右上：向内凹
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return p
    }
}
let islandOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
let islandGreen = Color(red: 0.30, green: 0.80, blue: 0.45)

private enum IslandPalette {
    static let ink = Color(white: 0.92)
    static let muted = Color(white: 0.62)
    static let surface = Color(white: 0.15)
    static let line = Color.white.opacity(0.095)
    static let blue = Color(red: 0.61, green: 0.73, blue: 0.90)
    static let lilac = Color(red: 0.77, green: 0.72, blue: 0.86)
}

struct IslandMarkdownBlock {
    enum Kind: Equatable {
        case paragraph, heading, quote, list(String), code
    }

    let id: Int
    let kind: Kind
    var text: AttributedString

    static func parse(_ source: String) -> [Self] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options), !parsed.characters.isEmpty else {
            return [Self(id: 0, kind: .paragraph, text: AttributedString(source))]
        }

        var blocks: [Self] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var fragment = AttributedString(parsed[run.range])
            // The message card owns navigation to the corresponding conversation.
            if run.link != nil {
                fragment.link = nil
                fragment.foregroundColor = IslandPalette.blue
                fragment.underlineStyle = .single
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                fragment.font = .system(size: 10.5, design: .monospaced)
                fragment.foregroundColor = IslandPalette.lilac
            }
            if blocks.last?.id == id {
                blocks[blocks.count - 1].text.append(fragment)
                continue
            }

            var kind = Kind.paragraph
            var order: Int?
            var isOrdered = false
            for component in components {
                switch component.kind {
                case .header: kind = .heading
                case .codeBlock: kind = .code
                case .blockQuote: if kind == .paragraph { kind = .quote }
                case let .listItem(ordinal): if order == nil { order = ordinal }
                case .orderedList: isOrdered = true
                default: break
                }
            }
            if let order, kind != .code { kind = .list(isOrdered ? "\(order)." : "•") }
            blocks.append(Self(id: id, kind: kind, text: fragment))
        }
        return blocks
    }
}

private struct IslandMarkdownPreview: View {
    let source: String
    var full = false

    var body: some View {
        let blocks = IslandMarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array((full ? blocks[...] : blocks.prefix(8)).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .heading:
                    Text(block.text).font(.system(size: 12.5, weight: .semibold)).lineLimit(full ? nil : 2)
                case .paragraph:
                    Text(block.text).font(.system(size: 11.5)).lineLimit(full ? nil : 5)
                case .list(let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(marker).foregroundStyle(IslandPalette.blue).accessibilityHidden(true)
                        Text(block.text).lineLimit(full ? nil : 3)
                    }.font(.system(size: 11.5))
                case .quote:
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(IslandPalette.blue.opacity(0.5))
                            .frame(width: 2)
                        Text(block.text).lineLimit(full ? nil : 3).foregroundStyle(IslandPalette.muted)
                    }
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                case .code:
                    Text(block.text).font(.system(size: 10.5, design: .monospaced)).lineLimit(full ? nil : 5)
                        .foregroundStyle(IslandPalette.lilac)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(IslandPalette.lilac.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if !full && blocks.count > 8 {
                Text("…").font(.system(size: 11)).foregroundStyle(IslandPalette.muted)
            }
        }
        .foregroundStyle(IslandPalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IslandIconButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundColor(IslandPalette.muted.opacity(disabled ? 0.40 : 1))
                .frame(width: 20, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
    }
}
final class IslandViewInteraction: ObservableObject {
    @Published var hovered = false
    @Published var copied = false
}
struct ApprovalContentView: View {
    @ObservedObject var model: IslandModel
    let item: IslandApproval
    let height: CGFloat
    let width: CGFloat
    let onOpen: (String) -> Void
    let onDecision: (String, String) -> Void
    @ObservedObject private var interaction = IslandViewInteraction()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(islandOrange).frame(width: 6, height: 6)
                Button { onOpen(item.session.id) } label: {
                    Text(item.session.title.isEmpty ? "待审批" : item.session.title)
                        .font(.system(size: 13, weight: .medium)).foregroundColor(IslandPalette.ink)
                        .lineLimit(1)
                }.buttonStyle(.plain).help(item.session.title + "：点击打开对应对话")
                    .accessibilityLabel("打开对话：" + (item.session.title.isEmpty ? "待审批任务" : item.session.title))
                Spacer(minLength: 0)
                if model.approvals.count > 1 {
                    IslandIconButton(symbol: "chevron.left", label: "上一条审批", disabled: model.approvalIndex == 0) { model.selectApproval(offset: -1) }
                    Text("\(model.approvalIndex + 1)/\(model.approvals.count)")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(IslandPalette.muted)
                    IslandIconButton(symbol: "chevron.right", label: "下一条审批", disabled: model.approvalIndex == model.approvals.count - 1) { model.selectApproval(offset: 1) }
                }
                IslandIconButton(symbol: "chevron.up", label: "收起审批") { model.dismiss() }
            }
            .padding(.horizontal, IslandLayout.padding)
            .frame(width: width, height: IslandLayout.headerHeight)
            ScrollView(.vertical) {
                IslandMarkdownPreview(source: approvalText(item.pending))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(0, width - IslandLayout.padding * 2 - 8), alignment: .leading)
                    .padding(.leading, IslandLayout.padding + 8).padding(.trailing, IslandLayout.padding)
                    .padding(.vertical, 4)
            }
            .frame(width: width)
            .id(item.id)
            .frame(height: max(0, height - IslandLayout.headerHeight - IslandLayout.footerHeight))
            HStack(spacing: 8) {
                IslandIconButton(symbol: interaction.copied ? "checkmark" : "doc.on.doc", label: "复制审批全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(approvalText(item.pending), forType: .string)
                    interaction.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { interaction.copied = false }
                }
                if let feedback = model.feedback[item.id] {
                    Text(feedback).font(.system(size: 10)).foregroundColor(IslandPalette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.pending.kind == "ask_user_question" {
                    Button("在 DSH 回答") { onOpen(item.session.id) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white).padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.38, blue: 0.57)))
                } else {
                    Button("拒绝") { model.submit(item.id, outcome: "rejected", send: onDecision) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(IslandPalette.ink)
                        .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(IslandPalette.surface))
                        .disabled(model.submitting.contains(item.id))
                    Button("同意一次") { model.submit(item.id, outcome: "allowed-once", send: onDecision) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Color(red: 0.25, green: 0.38, blue: 0.57)))
                        .disabled(model.submitting.contains(item.id))
                }
            }
            .padding(.horizontal, IslandLayout.padding).frame(height: IslandLayout.footerHeight)
            .overlay(alignment: .top) { Rectangle().fill(IslandPalette.line).frame(height: 0.5).padding(.horizontal, IslandLayout.padding) }
        }.frame(height: height, alignment: .top)
    }
}
private struct IslandTokenLabel: View {
    var body: some View {
        Text("token")
            .fixedSize()
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(Color(red: 0.65, green: 0.75, blue: 0.86))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(red: 0.41, green: 0.54, blue: 0.69).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}

private struct IslandUsage: View {
    let remaining: Int?
    let tokens: Int?

    private static let context = icon(#"<circle cx="8" cy="8" r="5.4"/><path d="M8 5v3l2.1 1.4"/>"#)

    private static func icon(_ paths: String) -> NSImage? {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
          <g fill="none" stroke="black" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round">\(paths)</g>
        </svg>
        """
        return NSImage(data: Data(svg.utf8))
    }

    var body: some View {
        HStack(spacing: 14) {
            if let remaining {
                let used = 100 - min(100, max(0, remaining))
                metric(Self.context, value: "\(used)%", help: "上下文已用 \(used)%，剩余 \(100 - used)%")
            }
            if let tokens {
                HStack(spacing: 4) {
                    IslandTokenLabel()
                    Text(tokens.formatted()).font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(IslandPalette.muted)
                }
                .fixedSize()
                .help("累计 \(tokens.formatted()) Token（含缓存）")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("累计 \(tokens.formatted()) Token")
            }
        }
    }

    private func metric(_ icon: NSImage?, value: String, help: String) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 13, height: 13)
            }
            Text(value).font(.system(size: 10.5)).monospacedDigit()
        }
        .foregroundStyle(IslandPalette.muted)
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

struct IslandConsoleView: View {
    @ObservedObject var model: IslandModel
    let width: CGFloat
    let height: CGFloat
    let onOpen: (String) -> Void
    let onDecision: (String, String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.showingConversation, let row = model.selectedSession {
                detail(row)
                    .transition(pageTransition(edge: .trailing))
            } else {
                list
                    .transition(pageTransition(edge: .leading))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.showingConversation)
        .onExitCommand {
            if model.showingConversation { model.showingConversation = false }
            else { model.dismiss() }
        }
    }

    private func pageTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var list: some View {
        let rows = model.consoleRows
        let tags = IslandSessionTag.forSessions(rows.map(\.id))
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                IslandIconButton(symbol: "chevron.up", label: "收起") { model.dismiss() }
            }
            .frame(height: 23)
            .padding(.horizontal, 10)

            if rows.isEmpty {
                if model.recentState == "loading" {
                    IslandRecentLoading()
                } else {
                    Text(model.recentState == "unavailable" ? "暂时无法读取会话" : "暂无最近会话")
                        .font(.system(size: 12)).foregroundStyle(IslandPalette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        IslandConversationRow(row: row, tint: tags[row.id] ?? IslandPalette.muted, order: offset,
                                              unread: model.unreadDeliveries.contains(where: { $0.id == row.id })) {
                            model.showConversation(row)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
    }

    private func detail(_ row: IslandSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IslandIconButton(symbol: "chevron.left", label: "返回最近会话") { model.showingConversation = false }
                Menu {
                    ForEach(model.consoleRows, id: \.id) { option in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.17)) {
                                model.showConversation(option)
                            }
                        } label: {
                            if row.id == option.id { Label(title(option), systemImage: "checkmark") }
                            else { Text(title(option)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(title(row)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(IslandPalette.ink)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .help("快速切换会话")
                Spacer(minLength: 6)
                IslandUsage(remaining: row.remaining, tokens: row.tokens)
                IslandIconButton(symbol: "arrow.up.right", label: "在 DSH 打开会话") { onOpen(row.id) }
            }
            .frame(height: 32)
            .padding(.horizontal, 10)
            Rectangle().fill(IslandPalette.line).frame(height: 1).padding(.horizontal, 12)

            if let approval = model.selectedApproval, approval.pending.kind == "permission" {
                ApprovalContentView(model: model, item: approval, height: max(0, height - 45),
                                    width: width, onOpen: onOpen, onDecision: onDecision)
            } else if let approval = model.selectedApproval {
                IslandQuestionView(model: model, approval: approval)
                    .id(approval.id)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            } else {
                IslandConversationHistory(model: model, row: row)
                    .id(row.id)
                    .transition(.opacity)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 12)
    }

    private func title(_ row: IslandSession) -> String {
        row.title.isEmpty ? "未命名会话" : row.title
    }
}

private enum IslandSessionTag {
    static let colors = [
        Color(red: 0.48, green: 0.75, blue: 0.62),
        Color(red: 0.55, green: 0.68, blue: 0.91),
        Color(red: 0.83, green: 0.66, blue: 0.47),
        Color(red: 0.72, green: 0.60, blue: 0.86),
        Color(red: 0.81, green: 0.58, blue: 0.63),
        Color(red: 0.52, green: 0.72, blue: 0.75),
        Color(red: 0.76, green: 0.73, blue: 0.54),
    ]

    static func forSessions(_ ids: [String]) -> [String: Color] {
        var occupied: Set<Int> = []
        var tags: [String: Color] = [:]
        for id in Set(ids).sorted() {
            let hash = id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
            var slot = Int(hash % UInt32(colors.count))
            while occupied.count < colors.count && occupied.contains(slot) {
                slot = (slot + 1) % colors.count
            }
            occupied.insert(slot)
            tags[id] = colors[slot]
        }
        return tags
    }
}

private struct IslandRecentLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 10) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(width: 2, height: 19)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.white.opacity(0.10)).frame(width: CGFloat(108 - index * 13), height: 6)
                        Capsule().fill(Color.white.opacity(0.055)).frame(width: CGFloat(145 - index * 19), height: 4)
                    }
                    Spacer()
                    Capsule().fill(Color.white.opacity(0.054)).frame(width: 30, height: 4)
                }
                .padding(.horizontal, 9)
                .frame(height: 54)
                Rectangle().fill(IslandPalette.line).frame(height: 1).padding(.horizontal, 9)
            }
        }
        .accessibilityLabel("正在读取会话")
    }
}

private struct IslandConversationRow: View {
    let row: IslandSession
    let tint: Color
    let order: Int
    var unread = false
    let onSelect: () -> Void
    @State private var appeared = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { row.title.isEmpty ? "未命名会话" : row.title }
    private var status: String? {
        if let pending = row.pending { return pending.kind == "permission" ? "待审批" : "待回复" }
        return row.running ? "运行中" : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    identity
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(IslandPalette.ink).lineLimit(1).truncationMode(.tail)
                            if unread {
                                Circle().fill(Color(red: 0.94, green: 0.31, blue: 0.33)).frame(width: 5, height: 5)
                                    .accessibilityLabel("有新交付")
                            }
                        }
                        if let status {
                            HStack(spacing: 5) {
                                Circle().fill(row.pending == nil ? islandGreen : islandOrange).frame(width: 4, height: 4)
                                Text(status).font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(row.pending == nil ? IslandPalette.muted : islandOrange)
                        } else if let preview = row.messages.last?.text {
                            Text(IslandMarkdownBlock.parse(preview).first?.text ?? AttributedString(preview))
                                .font(.system(size: 10.5)).foregroundStyle(IslandPalette.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    rowMetrics
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(hovered ? IslandPalette.ink : IslandPalette.muted)
                        .offset(x: hovered && !reduceMotion ? 2 : 0)
                        .frame(width: 9)
                }
                .padding(.horizontal, 9)
                .frame(height: 54)
                .background(hovered ? IslandPalette.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .onHover { over in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovered = over } }
            Rectangle().fill(IslandPalette.line).frame(height: 1).padding(.horizontal, 9)
        }
        .opacity(appeared || reduceMotion ? 1 : 0.78)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20).delay(Double(order) * 0.035)) {
                appeared = true
            }
        }
    }

    private var identity: some View {
        Capsule()
            .fill(tint.opacity(0.74))
            .frame(width: 2, height: 19)
            .accessibilityHidden(true)
    }

    private var rowMetrics: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let date = row.lastActivity {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(relative(date, now: context.date)).font(.system(size: 10.5))
                        .foregroundStyle(IslandPalette.ink.opacity(0.78))
                }
            }
            if let tokens = row.tokens {
                HStack(spacing: 4) {
                    IslandTokenLabel()
                    Text(shortTokens(tokens)).monospacedDigit().font(.system(size: 10))
                        .accessibilityLabel("累计 \(tokens.formatted()) Token")
                }
                .foregroundStyle(IslandPalette.muted)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 57, alignment: .trailing)
    }

    private var helpText: String {
        var lines = [title]
        if unread { lines.append("有新交付，点击查看") }
        if let date = row.lastActivity { lines.append("最近活跃：\(date.formatted(date: .abbreviated, time: .shortened))") }
        if let tokens = row.tokens { lines.append("累计 \(tokens.formatted()) Token（含缓存）") }
        return lines.joined(separator: "\n")
    }

    private func shortTokens(_ tokens: Int) -> String {
        for (size, suffix) in [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")] {
            if tokens >= size {
                return (Double(tokens) / Double(size)).formatted(.number.precision(.fractionLength(0...1))) + suffix
            }
        }
        return tokens.formatted()
    }

    private func relative(_ date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) 小时前" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400)) 天前" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

private struct IslandHistoryEntry: Identifiable {
    var items: [IslandMessage]
    var id: Int { items[0].id }
    var isProcess: Bool { items[0].kind != "message" }

    static func group(_ messages: [IslandMessage]) -> [Self] {
        var entries: [Self] = []
        for message in messages {
            if message.kind != "message", let previous = entries.last, previous.isProcess,
               previous.items.last?.turn == message.turn {
                entries[entries.count - 1].items.append(message)
            } else {
                entries.append(Self(items: [message]))
            }
        }
        return entries
    }
}

private struct IslandProcessDisclosure: View {
    let records: [IslandMessage]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(records) { record in
                    if record.kind == "tool" {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal").font(.system(size: 9))
                            Text(record.text).font(.system(size: 10.5, design: .monospaced))
                            Spacer()
                            if let outcome = record.outcome {
                                Text(outcome == "error" ? "失败" : "完成").font(.system(size: 10))
                                    .foregroundStyle(outcome == "error" ? islandOrange : IslandPalette.muted)
                            }
                        }
                        .foregroundStyle(IslandPalette.muted)
                    } else {
                        IslandMarkdownPreview(source: record.text).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10))
                Text("执行过程").font(.system(size: 11, weight: .medium))
                let calls = records.filter { $0.kind == "tool" }.count
                if calls > 0 { Text("\(calls) 次调用").font(.system(size: 10)).monospacedDigit() }
            }
            .foregroundStyle(IslandPalette.muted)
        }
        .tint(IslandPalette.muted)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct HistoryTop: PreferenceKey {
    static let defaultValue: CGFloat = -.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct IslandConversationHistory: View {
    @ObservedObject var model: IslandModel
    let row: IslandSession
    @State private var positioned = false
    @State private var restoreAnchor: Int?
    @State private var newestSeen: Int?
    private var history: IslandHistory { model.histories[row.id] ?? IslandHistory() }

    var body: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                historyScroll
                .onAppear {
                    newestSeen = row.messages.last?.id
                    if history.loaded { position(proxy) }
                    model.requestHistory(row.id)
                }
                .onChange(of: history.loaded) { loaded in if loaded { position(proxy) } }
                .onChange(of: history.before) { _ in
                    guard let anchor = restoreAnchor else { return }
                    restoreAnchor = nil
                    DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                }
                .onChange(of: row.messages.last?.id) { refreshLatest($0) }
                .onChange(of: history.requestID) { request in
                    if request == nil { refreshLatest(row.messages.last?.id) }
                }
            }
            reply
        }
    }

    private var scrollContent: some View {
        ScrollView(.vertical) {
            // Scroll-to-tail needs measured Markdown heights. LazyVStack can leave
            // the viewport on an unrendered estimated spacer for long messages.
            VStack(alignment: .leading, spacing: 10) {
                header
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: HistoryTop.self, value: geo.frame(in: .named("history")).maxY)
                        }
                    }
                ForEach(IslandHistoryEntry.group(history.loaded ? history.messages : row.messages)) { entry in
                    if entry.isProcess {
                        IslandProcessDisclosure(records: entry.items).id(entry.id)
                    } else {
                        messageRow(entry.items[0]).id(entry.id)
                    }
                }
                Color.clear.frame(height: 1).id("tail")
            }
            .padding(.vertical, 8)
        }
        .coordinateSpace(name: "history")
    }

    @ViewBuilder private var historyScroll: some View {
        if #available(macOS 15.0, *) {
            scrollContent
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top + 18
                } action: { _, atTop in
                    if atTop { loadEarlierAtTop() }
                }
        } else {
            scrollContent.onPreferenceChange(HistoryTop.self) { top in
                if top >= -2 { loadEarlierAtTop() }
            }
        }
    }

    private func loadEarlierAtTop() {
        guard positioned, !history.failed, let before = history.before else { return }
        loadOlder(before)
    }

    @ViewBuilder private var header: some View {
        if history.failed {
            Button("历史加载失败，重试") {
                if let before = history.failedBefore { loadOlder(before) }
                else { model.requestHistory(row.id) }
            }
            .buttonStyle(.plain).foregroundStyle(IslandPalette.ink).font(.system(size: 11))
        } else if !history.loaded && row.messages.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取对话").font(.system(size: 11)).foregroundStyle(IslandPalette.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 14)
        } else if history.requestBefore != nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if let before = history.before {
            Button("加载更早消息") { loadOlder(before) }
                .buttonStyle(.plain).foregroundStyle(IslandPalette.muted).font(.system(size: 10))
        } else if history.loaded && history.messages.isEmpty {
            Text("暂无文本消息").font(.system(size: 11)).foregroundStyle(IslandPalette.muted)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func refreshLatest(_ latest: Int?) {
        guard let latest, latest != newestSeen, history.requestID == nil else { return }
        newestSeen = latest
        model.requestHistory(row.id)
    }

    private func position(_ proxy: ScrollViewProxy) {
        guard !positioned else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("tail", anchor: .bottom)
            // Lazy rows resolve their final Markdown height after the first scroll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard !positioned else { return }
                proxy.scrollTo("tail", anchor: .bottom)
                positioned = true
            }
        }
    }

    private func loadOlder(_ before: Int) {
        guard history.requestID == nil else { return }
        restoreAnchor = history.messages.first(where: { $0.kind == "message" })?.id ?? history.messages.first?.id
        model.requestHistory(row.id, before: before)
    }

    private func messageRow(_ message: IslandMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(message.role == "user" ? "你" : "DeepSeek")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(IslandPalette.muted)
                Spacer()
                IslandIconButton(symbol: "arrow.up.right", label: "在 DSH 中查看这条消息") {
                    var event: [String: Any] = ["type": "open", "sessionId": row.id]
                    if let key = message.nodeKey { event["nodeKey"] = key }
                    model.eventSink(event)
                    model.dismiss()
                }
            }
            IslandMarkdownPreview(source: message.text, full: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(IslandPalette.line).frame(height: 1) }
    }

    private var reply: some View {
        HStack(spacing: 6) {
            TextField("输入回复", text: Binding(
                get: { model.drafts[row.id, default: ""] },
                set: { model.drafts[row.id] = String($0.prefix(4000)) }
            ), prompt: Text("输入回复").foregroundStyle(IslandPalette.muted))
            .textFieldStyle(.plain)
            .foregroundStyle(IslandPalette.ink)
            .font(.system(size: 11.5))
            .disabled(model.pendingReplies[row.id] != nil)
            .onSubmit { model.sendReply(to: row) }
            if let status = model.replyFeedback[row.id] {
                Text(status).font(.system(size: 10)).foregroundStyle(IslandPalette.muted)
            }
            IslandIconButton(symbol: "arrow.up.circle", label: "发送回复",
                             disabled: model.pendingReplies[row.id] != nil || model.drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                model.sendReply(to: row)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct IslandQuestionView: View {
    @ObservedObject var model: IslandModel
    let approval: IslandApproval
    @State private var choices: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]

    private func questionID(_ item: [String: Any]) -> String { item["id"] as? String ?? "" }
    private func multi(_ item: [String: Any]) -> Bool { item["multiSelect"] as? Bool == true }
    private func permitsText(_ item: [String: Any]) -> Bool {
        (item["intent"] as? [String: Any])?["kind"] as? String != "approval"
    }
    private var questions: [[String: Any]] { approval.pending.questions }
    private var ready: Bool {
        !questions.isEmpty && questions.allSatisfy { item in
            let id = questionID(item)
            return !id.isEmpty && (!choices[id, default: []].isEmpty ||
                !custom[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(questions.indices, id: \.self) { index in
                        let item = questions[index]
                        let id = questionID(item)
                        Text(item["question"] as? String ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IslandPalette.ink)
                        if let detail = item["detail"] as? String {
                            IslandMarkdownPreview(source: detail)
                        }
                        ForEach((item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }, id: \.self) { label in
                            Button {
                                if choices[id, default: []].contains(label) {
                                    choices[id]?.remove(label)
                                } else if multi(item) {
                                    choices[id, default: []].insert(label)
                                } else {
                                    choices[id] = [label]
                                    custom.removeValue(forKey: id)
                                }
                            } label: {
                                Label(label, systemImage: choices[id, default: []].contains(label) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(choices[id, default: []].contains(label) ? IslandPalette.blue : IslandPalette.ink)
                            }.buttonStyle(.plain)
                        }
                        if permitsText(item) {
                            TextField("自定义回答", text: Binding(
                                get: { custom[id, default: ""] },
                                set: { value in
                                    custom[id] = String(value.prefix(1000))
                                    if !multi(item) && !value.isEmpty { choices.removeValue(forKey: id) }
                                }
                            ), prompt: Text("自定义回答").foregroundStyle(IslandPalette.muted))
                            .textFieldStyle(.plain)
                            .foregroundStyle(IslandPalette.ink)
                            .font(.system(size: 11.5))
                            .padding(8)
                            .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(IslandPalette.line) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let feedback = model.feedback[approval.id] {
                    Text(feedback).font(.system(size: 10)).foregroundStyle(IslandPalette.muted)
                }
                Spacer()
                Button("提交回答") {
                    let answers: [[String: Any]] = questions.map { item in
                        let id = questionID(item)
                        let text = custom[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                        var answer: [String: Any] = ["id": id, "selected": choices[id, default: []].sorted()]
                        if !text.isEmpty { answer["custom"] = text }
                        return answer
                    }
                    model.answerQuestion(approval.id, answers: answers)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.25, green: 0.38, blue: 0.57))
                .disabled(!ready || model.submitting.contains(approval.id))
            }
        }
    }
}

/// 收起态的按下反馈：轻微缩放 + 提亮，替代原来毫无反馈的点击。
struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}


// MARK: - 动态 DeepSeek 标记

/// 三条流动曲线组成的鲸形标记：用 `trim` 让高光沿线条游走，
/// 整枚标记再做极缓慢的上下浮动，模拟「呼吸 + 跳动」。
struct DeepSeekMark: View {
    var animating: Bool
    var size: CGFloat = 17
    var pulse: Int = 0
    var completed = false
    @State private var phase: CGFloat = 0
    @State private var bob: CGFloat = 0
    @State private var scale: CGFloat = 1

    private var flow: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.33, green: 0.60, blue: 0.98),
                     Color(red: 0.58, green: 0.93, blue: 1.00),
                     Color(red: 0.33, green: 0.60, blue: 0.98)],
            startPoint: .leading, endPoint: .trailing
        )
    }
    private var style: StrokeStyle {
        StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                // 底纹：常驻但很淡，保证静止时也是一枚完整标记
                let base = Color(red: 0.48, green: 0.75, blue: 1.0).opacity(animating ? 0.38 : 0.24)
                WhaleFlowLine(index: i)
                    .stroke(completed ? islandGreen : base, style: style)
                if !completed {
                    WhaleFlowLine(index: i)
                        .trim(from: phase, to: min(1, phase + 0.42))
                        .stroke(flow, style: style)
                        .blendMode(.plusLighter)
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .offset(y: bob)
        .accessibilityLabel(completed ? "任务已完成" : animating ? "任务运行中" : "空闲")
        .onAppear { startIfNeeded() }
        .onChange(of: animating) { on in
            if on { startIfNeeded() } else {
                withAnimation(.easeOut(duration: 0.25)) { phase = 0; bob = 0 }
            }
        }
        .onChange(of: pulse) { _ in
            // 状态变化时轻轻弹一下
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { scale = 1.18 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { scale = 1 }
            }
        }
    }

    private func startIfNeeded() {
        guard animating else { return }
        withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { phase = 1 }
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { bob = -size * 0.08 }
    }
}

/// 单条曲线：轻微错位叠加，合起来像鲸身的流线。
struct WhaleFlowLine: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        switch index {
        case 0:
            p.move(to: CGPoint(x: w * 0.10, y: h * 0.66))
            p.addCurve(to: CGPoint(x: w * 0.90, y: h * 0.60),
                       control1: CGPoint(x: w * 0.34, y: h * 0.18),
                       control2: CGPoint(x: w * 0.62, y: h * 1.02))
        case 1:
            p.move(to: CGPoint(x: w * 0.06, y: h * 0.50))
            p.addCurve(to: CGPoint(x: w * 0.86, y: h * 0.44),
                       control1: CGPoint(x: w * 0.32, y: h * 0.02),
                       control2: CGPoint(x: w * 0.58, y: h * 0.86))
        default:
            p.move(to: CGPoint(x: w * 0.16, y: h * 0.82))
            p.addCurve(to: CGPoint(x: w * 0.94, y: h * 0.76),
                       control1: CGPoint(x: w * 0.38, y: h * 0.36),
                       control2: CGPoint(x: w * 0.66, y: h * 1.18))
        }
        return p
    }
}

/// 右侧的声波柱：三条不同相位的竖条，运行时跳动，静止时收敛成弱化刻度。
struct WaveformBars: View {
    var active: Bool
    var tint: Color = Color(red: 0.55, green: 0.90, blue: 0.98)
    @State private var hi = false
    private let heights: [CGFloat] = [0.45, 1.0, 0.68]

    var body: some View {
        HStack(alignment: .center, spacing: 1.8) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(active ? tint : Color.white.opacity(0.32))
                    .frame(width: 1.9, height: max(3, 11 * heights[i] * (hi ? 1 : 0.5)))
                    .animation(.easeInOut(duration: 0.42 + Double(i) * 0.13)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.07),
                               value: hi)
            }
        }
        .frame(width: 13, height: 12)
        .onAppear { hi = active }
        .onChange(of: active) { on in hi = on }
    }
}

/// 空闲时贴着底边的一条呼吸细线：不打扰，但一眼能看出这里有个可交互的岛。
struct IdleUnderline: View {
    let width: CGFloat
    @State private var on = false
    var body: some View {
        Capsule()
            .fill(Color(red: 0.45, green: 0.72, blue: 0.98))
            .frame(width: max(28, width * 0.42), height: 2)
            .padding(.bottom, 3)
            .opacity(on ? 0.55 : 0.22)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 空闲时的呼吸点：像设备待机指示灯，告诉用户「岛在这儿，随时可用」。
struct IdleBreathingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.white.opacity(on ? 0.55 : 0.18))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color.white.opacity(on ? 0.20 : 0.05), lineWidth: 3).blur(radius: 1))
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 状态点：运行中是柔和的呼吸绿，待审批是暖橙并带一圈光晕。
@ViewBuilder
func statusDot(pending: Bool) -> some View {
    let color = pending ? islandOrange : islandGreen
    Circle()
        .fill(color)
        .frame(width: 7, height: 7)
        .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 3).blur(radius: 1.2))
        .shadow(color: color.opacity(0.55), radius: 3.5, y: 0)
}

struct NotchIslandView: View {
    @ObservedObject var model: IslandModel
    let onOpen: (String) -> Void
    let onDecision: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            IslandPresentation(model: model, canvas: proxy.size, onOpen: onOpen, onDecision: onDecision,
                               progress: model.mode == .expanded ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.46), value: model.mode)
        }
    }
}

struct IslandPresentation: View, Animatable {
    @ObservedObject var model: IslandModel
    let canvas: CGSize
    let onOpen: (String) -> Void
    let onDecision: (String, String) -> Void
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let metrics = model.metrics
        let growth = min(1, max(0, progress))
        let availableHeight = canvas.height
        let compact = islandShapeSize(model: model, metrics: metrics, expanded: false,
                                      maxHeight: availableHeight, availableWidth: canvas.width - 24)
        let expanded = islandShapeSize(model: model, metrics: metrics, expanded: true,
                                       maxHeight: availableHeight, availableWidth: canvas.width - 24)
        let size = CGSize(width: compact.width + (expanded.width - compact.width) * growth,
                          height: compact.height + (expanded.height - compact.height) * growth)
        let topRadius = 6 + 13 * growth
        let bottomRadius = 14 + 10 * growth
        let headerHeight = min(metrics.notchHeight, size.height)
        let contentWidth = metrics.hasNotch ? max(0, expanded.width - 38) : expanded.width
        let shift = islandHorizontalOffset(model: model, metrics: metrics, expanded: false) * (1 - growth)

        ZStack(alignment: .top) {
            backdrop(expanded: growth > 0, metrics: metrics, size: size,
                     topRadius: topRadius, bottomRadius: bottomRadius)
            VStack(spacing: 0) {
                header(growth: growth, metrics: metrics, size: size)
                    .frame(width: size.width, height: headerHeight)
                if growth > 0.30 {
                    IslandConsoleView(model: model, width: contentWidth, height: max(0, expanded.height - headerHeight),
                                      onOpen: onOpen, onDecision: onDecision)
                    .environment(\.colorScheme, .dark)
                    .opacity(min(1, (growth - 0.30) / 0.62))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .mask(
                Group {
                    if metrics.hasNotch {
                        NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                    } else {
                        RoundedRectangle(cornerRadius: bottomRadius, style: .continuous)
                    }
                }
                .frame(width: size.width, height: size.height)
            )
        }
        .offset(x: shift)
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
    }

    // MARK: - 背景

    @ViewBuilder
    func backdrop(expanded: Bool, metrics: IslandMetrics, size: CGSize,
                  topRadius: CGFloat, bottomRadius: CGFloat) -> some View {
        if metrics.hasNotch {
            NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                .fill(LinearGradient(colors: [Color(white: 0.035), Color(white: 0.075)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size.width, height: size.height)
                // 顶部一条 1pt 黑条：盖住刘海与形状之间的那条缝
                .overlay(alignment: .top) {
                    Rectangle().fill(.black).frame(height: 1)
                        .padding(.horizontal, topRadius)
                }
                // 空闲时给一道极淡描边，让「岛在那里」这件事在黑刘海边上也能被看见
                .overlay(
                    NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                        .stroke(Color.white.opacity(model.hasContent ? 0.10 : 0.16), lineWidth: 0.6)
                        .frame(width: size.width, height: size.height)
                )
                .overlay(alignment: .bottom) {
                    if !expanded && !model.hasContent {
                        IdleUnderline(width: size.width)
                    }
                }
                .shadow(color: expanded ? Color.black.opacity(0.65) : .clear,
                        radius: 6, y: 2)
        } else {
            let shape = RoundedRectangle(cornerRadius: bottomRadius, style: .continuous)
            shape.fill(Color.black.opacity(model.hasContent || expanded ? 0.93 : 0.62))
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.black.opacity(0.40), radius: 8, y: 3)
        }
    }

    // MARK: - 顶部一行（收起态的全部内容）

    @ViewBuilder
    func header(growth: CGFloat, metrics: IslandMetrics, size: CGSize) -> some View {
        if metrics.hasNotch {
            HStack(spacing: 6) {
                if model.hasContent || idlePresence {
                    wingContent
                    if !model.unreadDeliveries.isEmpty {
                        Circle().fill(Color(red: 0.94, green: 0.31, blue: 0.33))
                            .frame(width: 5, height: 5).accessibilityLabel("有新交付")
                    }
                }
                Spacer(minLength: 0)
                if growth < 0.5 {
                    trailingContent
                }
            }
            .padding(.leading, 10 + 23 * growth)
            .padding(.trailing, 12)
            .frame(width: size.width, height: metrics.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { if model.mode == .compact { model.toggleMode() } }
        } else {
            Button { model.toggleMode() } label: {
                HStack(spacing: 6) {
                    wingContent
                    if !model.unreadDeliveries.isEmpty {
                        Circle().fill(Color(red: 0.94, green: 0.31, blue: 0.33))
                            .frame(width: 5, height: 5).accessibilityLabel("有新交付")
                    }
                }
                .frame(width: size.width, height: min(metrics.notchHeight, size.height))
                .contentShape(Capsule())
            }
            .buttonStyle(IslandPressStyle())
        }
    }

    /// 右翼：运行中给声波 + 计数，待审批给橙色计数，完成给对勾。
    @ViewBuilder
    var trailingContent: some View {
        switch model.status {
        case .running:
            HStack(spacing: 5) {
                WaveformBars(active: true)
                Text("\(model.runningCount)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.92))
            }
        case .approval:
            HStack(spacing: 5) {
                WaveformBars(active: true, tint: islandOrange)
                Text("\(model.approvals.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(islandOrange)
            }
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(islandGreen)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    var wingContent: some View {
        switch model.status {
        case .approval:
            statusDot(pending: true)
        case .running:
            DeepSeekMark(animating: true, size: 17, pulse: model.runningCount)
        case .completed:
            DeepSeekMark(animating: false, size: 17, completed: true)
        case .idle:
            if idlePresence {
                DeepSeekMark(animating: false, size: 17)
            }
        }
    }


}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandController {
    let panel: IslandPanel
    let model: IslandModel
    let hosting: NSHostingView<NotchIslandView>
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var hideWork: DispatchWorkItem?
    private var completionWork: [String: DispatchWorkItem] = [:]

    init(model: IslandModel, onOpen: @escaping (String) -> Void, onDecision: @escaping (String, String) -> Void) {
        self.model = model
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 432, height: IslandLayout.maxHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        let root = NotchIslandView(model: model, onOpen: { sessionId in
            onOpen(sessionId)
            model.dismiss()
        }, onDecision: onDecision)
        hosting = NSHostingView(rootView: root)
        panel.contentView = hosting

        // Install after initialization. Capturing the old global controller here
        // captured nil forever, so clicks changed SwiftUI but never window state.
        model.onModeChange = { [weak self] in
            self?.relayout()
            if self?.model.mode == .compact, self?.panel.isKeyWindow == true {
                self?.panel.resignKey()
            }
            if CommandLine.arguments.contains("--demo"), let self = self {
                emitJson(["type": "demo-mode", "mode": self.model.mode.rawValue, "frame": NSStringFromRect(self.islandFrame)])
            }
        }
        if !isTestProtocol {
            installEventMonitors()
            startAnchorTimer()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.relayout() }
        }
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        hideWork?.cancel()
        for work in completionWork.values { work.cancel() }
    }

    var mouseMonitorCount: Int { monitors.count }

    /// 与 relayout 相同的"该不该显示"判定。测试模式下真实面板保持不可见，
    /// 但这条意图仍可断言——避免为了消掉测试弹窗，顺手把可见性路径的覆盖也砍掉。
    private(set) var intendedVisible = false

    var islandFrame: CGRect {
        let expanded = model.mode == .expanded
        let size = islandShapeSize(model: model, metrics: model.metrics, expanded: expanded,
                                   maxHeight: panel.frame.height, availableWidth: panel.frame.width - 24)
        let shift = islandHorizontalOffset(model: model, metrics: model.metrics, expanded: expanded)
        return CGRect(x: panel.frame.midX - size.width / 2 + shift, y: panel.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    func containsMouse(_ point: CGPoint) -> Bool {
        panel.isVisible && islandContains(point, frame: islandFrame, radius: model.mode == .expanded ? 16 : 12)
    }

    func syncMousePassthrough() {
        // The animation canvas is larger than the island. Its transparent area
        // must pass clicks through to the original app, including the first click.
        panel.ignoresMouseEvents = !containsMouse(NSEvent.mouseLocation)
    }

    /// 面板锚定的屏幕：有任务时锁定在任务开始那一刻鼠标所在的屏，
    /// 空闲时释放，避免鼠标跨屏移动时整颗岛来回跳。
    private var pinnedScreen: NSScreen?

    func currentScreen() -> NSScreen? {
        if let pinned = pinnedScreen, NSScreen.screens.contains(where: { $0 === pinned }) { return pinned }
        return islandScreen()
    }

    /// 宿主只在状态变化时推送，空闲时可能很久没有 update。
    /// 所以由 helper 自己盯着鼠标在哪块屏，收起态就静默搬过去。
    private var anchorTimer: Timer?

    private func startAnchorTimer() {
        anchorTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self = self, !isTestProtocol else { return }
            guard self.model.mode == .compact else { return }
            let target = islandScreen()
            if let current = self.pinnedScreen, let next = target, current !== next {
                self.pinnedScreen = next
                self.relayout()
            } else if self.pinnedScreen == nil {
                self.pinnedScreen = target
                self.relayout()
            }
        }
        timer.tolerance = 0.4
        anchorTimer = timer
    }

    /// 悬停展开 / 离开收起：带一点「意图延迟」，
    /// 扫过胶囊不会误展开，离开后也给回移的余地。
    private var hoverWork: DispatchWorkItem?

    private func scheduleHover(expand: Bool) {
        guard !isTestProtocol else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let inside = self.containsMouse(NSEvent.mouseLocation)
            if expand, inside, self.model.mode == .compact, self.model.hasContent {
                self.model.toggleMode()
                self.syncMousePassthrough()
            } else if !expand, !inside, self.model.mode == .expanded {
                guard Date() >= self.model.notificationVisibleUntil else { return }
                self.model.dismiss()
                self.syncMousePassthrough()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (expand ? 0.18 : 0.42), execute: work)
    }

    private func installEventMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks.union(moves), handler: { [weak self] event in
            guard let self = self else { return }
            if CommandLine.arguments.contains("--demo") && clicks.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)) {
                emitJson(["type": "demo-click", "point": NSStringFromPoint(NSEvent.mouseLocation), "frame": NSStringFromRect(self.islandFrame), "mode": self.model.mode.rawValue])
            }
            if clicks.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)),
               !self.containsMouse(NSEvent.mouseLocation) {
                self.hoverWork?.cancel()
                self.model.dismiss()
            } else {
                // 鼠标移动：靠近胶囊就展开，离开展开体就收起
                if self.model.mode == .compact, self.containsMouse(NSEvent.mouseLocation) {
                    self.scheduleHover(expand: true)
                } else if self.model.mode == .expanded, !self.containsMouse(NSEvent.mouseLocation) {
                    self.scheduleHover(expand: false)
                }
            }
            self.syncMousePassthrough()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(moves), handler: { [weak self] event in
            guard let self = self else { return event }
            let point = NSEvent.mouseLocation
            let isClick = clicks.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
            if isClick {
                if !self.containsMouse(point) {
                    self.model.dismiss()
                } else if event.window === self.panel && event.type == .leftMouseDown {
                    // Window coordinates start at the bottom; screen maxY is the top.
                    let inHeader = point.y >= self.islandFrame.maxY - self.model.metrics.notchHeight
                    if self.model.mode == .compact || inHeader {
                        self.model.toggleMode()
                        self.syncMousePassthrough()
                        return nil
                    }
                }
            }
            self.syncMousePassthrough()
            return event
        }) { monitors.append(monitor) }
    }

    func applyUpdate(_ payload: [String: Any]) {
        var rows: [IslandSession] = []
        for item in payload["sessions"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String else { continue }
            var pending: IslandPending? = nil
            if let pd = item["pending"] as? [String: Any] {
                pending = IslandPending(
                    requestId: (pd["requestId"] as? String) ?? "",
                    kind: (pd["kind"] as? String) ?? "permission",
                    toolName: (pd["toolName"] as? String) ?? "",
                    reason: stripEscalationPrefix((pd["reason"] as? String) ?? ""),
                    displayReason: (pd["displayReason"] as? String) ?? "",
                    questions: (pd["questions"] as? [[String: Any]]) ?? []
                )
            }
            rows.append(IslandSession(id: id, title: (item["title"] as? String) ?? "",
                                      running: (item["running"] as? Bool) ?? true, pending: pending))
        }
        model.sessions = rows
        if rows.isEmpty {
            pinnedScreen = nil
        } else if model.mode == .compact {
            // 收起态跟随鼠标所在屏：换屏工作时不用等下一轮任务才搬过去。
            pinnedScreen = islandScreen()
        } else if pinnedScreen == nil {
            pinnedScreen = islandScreen()
        }
        let activeIDs = Set(rows.map { $0.id })
        model.completedFlash.removeAll { activeIDs.contains($0.id) }
        for item in payload["completed"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, !activeIDs.contains(id) else { continue }
            model.completedFlash.removeAll { $0.id == id }
            model.completedFlash.append(IslandSession(id: id, title: item["title"] as? String ?? "", running: false, pending: nil))
            completionWork[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.model.completedFlash.removeAll { $0.id == id }
                self.completionWork.removeValue(forKey: id)
                self.model.autoExpandIfNeeded()
                self.relayout()
            }
            completionWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        model.autoExpandIfNeeded()
        for item in payload["completed"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, !activeIDs.contains(id) else { continue }
            let delivery = model.recent.first(where: { $0.id == id }) ??
                IslandSession(id: id, title: item["title"] as? String ?? "", running: false, pending: nil)
            model.receiveDelivery(delivery)
        }
        relayout()
    }

    func relayout() {
        let screen = currentScreen()
        let metrics = islandMetrics(on: screen)
        if model.metrics != metrics { model.metrics = metrics }
        // Protocol tests may run without a WindowServer screen. Keep their
        // geometry deterministic while production still waits for a real screen.
        let frame = screen?.frame ?? (isTestProtocol ? NSRect(x: 0, y: 0, width: 1440, height: 900) : .zero)
        guard frame.height > 0 else { return }
        let notchCenter: CGFloat
        if let screen = screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchCenter = (left.maxX + right.minX) / 2
        } else {
            notchCenter = frame.midX
        }
        let panelW: CGFloat = min(frame.width - 24, max(IslandLayout.taskMaxWidth + 40, notchWidth(of: screen) + 76))
        let panelH = min(IslandLayout.maxHeight, frame.height - 60)
        // 调试用：DSH_ISLAND_OFFSET_Y 把面板整体下移，方便与常驻实例并排观察
        let debugOffset = ProcessInfo.processInfo.environment["DSH_ISLAND_OFFSET_Y"].flatMap(Double.init) ?? 0
        let target = NSRect(x: notchCenter - panelW / 2, y: frame.maxY - panelH - debugOffset,
                            width: panelW, height: panelH)
        if panel.frame != target { panel.setFrame(target, display: true) }
        hideWork?.cancel()
        let shouldShow = !model.sessions.isEmpty || !model.completedFlash.isEmpty || idlePresence
        intendedVisible = shouldShow
        // Exercise the actual model and panel geometry without putting fixture
        // tasks over a user's running island or installing mouse monitors.
        if isTestProtocol {
            panel.orderOut(nil)
            panel.ignoresMouseEvents = true
            return
        }
        if shouldShow {
            panel.orderFrontRegardless()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.model.sessions.isEmpty && self.model.completedFlash.isEmpty && !idlePresence { self.panel.orderOut(nil) }
                self.syncMousePassthrough()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        syncMousePassthrough()
    }
}

var controller: IslandController?

func emitJson(_ payload: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
    }
}

func applyUpdate(_ payload: [String: Any]) {
    controller?.applyUpdate(payload)
}

func pushDemo(_ withPending: Bool, _ completed: [[String: Any]]?) {
    var row2: [String: Any] = ["id": "demo-2", "title": "SILAS 数据同步", "running": true]
    if withPending {
        row2["pending"] = ["requestId": "demo-req-1", "kind": "permission", "toolName": "bash",
                            "reason": "演示审批：验证刘海生长动画与岛上裁决"]
    }
    var payload: [String: Any] = ["type": "update", "sessions": [
        ["id": "demo-1", "title": "灵动岛演示 · 长任务运行中", "running": true],
        row2
    ]]
    if let c = completed { payload["completed"] = c }
    applyUpdate(payload)
}

let app = NSApplication.shared
app.setActivationPolicy(isTestProtocol ? .prohibited : .accessory)

var demoMode = CommandLine.arguments.contains("--demo")
let sink: ([String: Any]) -> Void = { payload in
    emitJson(payload)
    if demoMode, (payload["type"] as? String) == "decision" {
        pushDemo(false, nil)   // 演示：裁决后收回常驻
    }
}
let islandModel = IslandModel(eventSink: sink)
controller = IslandController(
    model: islandModel,
    onOpen: { sessionId in emitJson(["type": "open", "sessionId": sessionId]) },
    onDecision: { requestId, outcome in sink(["type": "decision", "requestId": requestId, "outcome": outcome]) }
)

if CommandLine.arguments.contains("--demo-empty") {
    // 仅用于本地视觉回归：空列表的展开态
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        applyUpdate(["type": "update", "sessions": []])
        islandModel.toggleMode()
    }
}
if demoMode {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        pushDemo(true, nil)
        FileHandle.standardError.write("[island] demo: expanded with approval\n".data(using: .utf8)!)
    }
}

emitJson(["type": "ready"])
let stdinQueue = DispatchQueue(label: "island-stdin")
if !demoMode { stdinQueue.async {
    let stdin = FileHandle.standardInput
    var buffer = Data()
    while true {
        let chunk = stdin.availableData   // 阻塞式读取（read(upToCount:) 在 stdin 上不阻塞，会静默退出）
        if chunk.isEmpty {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            break
        }
        if buffer.count + chunk.count > 1_500_000 {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            break
        }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: UInt8(10)) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let t = obj["type"] as? String
            if t == "update" {
                DispatchQueue.main.async { applyUpdate(obj) }
            } else if t == "recent" {
                DispatchQueue.main.async {
                    islandModel.recentState = obj["state"] as? String ?? "ready"
                    islandModel.recent = (obj["sessions"] as? [[String: Any]] ?? []).compactMap { item in
                        guard let id = item["id"] as? String else { return nil }
                        let messages = IslandMessage.decode(item["messages"])
                        return IslandSession(id: id, title: item["title"] as? String ?? "", running: item["running"] as? Bool ?? false,
                                             pending: nil, messages: Array(messages.suffix(2)), tokens: item["tokens"] as? Int,
                                             remaining: item["remaining"] as? Int,
                                             lastActivity: (item["lastActivityAt"] as? Double).flatMap { millis in
                                                 millis.isFinite && millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : nil
                                             })
                    }
                }
            } else if t == "history-result" {
                if let id = obj["sessionId"] as? String, let request = obj["requestId"] as? String {
                    DispatchQueue.main.async { islandModel.receiveHistory(id, requestID: request, page: obj["page"] as? [String: Any]) }
                }
            } else if t == "reply-result" {
                if let id = obj["sessionId"] as? String, let request = obj["requestId"] as? String {
                    DispatchQueue.main.async {
                        islandModel.finishReply(sessionID: id, requestID: request, ok: obj["ok"] as? Bool ?? false)
                    }
                }
            } else if t == "shutdown" {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            } else if t == "inspect", CommandLine.arguments.contains("--test-protocol") {
                DispatchQueue.main.async {
                    guard let controller = controller else { return }
                    let model = controller.model
                    emitJson(["type": "inspection", "mode": model.mode.rawValue,
                              "width": controller.islandFrame.width, "height": controller.islandFrame.height,
                              "maxX": controller.islandFrame.maxX, "maxY": controller.islandFrame.maxY,
                              "approvalIds": model.approvals.map { $0.id },
                              "selectedRequestId": model.activeApproval?.id ?? "",
                              "visibleTaskIds": model.visibleTasks.map { $0.id },
                              "consoleIds": model.consoleRows.map { $0.id },
                              "selectedConsoleId": model.selectedSession?.id ?? "",
                              "previewCount": model.selectedSession?.messages.count ?? 0,
                              "showingConversation": model.showingConversation,
                              "unreadIds": model.unreadDeliveries.map { $0.id },
                              "historyCount": model.selectedSession.flatMap { model.histories[$0.id]?.messages.count } ?? 0,
                              "visibleCompletionIds": model.visibleCompletions.map { $0.id },
                              "runningCount": model.runningCount,
                              "status": model.status.rawValue,
                              "windowNumber": controller.panel.windowNumber,
                              "panelCount": NSApp.windows.filter { $0 is IslandPanel }.count,
                              "panelVisible": controller.panel.isVisible,
                              "intentVisible": controller.intendedVisible,
                              "mouseMonitorCount": controller.mouseMonitorCount,
                              "body": model.activeApproval.map { approvalText($0.pending) } ?? ""])
                }
            } else if t == "test-next-approval", CommandLine.arguments.contains("--test-protocol") {
                DispatchQueue.main.async { controller?.model.selectApproval(offset: 1) }
            } else if t == "toggle" {
                DispatchQueue.main.async { controller?.model.toggleMode() }
            }
        }
    }
} }

app.run()
