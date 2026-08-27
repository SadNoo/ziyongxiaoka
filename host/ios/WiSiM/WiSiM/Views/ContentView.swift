import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: MobileAppState

    var body: some View {
        Group {
            switch state.phase {
            case .idle, .discovering:
                ProgressView("正在查找 WiSiM 设备…")
            case .loginRequired:
                LoginView()
            case .connected:
                MainTabView()
            case let .failed(message):
                ConnectView(message: message)
            }
        }
        .overlay(alignment: .top) {
            if let notice = state.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.notice)
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("设备", systemImage: "simcard.2") }
            SMSView()
                .tabItem { Label("短信", systemImage: "message.fill") }
            MobileCallsView()
                .tabItem { Label("通话", systemImage: "phone.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var endpoint = "192.168.4.1"
    let message: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 42))
                        .foregroundStyle(.orange)
                    Text("未找到可直接管理的设备")
                        .font(.title2.bold())
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        ForEach(state.managedHardware) { hardware in
                            managedHardwareRow(hardware)
                        }
                    }
                    .frame(maxWidth: 560)

                    Button("重新查找") { Task { await state.discover() } }
                        .buttonStyle(.borderedProminent)

                    VStack(spacing: 10) {
                        TextField("UFI 管理地址", text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("连接此地址") { Task { await state.connect(to: endpoint) } }
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("WiSiM")
        }
    }

    private func managedHardwareRow(_ hardware: ManagedHardwareStatus) -> some View {
        HStack(spacing: 14) {
            Image(systemName: hardware.kind.symbol)
                .font(.title2)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(hardware.kind.title).font(.headline)
                Text(hardware.availability.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(hardware.availability.title)
                .font(.caption.bold())
                .foregroundStyle(statusColor(hardware.availability))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusColor(_ availability: ManagedHardwareAvailability) -> Color {
        switch availability {
        case .connected: return .green
        case .notConnected: return .secondary
        case .macRelayRequired: return .orange
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var username = "user"
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("登录设备") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    Button(state.isBusy ? "登录中…" : "登录") {
                        Task { _ = await state.login(username: username, password: password) }
                    }
                    .disabled(state.isBusy || username.isEmpty || password.isEmpty)
                }
                if let error = state.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text("凭据仅保留在本次 App 运行的内存中，退出后需要重新登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("WiSiM")
        }
    }
}
