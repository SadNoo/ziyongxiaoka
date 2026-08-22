import AppKit
import Charts
import Foundation
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingMode: WorkMode?
    @State private var pendingDeviceAction: DeviceAction?

    private let adaptiveColumns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let appliance = state.appliance {
                    statusGrid(appliance)
                    workModeCard(appliance)
                } else {
                    statusPlaceholderGrid
                    workModePlaceholder
                }

                trafficCard

                if let appliance = state.appliance {
                    thermalCard(appliance.thermal)
                } else {
                    thermalPlaceholder
                }

                deviceManagementSection
            }
            .padding(24)
            .frame(maxWidth: 1240, alignment: .leading)
        }
        .confirmationDialog(
            "切换工作模式",
            isPresented: Binding(
                get: { pendingMode != nil },
                set: { if !$0 { pendingMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let mode = pendingMode {
                Button("切换到\(mode.title)") {
                    pendingMode = nil
                    Task { await state.switchWorkMode(mode) }
                }
            }
            Button("取消", role: .cancel) { pendingMode = nil }
        } message: {
            Text(pendingMode?.detail ?? "")
        }
        .confirmationDialog(
            pendingDeviceAction?.title ?? "确认操作",
            isPresented: Binding(
                get: { pendingDeviceAction != nil },
                set: { if !$0 { pendingDeviceAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingDeviceAction {
                Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                    pendingDeviceAction = nil
                    Task { await perform(action) }
                }
            }
            Button("取消", role: .cancel) { pendingDeviceAction = nil }
        } message: {
            Text(pendingDeviceAction?.message ?? "")
        }
        .task { if state.appliance == nil { await state.refreshOverview() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("网卡管理").font(.largeTitle.bold())
                Text("设备状态、流量与 SIM 管理")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await state.refreshOverview() } } label: {
                if state.isOverviewLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(state.isBusy)
        }
    }

    private func statusGrid(_ appliance: ApplianceStatus) -> some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 14) {
            metric("VoHive", appliance.vohiveActive ? "运行中" : "未运行", appliance.vohiveActive ? .green : .red, "server.rack")
            metric("Wi‑Fi", appliance.wifiSSID, .indigo, "wifi")
            metric("网络方向", uplinkTitle(appliance.uplinkMode), .blue, "arrow.left.arrow.right")
            metric("蜂窝设备", deviceSummary, onlineDeviceCount > 0 ? .green : .secondary, "simcard.2")
            metric("系统时间", appliance.systemTime, .secondary, "clock")
        }
    }

    private var statusPlaceholderGrid: some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 14) {
            metric("VoHive", "检测中…", .secondary, "server.rack")
            metric("Wi‑Fi", "检测中…", .secondary, "wifi")
            metric("网络方向", "检测中…", .secondary, "arrow.left.arrow.right")
            metric("蜂窝设备", "检测中…", .secondary, "simcard.2")
            metric("系统时间", "读取中…", .secondary, "clock")
        }
        .allowsHitTesting(false)
    }

    private var onlineDeviceCount: Int {
        if !state.managedDevices.isEmpty { return state.managedDevices.filter(\.healthy).count }
        return state.devices.filter(\.healthy).count
    }

    private var totalDeviceCount: Int {
        !state.managedDevices.isEmpty ? state.managedDevices.count : state.devices.count
    }

    private var deviceSummary: String { "\(onlineDeviceCount) 在线 / \(totalDeviceCount) 台" }

    private func uplinkTitle(_ value: String) -> String {
        UplinkMode(rawValue: value)?.title ?? value
    }

    private func metric(_ title: String, _ value: String, _ color: Color, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func workModeCard(_ appliance: ApplianceStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作模式").font(.title2.bold())
                    Text("默认双模式；切换会短暂重启蜂窝管理服务")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(appliance.workMode.mode.title).font(.headline).foregroundStyle(.indigo)
            }
            HStack(spacing: 12) {
                ForEach(WorkMode.allCases) { mode in
                    Button {
                        if appliance.workMode.mode != mode { pendingMode = mode }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: mode.symbol).font(.title2)
                            Text(mode.title).font(.headline)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                        .padding(14)
                        .background(appliance.workMode.mode == mode ? Color.indigo.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(appliance.workMode.mode == mode ? Color.indigo : Color.secondary.opacity(0.2))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isBusy || appliance.workMode.transitionMode != nil)
                }
            }
            if !appliance.workMode.lastError.isEmpty {
                Label(appliance.workMode.lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private var workModePlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作模式").font(.title2.bold())
                    Text("正在读取当前模式…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("检测中").font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(WorkMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: mode.symbol).font(.title2)
                        Text(mode.title).font(.headline)
                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                    .padding(14)
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)) }
                }
            }
        }
        .cardStyle()
        .allowsHitTesting(false)
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("流量分析").font(.title2.bold())
                    Text("设备端按分钟采样，按日、周或月聚合")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("范围", selection: Binding(
                    get: { state.trafficRange },
                    set: { range in Task { await state.refreshTraffic(range: range) } }
                )) {
                    ForEach(TrafficRange.allCases) { range in Text(range.title).tag(range) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack(spacing: 12) {
                trafficMetric("下载", state.trafficAnalysis.receivedBytes, .blue, "arrow.down")
                trafficMetric("上传", state.trafficAnalysis.transmittedBytes, .indigo, "arrow.up")
                trafficMetric("总计", state.trafficAnalysis.totalBytes, .green, "sum")
            }

            if trafficPoints.isEmpty {
                Text("当前周期暂无流量采样；建立蜂窝数据连接后会自动出现。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                Chart(trafficPoints) { point in
                    AreaMark(x: .value("时间", point.timestamp), y: .value("流量", point.bytes))
                        .foregroundStyle(.blue.opacity(0.12))
                    LineMark(x: .value("时间", point.timestamp), y: .value("流量", point.bytes))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) { Text(formatBytes(bytes)) }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .cardStyle()
    }

    private func trafficMetric(_ title: String, _ bytes: Double, _ color: Color, _ symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(formatBytes(bytes)).font(.headline.monospacedDigit())
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var trafficPoints: [TrafficPoint] {
        guard let chart = state.trafficAnalysis.chart else { return [] }
        return chart.timestamps.enumerated().compactMap { index, timestamp in
            let total = chart.devices.reduce(0.0) { partial, device in
                let values = chart.series[device] ?? []
                return partial + (values.indices.contains(index) ? values[index] : 0)
            }
            return TrafficPoint(timestamp: timestamp, bytes: total)
        }.suffix(96).map { $0 }
    }

    private func thermalCard(_ thermal: ThermalStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("温度").font(.title2.bold())
                Spacer()
                if let maximum = thermal.maximumC {
                    Text(String(format: "最高 %.1f°C", maximum)).foregroundStyle(temperatureColor(thermal.level))
                }
            }
            if thermal.sensors.isEmpty {
                Text("设备暂未提供可用的 thermal_zone 温度读数").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: adaptiveColumns, spacing: 12) {
                    ForEach(thermal.sensors.prefix(6)) { sensor in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sensor.name).font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.1f°C", sensor.temperatureC)).font(.headline)
                            }
                            Spacer()
                        }
                        .padding(11)
                        .background(temperatureColor(sensor.level).opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text("达到 \(Int(thermal.warningC))°C 显示警告，达到 \(Int(thermal.criticalC))°C 显示严重警告。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var thermalPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("温度").font(.title2.bold())
                Spacer()
                Text("读取中…").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(["CPU", "GPU", "基带"], id: \.self) { name in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Text("--.-°C").font(.headline)
                    }
                    .padding(11)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .cardStyle()
        .allowsHitTesting(false)
    }

    private var deviceManagementSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SIM 与设备管理").font(.title2.bold())
                    Text("查看驻网、信号、卡信息和蜂窝数据状态")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let endpoint = state.endpoint {
                    Button("网页高级管理") { NSWorkspace.shared.open(endpoint) }
                }
            }

            if state.managedDevices.isEmpty {
                Text("暂未读取到受管蜂窝设备。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
                    .cardStyle()
            } else {
                LazyVGrid(columns: adaptiveColumns, spacing: 14) {
                    ForEach(state.managedDevices) { device in managedDeviceCard(device) }
                }
                selectedDevicePanel
            }
        }
    }

    private func managedDeviceCard(_ device: ManagedDevice) -> some View {
        Button { Task { await state.selectDevice(id: device.id) } } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Circle().fill(device.healthy ? Color.green : Color.red).frame(width: 9, height: 9)
                    Text(device.name.isEmpty ? device.id : device.name).font(.headline).lineLimit(1)
                    Spacer()
                    if state.selectedDeviceID == device.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                    }
                }
                Text([device.modem?.operatorName, device.modem?.networkMode].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "未驻网")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Label(device.modem?.signalDBM.map { "\($0) dBm" } ?? "—", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text(device.networkConnected ? "数据已连接" : "数据未连接")
                        .foregroundStyle(device.networkConnected ? .green : .secondary)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            .padding(16)
            .background(state.selectedDeviceID == device.id ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(state.selectedDeviceID == device.id ? Color.indigo : Color.secondary.opacity(0.2))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedDevicePanel: some View {
        if let detail = state.selectedDeviceDetail, detail.id == state.selectedDeviceID {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle().fill(detail.healthy ? Color.green : Color.red).frame(width: 10, height: 10)
                            Text(detail.name.isEmpty ? detail.id : detail.name).font(.title2.bold())
                        }
                        Text(detail.lifecycleReason.nilIfEmpty ?? lifecycleTitle(detail.lifecyclePhase))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await state.refreshManagedDevice() } } label: {
                        Label("刷新设备", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isBusy)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    detailGroup("SIM 卡", symbol: "simcard") {
                        detailRow("本机号码", detail.localPhone)
                        detailRow("ICCID", detail.modem?.iccid, sensitive: true)
                        detailRow("IMSI", detail.modem?.imsi, sensitive: true)
                        detailRow("运营商", detail.modem?.operatorName ?? detail.modem?.nativeSPN)
                        detailRow("MCC / MNC", [detail.modem?.nativeMCC, detail.modem?.nativeMNC].compactMap { $0 }.joined(separator: " / ").nilIfEmpty)
                    }
                    detailGroup("调制解调器", symbol: "cpu") {
                        detailRow("IMEI", detail.modem?.imei, sensitive: true)
                        detailRow("固件", detail.modem?.firmware)
                        detailRow("网络", [detail.modem?.networkDuplex, detail.modem?.networkMode].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                        detailRow("频段", detail.modem?.radioBand)
                        detailRow("信道", detail.modem?.radioChannel.map(String.init))
                    }
                    detailGroup("信号与驻网", symbol: "antenna.radiowaves.left.and.right") {
                        detailRow("注册状态", detail.modem?.registrationText ?? detail.registrationState)
                        detailRow("RSSI", detail.modem?.signalDBM.map { "\($0) dBm" })
                        detailRow("RSRP", detail.modem?.signalRSRP.map(String.init))
                        detailRow("RSRQ", detail.modem?.signalRSRQ.map(String.init))
                        detailRow("SINR", detail.modem?.signalSINR.map(String.init))
                    }
                    detailGroup("蜂窝数据", symbol: "network") {
                        detailRow("状态", detail.networkConnected ? "已连接" : "未连接")
                        detailRow("接口", detail.interface)
                        detailRow("APN", detail.modem?.apn)
                        detailRow("内网 IP", detail.privateIP)
                        detailRow("公网 IP", detail.publicIP)
                        detailRow("下载累计", detail.traffic?.received)
                        detailRow("上传累计", detail.traffic?.transmitted)
                    }
                }

                HStack(spacing: 10) {
                    Button(detail.networkEnabled ? "关闭蜂窝数据" : "开启蜂窝数据") {
                        pendingDeviceAction = .network(!detail.networkEnabled)
                    }
                    Button(detail.flightModeEnabled ? "关闭飞行模式" : "开启飞行模式") {
                        pendingDeviceAction = .flight(!detail.flightModeEnabled)
                    }
                    Button("更换公网 IP") { pendingDeviceAction = .rotateIP }
                        .disabled(!detail.networkEnabled)
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy)
            }
            .cardStyle()
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在读取所选设备与 SIM 信息…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .cardStyle()
        }
    }

    private func detailGroup<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(15)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func detailRow(_ title: String, _ value: String?, sensitive: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.nilIfEmpty ?? "—")
                .font(.system(.body, design: sensitive ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .privacySensitive(sensitive)
        }
        .font(.caption)
    }

    private func lifecycleTitle(_ phase: String?) -> String {
        switch phase {
        case "online": return "设备在线"
        case "degraded": return "设备降级运行"
        case "recovering", "qmi_starting", "worker_starting": return "设备恢复中"
        case "rebooting": return "设备重启中"
        default: return "设备状态未知"
        }
    }

    private func perform(_ action: DeviceAction) async {
        switch action {
        case let .network(enabled): await state.setDeviceNetwork(enabled: enabled)
        case let .flight(enabled): await state.setDeviceFlightMode(enabled: enabled)
        case .rotateIP: await state.rotateDeviceIP()
        }
    }

    private func temperatureColor(_ level: String) -> Color {
        switch level {
        case "critical": return .red
        case "warning": return .orange
        default: return .green
        }
    }

    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }
}

