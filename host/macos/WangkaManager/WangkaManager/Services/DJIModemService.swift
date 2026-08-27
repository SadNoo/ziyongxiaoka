import CoreAudio
import Foundation
import UserNotifications

enum DJIModemServiceError: LocalizedError {
    case bridgeMissing
    case invalidBridgeResponse
    case bridgeFailure(String)

    var errorDescription: String? {
        switch self {
        case .bridgeMissing:
            return "WiSiM 大疆设备桥未包含在 App 中"
        case .invalidBridgeResponse:
            return "大疆设备桥返回了无法识别的数据"
        case let .bridgeFailure(message):
            return message
        }
    }
}

@MainActor
final class DJIModemService: ObservableObject {
    @Published private(set) var snapshot: DJIModemSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasCompletedInitialDetection = false
    @Published private(set) var isPerformingCallAction = false
    @Published private(set) var isPerformingDeviceAction = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var operationMessage: String?
    @Published private(set) var hostAudioInputAvailable = false
    @Published private(set) var hostAudioOutputAvailable = false

    private var refreshLoop: Task<Void, Never>?
    private var previousCallState = "idle"

    var isDetected: Bool { snapshot?.status == "ok" }

    var voiceAvailability: VoiceAvailability {
        guard let snapshot else {
            return .unavailable(errorMessage ?? "未检测到大疆 QDC507")
        }
        guard snapshot.voice.hardwareSupported else {
            return .unsupported(snapshot.voice.reason)
        }
        guard snapshot.voice.controlAvailable else {
            return .unavailable(snapshot.voice.reason)
        }
        if snapshot.voice.volteCapability == 0 {
            return .unsupported("模块固件当前报告 VoLTE capability=0，WiSiM 已禁用拨号。更换 SIM 后可以重新检测；如果仍为 0，则该组合无法启用通话。")
        }
        guard snapshot.voice.volteCapability == 1 else {
            return .unavailable("尚未取得可信的 VoLTE capability 结果，拨号保持禁用")
        }
        switch snapshot.voice.availability {
        case "needs_setup":
            return .needsSetup(snapshot.voice.reason)
        case "needs_runtime":
            if hostAudioInputAvailable && hostAudioOutputAvailable {
                return .needsRuntime("USB 音频已出现；仍需验证模块语音运行时和双向音频路由")
            }
            return .needsRuntime(snapshot.voice.reason)
        case "ready":
            guard hostAudioInputAvailable && hostAudioOutputAvailable else {
                return .needsRuntime("未同时检测到 AC Interface 输入与 AS Interface 输出")
            }
            return .ready
        default:
            return .unavailable(snapshot.voice.reason)
        }
    }

    var callActionsEnabled: Bool {
        voiceAvailability == .ready && snapshot?.sim.state == "ready"
    }

