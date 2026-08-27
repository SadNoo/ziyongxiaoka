import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var endpoint = "192.168.4.1"

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    if let current = state.endpoint {
                        LabeledContent("当前地址", value: current.absoluteString)
                    }
                    TextField("UFI 管理地址", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("连接此地址") { Task { await state.connect(to: endpoint) } }
                }
                Section("自动发现") {
                    LabeledContent("UFI USB", value: "192.168.5.1")
                    LabeledContent("UFI Wi-Fi", value: "192.168.4.1")
                    LabeledContent("大疆 QDC507", value: "需要 Mac WiSiM 中继")
                    Text("iOS 不开放对 QDC507 USB AT 与 USB 音频的直接访问，因此 App 不会把无法确认的模块伪报为已连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新查找") { Task { await state.discover() } }
                }
                Section("登录保护") {
                    LabeledContent("当前状态", value: state.capabilities?.authRequired == true ? "已开启" : "已关闭")
                    Text("启用保护时，凭据只保留在本次 App 运行的内存中；WiSiM 不写入钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("通话") {
                    LabeledContent("CallKit", value: "已集成")
                    LabeledContent("UFI103S", value: "不支持")
                    LabeledContent("大疆 QDC507", value: "需要 Mac 中继")
                }
                Section("版本") {
                    LabeledContent("WiSiM iOS", value: "0.2.0")
                }
            }
            .navigationTitle("设置")
        }
    }
}
