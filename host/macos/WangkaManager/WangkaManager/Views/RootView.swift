import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            switch state.phase {
            case .idle:
                ConnectionView(message: nil)
            case .discovering:
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("正在查找无线网卡…").font(.headline)
                    Text("依次检查 USB 192.168.5.1 和 Wi‑Fi 192.168.4.1")
                        .foregroundStyle(.secondary)
                }
            case let .failed(message):
                ConnectionView(message: message)
            case .loginRequired:
                LoginView()
            case .connected:
                MainShellView()
            }
        }
        .task {
            if state.phase == .idle { await state.discover() }
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
                Text("网卡管理").font(.largeTitle.bold())
                Text("Debian + VoHive 日常管理")
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
    case overview, sms, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "网卡管理"
        case .sms: return "短信"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "simcard.2.fill"
        case .sms: return "message.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

private struct MainShellView: View {
    @EnvironmentObject private var state: AppState
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
                        Text(state.endpoint?.host ?? "未连接")
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
                if state.notice != nil || state.errorMessage != nil {
                    StatusBanner()
                }
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .sms: SMSView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .animation(.easeInOut(duration: 0.18), value: state.notice)
            .animation(.easeInOut(duration: 0.18), value: state.errorMessage)
        }
        .task { await state.runSMSRefreshLoop() }
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
