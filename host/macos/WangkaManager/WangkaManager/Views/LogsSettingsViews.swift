import AppKit
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""

    private var filtered: [LogEntry] {
        let entries: [LogEntry]
        if search.isEmpty {
            entries = state.logs
        } else {
            entries = state.logs.filter {
                "\($0.level) \($0.caller) \($0.message) \($0.fields ?? "")"
                    .localizedCaseInsensitiveContains(search)
            }
        }
        return entries.sorted {
            if $0.time == $1.time { return $0.id > $1.id }
            return $0.time > $1.time
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志").font(.largeTitle.bold())
                Spacer()
                TextField("搜索", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 280)
                Button { Task { await state.refreshLogs() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .padding(20)
            Divider()
            if filtered.isEmpty {
                EmptyStateView(title: "暂无日志", symbol: "doc.text", description: "点击刷新读取最近的设备日志。")
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.level.uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(levelColor(entry.level))
                            Text(entry.time).font(.caption).foregroundStyle(.secondary)
                            Text(entry.caller).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(entry.message).textSelection(.enabled)
                        if let fields = entry.fields, !fields.isEmpty {
                            Text(fields)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .task { if state.logs.isEmpty { await state.refreshLogs() } }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error", "fatal": return .red
        case "warn", "warning": return .orange
        case "debug": return .secondary
        default: return .blue
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingAccessChange = false
    @State private var pendingUplinkMode: UplinkMode?
    @State private var showingWiFiConfiguration = false
    @State private var showingNotificationSettings = false

    private var currentUplinkMode: UplinkMode? {
        guard let value = state.appliance?.uplinkMode else { return nil }
        return UplinkMode(rawValue: value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("设置").font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("管理登录保护").font(.title2.bold())
                            Text(state.authenticationRequired
                                 ? "已开启：网页和 Mac App 都需要登录。"
                                 : "已关闭：连接设备 Wi-Fi 或 USB 后可以直接管理。")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(state.authenticationRequired ? "已开启" : "已关闭")
                            .foregroundStyle(state.authenticationRequired ? .green : .orange)
                        Button(state.authenticationRequired ? "关闭" : "开启") {
                            confirmingAccessChange = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy)
                    }
                }
                .cardStyle()

                networkDirectionCard
                wifiCard
                ledCard
                notificationCard

                VStack(alignment: .leading, spacing: 14) {
                    Text("连接").font(.title2.bold())
                    LabeledContent("当前地址", value: state.endpoint?.absoluteString ?? "—")
                    LabeledContent(
                        "管理方式",
                        value: state.authenticationRequired ? "登录保护" : "免登录管理（设备网络）"
                    )
                    HStack {
                        Button("打开网页管理") {
                            if let endpoint = state.endpoint { NSWorkspace.shared.open(endpoint) }
                        }
                        Button("断开设备", role: .destructive) { state.disconnect() }
                    }
                }
                .cardStyle()
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .sheet(isPresented: $showingWiFiConfiguration) {
            WiFiConfigurationView().environmentObject(state)
        }
        .sheet(isPresented: $showingNotificationSettings) {
            NotificationSettingsEditor().environmentObject(state)
        }
        .confirmationDialog(
            state.authenticationRequired ? "关闭管理登录保护？" : "开启管理登录保护？",
            isPresented: $confirmingAccessChange,
            titleVisibility: .visible
        ) {
            Button(state.authenticationRequired ? "确认关闭" : "确认开启") {
                Task { await state.setLoginProtection(enabled: !state.authenticationRequired) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if state.authenticationRequired {
                Text("关闭后，连接设备 Wi-Fi 或 USB 的人可以直接访问管理页面。")
            } else {
                Text("开启后会立即清除本次登录状态，并要求重新登录。")
            }
        }
        .confirmationDialog(
            "切换网络方向",
            isPresented: Binding(
                get: { pendingUplinkMode != nil },
                set: { if !$0 { pendingUplinkMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let mode = pendingUplinkMode {
                Button("切换到\(mode.title)") {
                    pendingUplinkMode = nil
                    Task { await state.switchUplinkMode(mode) }
                }
            }
            Button("取消", role: .cancel) { pendingUplinkMode = nil }
        } message: {
            Text(pendingUplinkMode?.detail ?? "")
        }
        .task {
            if state.notificationSettings == nil {
                await state.loadNotificationSettings(reportErrors: false)
            }
        }
    }

    private var networkDirectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("网络方向").font(.title2.bold())
                Text("选择由 SIM 为外部设备提供网络，或通过 USB 使用 Mac 的网络。")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(UplinkMode.allCases) { mode in
                    Button {
                        if currentUplinkMode != mode { pendingUplinkMode = mode }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: mode == .deviceUplink ? "antenna.radiowaves.left.and.right" : "laptopcomputer.and.arrow.down")
                                Text(mode.title).font(.headline)
                            }
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                        .padding(14)
                        .background(currentUplinkMode == mode ? Color.indigo.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(currentUplinkMode == mode ? Color.indigo : Color.secondary.opacity(0.2))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isBusy || currentUplinkMode == nil)
                }
            }
        }
        .cardStyle()
    }

    private var wifiCard: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wi-Fi").font(.title2.bold())
                Text(state.appliance?.wifiSSID ?? "正在读取当前热点…")
                    .foregroundStyle(.secondary)
                Text("修改名称或密码后热点会短暂重启；通过 Wi-Fi 管理时需要重新连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("修改 Wi-Fi") { showingWiFiConfiguration = true }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || state.appliance?.wifiSSID.isEmpty != false)
        }
        .cardStyle()
    }

    private var notificationCard: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("网页通知集成").font(.title2.bold())
                Text(notificationSummary)
                    .foregroundStyle(.secondary)
                Text("统一管理 Telegram、飞书、QQ、邮件、PushPlus、Webhook 与 Bark。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isNotificationLoading {
                ProgressView().controlSize(.small)
            }
            Button("管理通知集成") { showingNotificationSettings = true }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || state.isNotificationLoading || state.notificationSettings == nil)
        }
        .cardStyle()
    }

    private var ledCard: some View {
        let led = state.appliance?.led
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("状态灯").font(.title2.bold())
                    Text(led.map { "模式颜色：\($0.modeColorLabel) · 当前：\($0.currentAppearance)" } ?? "正在读取状态灯…")
                        .foregroundStyle(.secondary)
                    Text(led?.meaning ?? "双模式白色、网卡模式绿色、短信模式蓝色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "开启状态灯",
                        isOn: Binding(
                            get: { state.appliance?.led?.enabled ?? true },
                            set: { enabled in
                                Task {
                                    await state.updateLED(
                                        enabled: enabled,
                                        nightMode: state.appliance?.led?.nightMode ?? false
                                    )
                                }
                            }
                        )
                    )
                    Toggle(
                        "夜间模式",
                        isOn: Binding(
                            get: { state.appliance?.led?.nightMode ?? false },
                            set: { nightMode in
                                Task {
                                    await state.updateLED(
                                        enabled: state.appliance?.led?.enabled ?? true,
                                        nightMode: nightMode
                                    )
                                }
                            }
                        )
                    )
                }
                .toggleStyle(.switch)
                .disabled(state.isBusy || led == nil)
            }
            Text("夜间模式会关闭正常运行和切换提示灯；温度、蜂窝与系统异常仍会亮灯告警。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var notificationSummary: String {
        guard let settings = state.notificationSettings else { return "正在读取网页通知设置…" }
        let enabled = [
            settings.telegram.enabled,
            settings.feishu.enabled,
            settings.qq.enabled,
            settings.email.enabled,
            settings.pushplus.enabled,
            settings.webhook.enabled,
            settings.bark.enabled
        ].filter { $0 }.count
        return enabled == 0 ? "当前未启用通知渠道" : "已启用 \(enabled) 个通知渠道"
    }
}

