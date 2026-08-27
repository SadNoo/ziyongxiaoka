import SwiftUI

struct CallsView: View {
    @EnvironmentObject private var dji: DJIModemService
    @State private var phoneNumber = ""
    @State private var confirmInitialization = false
    @State private var confirmRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("通话").font(.largeTitle.bold())
                        Text("按设备真实能力显示，不支持的设备不会提供拨号入口。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await dji.refresh() }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .disabled(dji.isRefreshing || dji.isPerformingCallAction)
                }

                deviceCards

                if let snapshot = dji.snapshot {
                    readinessCard(snapshot)
                    initializationCard(snapshot)
                    callCard(snapshot)
                } else {
                    EmptyStateView(
                        title: "未检测到可通话设备",
                        symbol: "phone.down.fill",
                        description: dji.errorMessage ?? "请连接大疆 QDC507 后重新检测。UFI103S 本身不支持语音通话。"
                    )
                    .frame(minHeight: 260)
                    .cardStyle()
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .alert("初始化大疆模块的 ADB 与 USB 音频？", isPresented: $confirmInitialization) {
            Button("取消", role: .cancel) {}
            Button("创建备份并初始化") {
                Task { await dji.initializeADBAndUSBAudio() }
            }
        } message: {
            Text("WiSiM 会先在本机 App 数据目录创建私有备份，只启用 ADB 与 USB 音频并保留 VID/PID、其他 USB 功能位和 IMS/VoLTE。模块会重启并短暂断线。QADBKEY 授权可能持久保存，恢复 USB 配置不保证撤销该授权。")
        }
        .alert("恢复写入前 USB 配置？", isPresented: $confirmRestore) {
            Button("取消", role: .cancel) {}
            Button("恢复并重启", role: .destructive) {
                Task { await dji.restoreUSBConfiguration() }
            }
        } message: {
            Text("仅恢复由 WiSiM 为同一模块保存的 USB 配置。恢复前还会创建一份保护备份；IMS/VoLTE 不会被覆盖。模块会重启并短暂断线。")
        }
    }

    private var deviceCards: some View {
        HStack(spacing: 14) {
            voiceDeviceCard(
                title: "UFI103S",
                subtitle: "Debian + VoHive",
                availability: .unsupported("未发现可承载双向语音的硬件音频链路"),
                symbol: "simcard.2"
            )
            voiceDeviceCard(
                title: dji.snapshot.map { "大疆 \($0.device.model)" } ?? "大疆 QDC507",
                subtitle: dji.snapshot?.device.firmware.isEmpty == false
                    ? dji.snapshot!.device.firmware
                    : "USB 2ca3:4006",
                availability: dji.voiceAvailability,
                symbol: "antenna.radiowaves.left.and.right"
            )
        }
    }