private struct TrafficPoint: Identifiable {
    let timestamp: String
    let bytes: Double
    var id: String { timestamp }
}

private enum DeviceAction: Identifiable {
    case network(Bool)
    case flight(Bool)
    case rotateIP

    var id: String {
        switch self {
        case let .network(enabled): return "network-\(enabled)"
        case let .flight(enabled): return "flight-\(enabled)"
        case .rotateIP: return "rotate-ip"
        }
    }

    var title: String {
        switch self {
        case let .network(enabled): return enabled ? "开启蜂窝数据？" : "关闭蜂窝数据？"
        case let .flight(enabled): return enabled ? "开启飞行模式？" : "关闭飞行模式？"
        case .rotateIP: return "更换公网 IP？"
        }
    }

    var buttonTitle: String {
        switch self {
        case let .network(enabled): return enabled ? "确认开启" : "确认关闭"
        case let .flight(enabled): return enabled ? "确认开启" : "确认关闭"
        case .rotateIP: return "确认更换"
        }
    }

    var message: String {
        switch self {
        case let .network(enabled):
            return enabled ? "设备将建立蜂窝数据连接。" : "设备会断开蜂窝数据，但短信管理仍由当前工作模式决定。"
        case let .flight(enabled):
            return enabled ? "开启后设备会暂时离开运营商网络。" : "关闭后设备会重新搜索并注册运营商网络。"
        case .rotateIP:
            return "设备会短暂重连蜂窝数据以获取新的公网 IP。"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .network(false), .flight(true): return true
        default: return false
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
