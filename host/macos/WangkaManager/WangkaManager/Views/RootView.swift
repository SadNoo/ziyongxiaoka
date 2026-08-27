import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var dji: DJIModemService

    var body: some View {
        ZStack {
            switch state.phase {
            case .idle:
                if dji.isDetected {
                    MainShellView()
                } else if !dji.hasCompletedInitialDetection {
                    DeviceDiscoveryView()
                } else {
                    ConnectionView(message: nil)
                }
            case .discovering:
                if dji.isDetected {
                    MainShellView()
                } else {
                    DeviceDiscoveryView()
                }
            case let .failed(message):
                if dji.isDetected {
                    MainShellView()
                } else if dji.isRefreshing || !dji.hasCompletedInitialDetection {
                    DeviceDiscoveryView()
                } else {
                    ConnectionView(message: message + " 同时也没有检测到受支持的大疆 QDC507 USB 设备。")
                }
            case .loginRequired:
                LoginView()
            case .connected:
                MainShellView()
            }
        }
        .task {
            dji.start()
            if state.phase == .idle { await state.discover() }
        }
    }
}

private struct DeviceDiscoveryView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("正在查找设备…").font(.headline)
            Text("同时检查 UFI USB 192.168.5.1、Wi‑Fi 192.168.4.1 和大疆 QDC507 USB")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionView: View {
    @EnvironmentObject private var state: AppState
    let message: String?
    @State private var endpoint = "http://192.168.5.1"

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "simcard.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(.indigo)
            VStack(spacing: 7) {
                Text("查找设备").font(.largeTitle.bold())
                Text("支持 UFI Debian + VoHive 和大疆 QDC507 USB")
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack {
                TextField("管理地址", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await state.connect(to: endpoint) } }
                Button("连接") { Task { await state.connect(to: endpoint) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 520)
            Button("重新自动查找") { Task { await state.discover() } }
                .buttonStyle(.link)
        }
        .padding(50)
    }
}

private struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var username = "user"
    @State private var password = ""

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(.indigo)
            VStack(spacing: 6) {
                Text("登录设备").font(.largeTitle.bold())
                Text(state.endpoint?.absoluteString ?? "")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                if let error = state.errorMessage {
                    Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(state.isBusy ? "正在登录…" : "登录") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(state.isBusy || username.isEmpty || password.isEmpty)
            }
            .frame(width: 360)
            Button("改用其他管理地址") { state.disconnect() }
                .buttonStyle(.link)
        }
        .padding(50)
    }

    private func submit() {
        let submitted = password
        password = ""
        Task { _ = await state.login(username: username, password: submitted) }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, sms, calls, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "网卡管理"
        case .sms: return "短信"
        case .calls: return "通话"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "simcard.2.fill"
        case .sms: return "message.fill"
        case .calls: return "phone.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

private struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var dji: DJIModemService
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                        Text(connectionLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                UFIConnectionBanner()
                if state.notice != nil || state.errorMessage != nil {
                    StatusBanner()
                }
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .sms: SMSView()
                case .calls: CallsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .animation(.easeInOut(duration: 0.18), value: state.notice)
            .animation(.easeInOut(duration: 0.18), value: state.errorMessage)
        }
        .task { await state.runSMSRefreshLoop() }
        .overlay(alignment: .topTrailing) { IncomingCallBanner() }
    }

    private var connectionLabel: String {
        if let host = state.endpoint?.host { return host }
        if let snapshot = dji.snapshot { return "大疆 \(snapshot.device.model) USB 已连接" }
        return "未连接"
    }
}

private struct UFIConnectionBanner: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var dji: DJIModemService
    @State private var endpoint = "http://192.168.5.1"

    var body: some View {
        switch state.phase {
        case .connected, .loginRequired:
            EmptyView()
        case .discovering:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(dji.isDetected
                    ? "大疆 \(dji.snapshot?.device.model ?? "QDC507") 已连接；正在继续查找 UFI…"
                    : "正在同时查找 UFI 和大疆 QDC507…")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.indigo.opacity(0.08))
        case let .failed(message):
            connectionControls(message: dji.isDetected
                ? "大疆 \(dji.snapshot?.device.model ?? "QDC507") USB 已连接；UFI 管理端未连接，但不影响继续管理大疆设备。"
                : message)
        case .idle:
            connectionControls(message: dji.isDetected
                ? "大疆 \(dji.snapshot?.device.model ?? "QDC507") USB 已连接；UFI 尚未连接。"
                : "UFI 尚未连接；也可以通过 USB 连接大疆 QDC507。")
        }
    }

    private func connectionControls(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("UFI 管理地址", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .onSubmit { Task { await state.connect(to: endpoint) } }
            Button("连接") { Task { await state.connect(to: endpoint) } }
                .buttonStyle(.borderedProminent)
            Button("自动查找") { Task { await state.discover() } }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

private struct StatusBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(state.errorMessage ?? state.notice ?? "")
            Spacer()
            Button { state.clearMessages() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .foregroundStyle(state.errorMessage == nil ? .green : .red)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background((state.errorMessage == nil ? Color.green : Color.red).opacity(0.09))
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.quaternary)
            }
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