    private func voiceDeviceCard(
        title: String,
        subtitle: String,
        availability: VoiceAvailability,
        symbol: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(Color.indigo.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(availability.title, systemImage: availability.symbol)
                .font(.subheadline.bold())
                .foregroundStyle(availability == .ready ? .green : .orange)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func readinessCard(_ snapshot: DJIModemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("大疆通话能力").font(.title2.bold())
                    Text(dji.voiceAvailability.detail).foregroundStyle(.secondary)
                }
                Spacer()
                Text(dji.voiceAvailability.title)
                    .font(.headline)
                    .foregroundStyle(dji.voiceAvailability == .ready ? .green : .orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                readinessItem("AT 控制", ready: snapshot.voice.controlAvailable)
                readinessItem("ADB", ready: snapshot.voice.adbEnabled)
                readinessItem("USB 音频", ready: snapshot.voice.uacEnabled)
                readinessItem("IMS", ready: snapshot.voice.imsEnabled)
                readinessItem(
                    "VoLTE 能力",
                    ready: snapshot.voice.volteCapability == 1,
                    detail: volteCapabilityLabel(snapshot.voice.volteCapability)
                )
                readinessItem("VoLTE 开关", ready: snapshot.voice.volteEnabled)
                readinessItem("AC 输入", ready: dji.hostAudioInputAvailable)
                readinessItem("AS 输出", ready: dji.hostAudioOutputAvailable)
                readinessItem("SIM", ready: snapshot.sim.state == "ready", detail: snapshot.sim.label)
            }
            Text("拨号只会在模块报告 VoLTE capability=1，且 IMS、USB 音频、主机音频桥和 SIM 全部就绪后开放。UFI103S 始终只作为短信设备。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private func initializationCard(_ snapshot: DJIModemSnapshot) -> some View {
        if let info = snapshot.initialization {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: info.adbUACInitialized ? "checkmark.shield.fill" : "externaldrive.badge.plus")
                        .font(.title2)
                        .foregroundStyle(info.adbUACInitialized ? .green : .indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("大疆初始化与回滚").font(.title2.bold())
                        Text(info.reason).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(info.adbUACInitialized ? "ADB/UAC 已启用" : "尚未完整初始化")
                        .font(.subheadline.bold())
                        .foregroundStyle(info.adbUACInitialized ? .green : .orange)
                }

                HStack(spacing: 12) {
                    statusPill(
                        title: "本机备份",
                        value: info.backupAvailable ? String(info.backupCount) + " 份" : "无可用备份",
                        ready: info.backupAvailable
                    )
                    statusPill(
                        title: "模块标识",
                        value: snapshot.device.imeiSuffix.map { "IMEI 尾号 " + $0 } ?? "未读取",
                        ready: snapshot.device.imeiSuffix != nil
                    )
                    if let savedAt = info.latestBackupAt {
                        statusPill(title: "最近备份", value: displayDate(savedAt), ready: true)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        confirmInitialization = true
                    } label: {
                        Label("创建备份并初始化 ADB/UAC", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!info.canInitialize || dji.isPerformingDeviceAction)

                    Button(role: .destructive) {
                        confirmRestore = true
                    } label: {
                        Label("恢复写入前 USB 配置", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(!info.canRestore || dji.isPerformingDeviceAction)

                    if dji.isPerformingDeviceAction {
                        ProgressView().controlSize(.small)
                        Text("正在安全处理设备…").foregroundStyle(.secondary)
                    }
                }

                if let message = dji.operationMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(message)
                        Spacer()
                        Button { dji.clearOperationMessage() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Text("备份只保存在本机 WiSiM 的 App 数据目录，包含设备识别信息，不会上传或写入项目。恢复 USB 配置不等于撤销模块可能保存的 QADBKEY 持久授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .cardStyle()
        }
    }

    private func statusPill(title: String, value: String, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(value, systemImage: ready ? "checkmark.circle.fill" : "minus.circle")
                .font(.subheadline.bold())
                .foregroundStyle(ready ? .primary : .secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func volteCapabilityLabel(_ value: Int?) -> String {
        switch value {
        case 1: return "1（模块支持）"
        case 0: return "0（当前不支持）"
        default: return "未取得可信结果"
        }
    }

    private func displayDate(_ value: String) -> String {
        value.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "+08:00", with: "")
    }

    private func readinessItem(_ title: String, ready: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func callCard(_ snapshot: DJIModemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前呼叫").font(.title2.bold())
                    Text(snapshot.call.label).foregroundStyle(.secondary)
                }
                Spacer()
                if let number = snapshot.call.number, !number.isEmpty {
                    Text(number).font(.title3.monospacedDigit().bold())
                }
            }

            if snapshot.call.isIdle {
                HStack {
                    TextField("号码（请包含国家/地区码）", text: $phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dial() }
                    Button("拨打") { dial() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!dji.callActionsEnabled || phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack {
                    if snapshot.call.incoming {
                        Button("接听") { Task { await dji.answer() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                    Button("挂断", role: .destructive) { Task { await dji.hangup() } }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let error = dji.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .cardStyle()
    }

    private func dial() {
        let number = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        Task { await dji.dial(number) }
    }
}

struct IncomingCallBanner: View {
    @EnvironmentObject private var dji: DJIModemService

    var body: some View {
        if let call = dji.snapshot?.call, call.incoming {
            HStack(spacing: 14) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.green)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("大疆模块来电").font(.headline)
                    Text(call.number?.isEmpty == false ? call.number! : "未知号码")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("接听") { Task { await dji.answer() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!dji.callActionsEnabled)
                Button("拒接", role: .destructive) { Task { await dji.hangup() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(18)
        }
    }
}
