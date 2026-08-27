import SwiftUI

struct MobileCallsView: View {
    @EnvironmentObject private var callKit: CallKitCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    capabilityCard(
                        title: "UFI103S",
                        subtitle: "Debian + VoHive",
                        support: .unsupported("该硬件没有已验证的双向语音音频链路"),
                        symbol: "simcard.2"
                    )
                    capabilityCard(
                        title: "大疆 QDC507",
                        subtitle: "VoLTE 模块",
                        support: .needsMacRelay("iPhone/iPad 不能直接访问模块 USB AT 与 USB 音频；需要 Mac WiSiM 完成模块初始化、信令和实时音频中继"),
                        symbol: "antenna.radiowaves.left.and.right"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Label("CallKit 已就绪", systemImage: "phone.connection.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("系统来电界面、接听、挂断和拨号动作已接入 WiSiM 的通话层。它只负责 iOS 系统界面；大疆模块仍需 Mac 中继提供真实信令与双向音频后，拨号入口才会启用。")
                            .foregroundStyle(.secondary)
                        if let error = callKit.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                    .mobileCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("当前状态").font(.headline)
                        LabeledContent("UFI103S", value: "不支持通话")
                        LabeledContent("大疆 QDC507", value: "等待 Mac 中继")
                        Text("在真实音频链路通过验收以前，WiSiM 不会把设备显示成可通话，也不会提交虚假的拨号操作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .mobileCard()
                }
                .padding()
            }
            .navigationTitle("通话")
        }
    }

    private func capabilityCard(
        title: String,
        subtitle: String,
        support: VoiceSupport,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(support.title).font(.subheadline.bold()).foregroundStyle(.orange)
            }
            Text(support.detail).font(.callout).foregroundStyle(.secondary)
        }
        .mobileCard()
    }
}
