import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var state: MobileAppState

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    managedHardwareSection
                    statusSection
                    workModeSection
                    temperatureSection
                    devicesSection
                }
                .padding()
            }
            .refreshable { await state.refreshAll() }
            .navigationTitle("设备管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await state.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var managedHardwareSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已支持设备").font(.headline)
            ForEach(state.managedHardware) { hardware in
                HStack(spacing: 12) {
                    Image(systemName: hardware.kind.symbol)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hardware.kind.title).font(.headline)
                        Text(hardware.availability.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(hardware.availability.title, systemImage: statusSymbol(hardware.availability))
                        .font(.caption.bold())
                        .foregroundStyle(statusColor(hardware.availability))
                }
                if hardware.id != state.managedHardware.last?.id { Divider() }
            }
        }
        .mobileCard()
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UFI103S").font(.title2.bold())
            LabeledContent("VoHive", value: state.appliance?.vohiveActive == true ? "运行中" : "未连接")
            LabeledContent("Wi-Fi", value: state.appliance?.wifiSSID ?? "—")
            LabeledContent("网络方向", value: state.appliance?.uplinkMode ?? "—")
            if let endpoint = state.endpoint { LabeledContent("管理地址", value: endpoint.absoluteString) }
        }
        .mobileCard()
    }

    private var workModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("工作模式").font(.headline)
                Spacer()
                Text(state.appliance?.workMode.mode.title ?? "读取中")
                    .foregroundStyle(.indigo)
            }
            ForEach(WorkMode.allCases) { mode in
                Button {
                    Task { await state.switchWorkMode(mode) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbol).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(mode.title).font(.headline)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.appliance?.workMode.mode == mode {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                if mode != WorkMode.allCases.last { Divider() }
            }
        }
        .mobileCard()
    }

    @ViewBuilder
    private var temperatureSection: some View {
        if let thermal = state.appliance?.thermal {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("温度").font(.headline)
                    Spacer()
                    Text(thermal.maximumC.map { String(format: "最高 %.1f°C", $0) } ?? "—")
                        .foregroundStyle((thermal.maximumC ?? 0) >= thermal.warningC ? .orange : .green)
                }
                ForEach(thermal.sensors) { sensor in
                    LabeledContent(sensor.name, value: String(format: "%.1f°C", sensor.temperatureC))
                }
                Text("达到 \(Int(thermal.warningC))°C 显示警告，达到 \(Int(thermal.criticalC))°C 显示严重警告。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .mobileCard()
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SIM 与蜂窝设备").font(.headline)
            if state.devices.isEmpty {
                Text("暂无设备信息").foregroundStyle(.secondary)
            } else {
                ForEach(state.devices) { device in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Circle().fill(device.healthy ? .green : .orange).frame(width: 9, height: 9)
                            Text(device.name).font(.headline)
                            Spacer()
                            Text(device.modem?.operatorName ?? "未注册").foregroundStyle(.secondary)
                        }
                        LabeledContent("网络", value: device.modem?.networkMode ?? "—")
                        LabeledContent("信号", value: device.modem?.signalDBM.map { "\($0) dBm" } ?? "—")
                        LabeledContent("公网 IP", value: device.publicIP ?? "—")
                    }
                    if device.id != state.devices.last?.id { Divider() }
                }
            }
        }
        .mobileCard()
    }

    private func statusSymbol(_ availability: ManagedHardwareAvailability) -> String {
        switch availability {
        case .connected: return "checkmark.circle.fill"
        case .notConnected: return "minus.circle"
        case .macRelayRequired: return "macbook.and.iphone"
        }
    }

    private func statusColor(_ availability: ManagedHardwareAvailability) -> Color {
        switch availability {
        case .connected: return .green
        case .notConnected: return .secondary
        case .macRelayRequired: return .orange
        }
    }
}

extension View {
    func mobileCard() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