    deinit { refreshLoop?.cancel() }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } catch {
                    return
                }
                await self.refresh(silent: true)
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh(silent: Bool = false) async {
        guard !isPerformingDeviceAction else { return }
        if !silent { isRefreshing = true }
        defer {
            if !silent {
                isRefreshing = false
                hasCompletedInitialDetection = true
            }
        }
        do {
            let current = try await Self.executeBridge(
                arguments: ["status", Self.backupDirectoryURL.path]
            )
            snapshot = current
            errorMessage = nil
            refreshAudioDevices()
            notifyIfIncoming(current.call)
        } catch {
            if !silent || snapshot == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dial(_ rawNumber: String) async {
        await performCallAction(arguments: ["dial", rawNumber])
    }

    func answer() async {
        await performCallAction(arguments: ["answer"])
    }

    func hangup() async {
        await performCallAction(arguments: ["hangup"])
    }

    func initializeADBAndUSBAudio() async {
        await performDeviceAction(
            arguments: ["initialize-usb", Self.backupDirectoryURL.path, "--confirm-adb-uac"]
        )
    }

    func restoreUSBConfiguration() async {
        await performDeviceAction(
            arguments: ["restore-usb", Self.backupDirectoryURL.path, "--confirm-restore"]
        )
    }

    func clearOperationMessage() {
        operationMessage = nil
    }

    private func performCallAction(arguments: [String]) async {
        guard callActionsEnabled else {
            errorMessage = voiceAvailability.detail
            return
        }
        isPerformingCallAction = true
        errorMessage = nil
        defer { isPerformingCallAction = false }
        do {
            snapshot = try await Self.executeBridge(arguments: arguments)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDeviceAction(arguments: [String]) async {
        guard !isPerformingDeviceAction && !isPerformingCallAction else { return }
        isPerformingDeviceAction = true
        errorMessage = nil
        operationMessage = nil
        do {
            let result = try await Self.executeBridgeOperation(arguments: arguments)
            operationMessage = result.message ?? "设备操作已完成"
            if result.rebootRequested {
                snapshot = nil
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            isPerformingDeviceAction = false
            await refresh()
        } catch {
            isPerformingDeviceAction = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAudioDevices() {
        let names = Self.audioDeviceNames().map { $0.lowercased() }
        hostAudioInputAvailable = names.contains { $0.contains("ac interface") }
        hostAudioOutputAvailable = names.contains { $0.contains("as interface") }
    }

    private func notifyIfIncoming(_ call: DJICallInfo) {
        defer { previousCallState = call.state }
        guard call.state == "incoming", previousCallState != "incoming" else { return }
        let content = UNMutableNotificationContent()
        content.title = "WiSiM 来电"
        content.body = call.number?.isEmpty == false ? call.number! : "未知号码"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "wisim-incoming-call",
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    nonisolated private static func executeBridge(arguments: [String]) async throws -> DJIModemSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let response = try runBridge(arguments: arguments)
            let data = response.output
            guard !data.isEmpty,
                  let decoded = try? JSONDecoder().decode(DJIModemSnapshot.self, from: data)
            else {
                let diagnostic = String(
                    data: response.errors,
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let diagnostic, !diagnostic.isEmpty {
                    throw DJIModemServiceError.bridgeFailure(diagnostic)
                }
                throw DJIModemServiceError.invalidBridgeResponse
            }
            guard decoded.status == "ok" else {
                throw DJIModemServiceError.bridgeFailure(decoded.error ?? decoded.voice.reason)
            }
            return decoded
        }.value
    }

    nonisolated private static func executeBridgeOperation(arguments: [String]) async throws -> DJIDeviceOperationResult {
        try await Task.detached(priority: .userInitiated) {
            let response = try runBridge(arguments: arguments)
            guard !response.output.isEmpty,
                  let decoded = try? JSONDecoder().decode(DJIDeviceOperationResult.self, from: response.output)
            else {
                let diagnostic = String(data: response.errors, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let diagnostic, !diagnostic.isEmpty {
                    throw DJIModemServiceError.bridgeFailure(diagnostic)
                }
                throw DJIModemServiceError.invalidBridgeResponse
            }
            guard decoded.status == "ok" else {
                throw DJIModemServiceError.bridgeFailure(decoded.error ?? decoded.message ?? "设备操作失败")
            }
            return decoded
        }.value
    }

    nonisolated private static func runBridge(arguments: [String]) throws -> (output: Data, errors: Data) {
        let executable = try bridgeExecutableURL()
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            output.fileHandleForReading.readDataToEndOfFile(),
            errors.fileHandleForReading.readDataToEndOfFile()
        )
    }

    nonisolated private static var backupDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("WiSiM", isDirectory: true)
            .appendingPathComponent("QDC507Backups", isDirectory: true)
    }

    nonisolated private static func bridgeExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WISIM_BRIDGE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let bundled = Bundle.main.url(
            forResource: "wisim-modem-bridge",
            withExtension: nil,
            subdirectory: "bridge"
        ) else {
            throw DJIModemServiceError.bridgeMissing
        }
        return bundled
    }

    nonisolated private static func audioDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }

        return devices.compactMap { device in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) { pointer in
                AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
            }
            return status == noErr ? name as String : nil
        }
    }
}