private struct NotificationSettingsEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NotificationSettings.empty
    @State private var initialized = false
    @State private var expandedChannels: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("网页通知集成").font(.title.bold())
                    Text("配置保存在设备的 VoHive 中")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button(state.isBusy ? "正在保存…" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    channelCard("Telegram", symbol: "paperplane.fill", enabled: $draft.telegram.enabled) {
                        SecureField("Bot Token", text: $draft.telegram.botToken)
                        TextField("Chat ID", value: $draft.telegram.chatID, format: .number)
                        TextField("管理员 ID（可选）", value: $draft.telegram.adminID, format: .number)
                        TextField("API 基础地址（可选）", text: $draft.telegram.baseURL)
                        TextField("HTTP 代理（可选）", text: $draft.telegram.proxy)
                    }

                    channelCard("飞书", symbol: "bird.fill", enabled: $draft.feishu.enabled) {
                        TextField("App ID", text: $draft.feishu.appID)
                        SecureField("App Secret", text: $draft.feishu.appSecret)
                        TextField("群聊 Chat ID，每行一个", text: listBinding(\.feishu.chatIDs), axis: .vertical)
                            .lineLimit(2...5)
                    }

                    channelCard("QQ", symbol: "person.2.fill", enabled: $draft.qq.enabled) {
                        TextField("App ID", text: $draft.qq.appID)
                        SecureField("App Secret", text: $draft.qq.appSecret)
                        TextField("群 ID", text: $draft.qq.groupIDs)
                        TextField("私聊用户 ID", text: $draft.qq.directIDs)
                    }

                    channelCard("邮件", symbol: "envelope.fill", enabled: $draft.email.enabled) {
                        Toggle("使用 SSL", isOn: $draft.email.useSSL)
                        TextField("SMTP 主机", text: $draft.email.smtpHost)
                        TextField("SMTP 端口", value: $draft.email.smtpPort, format: .number)
                        TextField("用户名", text: $draft.email.username)
                        SecureField("密码", text: $draft.email.password)
                        TextField("发件地址", text: $draft.email.fromAddress)
                        TextField("收件地址，每行一个", text: listBinding(\.email.toAddresses), axis: .vertical)
                            .lineLimit(2...5)
                    }

                    channelCard("PushPlus", symbol: "bell.badge.fill", enabled: $draft.pushplus.enabled) {
                        SecureField("Token", text: $draft.pushplus.token)
                        TextField("Topic（可选）", text: $draft.pushplus.topic)
                        TextField("Channel（可选）", text: $draft.pushplus.channel)
                    }

                    channelCard("Webhook", symbol: "link", enabled: $draft.webhook.enabled) {
                        TextField("URL，每行一个", text: listBinding(\.webhook.urls), axis: .vertical)
                            .lineLimit(2...5)
                        SecureField("签名密钥（可选）", text: $draft.webhook.secret)
                        TextField("超时（毫秒）", value: $draft.webhook.timeoutMs, format: .number)
                        TextField("重试次数", value: $draft.webhook.retryMax, format: .number)
                        TextField("文本模板（可选）", text: $draft.webhook.textTemplate, axis: .vertical)
                            .lineLimit(2...5)
                    }

                    channelCard("Bark", symbol: "app.badge.fill", enabled: $draft.bark.enabled) {
                        TextField("Bark URL，每行一个", text: listBinding(\.bark.urls), axis: .vertical)
                            .lineLimit(2...5)
                        TextField("分组（可选）", text: $draft.bark.group)
                        TextField("图标 URL（可选）", text: $draft.bark.icon)
                        TextField("提醒级别", text: $draft.bark.level)
                    }

                    if let error = state.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 760)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            state.clearMessages()
            draft = state.notificationSettings ?? .empty
        }
    }

    private func channelCard<Content: View>(
        _ title: String,
        symbol: String,
        enabled: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedChannels.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isExpanded {
                            expandedChannels.remove(title)
                        } else {
                            expandedChannels.insert(title)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .frame(width: 14)
                        Image(systemName: symbol).frame(width: 24)
                        Text(title).font(.headline)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(title)设置")

                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary) }
    }

    private func listBinding(_ keyPath: WritableKeyPath<NotificationSettings, [String]>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath].joined(separator: "\n") },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func save() {
        let submitted = draft
        Task {
            if await state.saveNotificationSettings(submitted) { dismiss() }
        }
    }
}

private struct WiFiConfigurationView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("修改 Wi-Fi").font(.title.bold())
                Spacer()
                Button("取消") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Wi-Fi 名称").font(.headline)
                TextField("1～32 字节", text: $ssid)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("新密码（8～63 字节）", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("再次输入新密码", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let error = state.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(state.isBusy ? "正在更新…" : "更新 Wi-Fi") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy || ssid.isEmpty || password.isEmpty || confirmation.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            state.clearMessages()
            ssid = state.appliance?.wifiSSID ?? ""
        }
    }

    private func submit() {
        let submittedSSID = ssid
        let submittedPassword = password
        let submittedConfirmation = confirmation
        Task {
            if await state.updateWiFi(
                ssid: submittedSSID,
                password: submittedPassword,
                confirmation: submittedConfirmation
            ) {
                password = ""
                confirmation = ""
                dismiss()
            }
        }
    }
}
