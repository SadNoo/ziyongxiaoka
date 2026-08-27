import CryptoKit
import Foundation
import UserNotifications

final class SMSNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class AppState: ObservableObject {
    private static let readStateDefaultsKey = "smsReadThroughByContactHash"
    enum Phase: Equatable {
        case idle
        case discovering
        case loginRequired
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var endpoint: URL?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var appliance: ApplianceStatus?
    @Published private(set) var devices: [DashboardDevice] = []
    @Published private(set) var managedDevices: [ManagedDevice] = []
    @Published private(set) var selectedDeviceDetail: DeviceDetail?
    @Published var selectedDeviceID: String?
    @Published private(set) var trafficAnalysis: TrafficAnalysis = .empty
    @Published var trafficRange: TrafficRange = .day
    @Published private(set) var notificationSettings: NotificationSettings?
    @Published private(set) var isNotificationLoading = false
    @Published private(set) var contacts: [SMSContact] = []
    @Published private(set) var messages: [SMSMessage] = []
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var isOverviewLoading = false
    @Published var selectedContactID: String?
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var isBusy = false

    private var client: APIClient?
    private var noticeDismissTask: Task<Void, Never>?
    private var knownLastSMSIDs: [String: Int] = [:]
    @Published private var readThroughSMSIDs: [String: Int] = AppState.loadReadState()
    private var hasSMSBaseline = false
    private var smsViewActive = false
    private var askedForNotificationPermission = false
    private let notificationDelegate = SMSNotificationDelegate()

    var selectedContact: SMSContact? {
        contacts.first { $0.id == selectedContactID }
    }

    var selectedManagedDevice: ManagedDevice? {
        managedDevices.first { $0.id == selectedDeviceID }
    }

    var authenticationRequired: Bool {
        capabilities?.authRequired ?? true
    }

    var smsEnabled: Bool {
        appliance?.workMode.smsEnabled ?? true
    }

    func unreadCount(for contact: SMSContact) -> Int {
        if let readThrough = readThroughSMSIDs[readStateKey(for: contact)], readThrough >= contact.lastSMSID {
            return 0
        }
        return contact.unreadCount
    }

    func discover() async {
        phase = .discovering
        errorMessage = nil
        // macOS may grant the local-network path just after the app becomes
        // active. A short second pass avoids making the user connect manually
        // on the first launch while keeping USB ahead of Wi-Fi.
        for pass in 0..<2 {
            for value in ManagementEndpoint.defaults {
                if Task.isCancelled { return }
                do {
                    let url = try ManagementEndpoint.normalize(value)
                    let probe = APIClient(
                        baseURL: url,
                        requestTimeout: 3,
                        resourceTimeout: 4
                    )
                    let detected = try await probe.capabilities()
                    if Task.isCancelled { return }
                    try await prepareConnection(url, detectedCapabilities: detected)
                    return
                } catch {
                    if Task.isCancelled { return }
                    continue
                }
            }
            guard pass == 0 else { break }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        if Task.isCancelled { return }
        phase = .failed("没有找到 UFI 管理端。请确认 UFI USB 或设备 Wi‑Fi 已连接，也可以手动填写管理地址。")
    }

    func connect(to rawEndpoint: String) async {
        phase = .discovering
        errorMessage = nil
        do {
            try await prepareConnection(ManagementEndpoint.normalize(rawEndpoint))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func login(username: String, password: String) async -> Bool {
        guard let client else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await client.login(username: username, password: password)
            client.setBearerToken(response.token)
            phase = .connected
            prepareSMSNotifications()
            await refreshOverview()
            await refreshContacts()
            return true
        } catch {
            client.clearCredentials()
            errorMessage = error.localizedDescription
            phase = .loginRequired
            return false
        }
    }

    func disconnect() {
        noticeDismissTask?.cancel()
        client?.clearCredentials()
        client = nil
        endpoint = nil
        capabilities = nil
        appliance = nil
        devices = []
        managedDevices = []
        selectedDeviceDetail = nil
        selectedDeviceID = nil
        trafficAnalysis = .empty
        trafficRange = .day
        notificationSettings = nil
        contacts = []
        messages = []
        logs = []
        selectedContactID = nil
        knownLastSMSIDs = [:]
        hasSMSBaseline = false
        smsViewActive = false
        notice = nil
        errorMessage = nil
        phase = .idle
    }

    func refreshOverview(reportErrors: Bool = true) async {
        guard let client else { return }
        if appliance == nil { isOverviewLoading = true }
        defer { isOverviewLoading = false }

        let statusTask = Task { try await client.applianceStatus() }
        let dashboardTask = Task { try await client.dashboardDevices() }
        let managedTask = Task { try await client.managedDevices() }
        let trafficTask = Task { try await client.trafficAnalysis(range: trafficRange) }

        do {
            appliance = try await statusTask.value
        } catch {
            if reportErrors { handle(error) }
        }

        do {
            devices = try await dashboardTask.value
        } catch let apiError as APIClientError where apiError == .unauthorized {
            handle(apiError)
        } catch {
            // Keep the last known list and allow the next refresh to recover.
        }

        do {
            let response = try await managedTask.value
            managedDevices = response.devices
            if selectedDeviceID == nil || !response.devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = response.devices.first?.id
            }
        } catch let apiError as APIClientError where apiError == .unauthorized {
            handle(apiError)
        } catch {
            // The overview stays useful even if the slower management list is unavailable.
        }

        do {
            trafficAnalysis = try await trafficTask.value
        } catch let apiError as APIClientError where apiError == .unauthorized {
            handle(apiError)
        } catch {
            // Keep the previous aggregate while the sampler or modem recovers.
        }

        if let selectedDeviceID {
            await refreshDeviceDetail(id: selectedDeviceID, reportErrors: false)
        }
    }

    func refreshTraffic(range: TrafficRange) async {
        guard let client else { return }
        trafficRange = range
        do {
            trafficAnalysis = try await client.trafficAnalysis(range: range)
        } catch {
            handle(error)
        }
    }

    func selectDevice(id: String) async {
        guard selectedDeviceID != id || selectedDeviceDetail?.id != id else { return }
        selectedDeviceID = id
        selectedDeviceDetail = nil
        await refreshDeviceDetail(id: id)
    }

    func refreshDeviceDetail(id: String? = nil, reportErrors: Bool = true) async {
        guard let client, let targetID = id ?? selectedDeviceID else { return }
        do {
            let detail = try await client.deviceOverview(id: targetID)
            guard selectedDeviceID == targetID else { return }
            selectedDeviceDetail = detail
        } catch {
            if reportErrors { handle(error) }
        }
    }

    func refreshManagedDevice() async {
        guard let client, let id = selectedDeviceID else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            try await client.refreshDevice(id: id)
            await refreshOverview(reportErrors: false)
            showNotice("设备与 SIM 信息已刷新")
        } catch {
            handle(error)
        }
    }

    func setDeviceNetwork(enabled: Bool) async {
        guard let client, let id = selectedDeviceID else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.setDeviceNetwork(id: id, enabled: enabled)
            await refreshOverview(reportErrors: false)
            showNotice(enabled ? "蜂窝数据连接已开启" : "蜂窝数据连接已关闭")
        } catch {
            handle(error)
        }
    }

    func setDeviceFlightMode(enabled: Bool) async {
        guard let client, let id = selectedDeviceID else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.setFlightMode(id: id, enabled: enabled)
            await refreshOverview(reportErrors: false)
            showNotice(enabled ? "飞行模式已开启" : "飞行模式已关闭")
        } catch {
            handle(error)
        }
    }

    func rotateDeviceIP() async {
        guard let client, let id = selectedDeviceID else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            try await client.rotateDeviceIP(id: id)
            await refreshOverview(reportErrors: false)
            showNotice("已提交更换公网 IP")
        } catch {
            handle(error)
        }
    }

    func loadNotificationSettings(reportErrors: Bool = true) async {
        guard let client else { return }
        isNotificationLoading = true
        defer { isNotificationLoading = false }
        do {
            notificationSettings = try await client.notificationSettings()
        } catch {
            if reportErrors { handle(error) }
        }
    }

    func saveNotificationSettings(_ settings: NotificationSettings) async -> Bool {
        guard let client else { return false }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            let response = try await client.saveNotificationSettings(settings)
            notificationSettings = settings
            if let warning = response.warning, !warning.isEmpty {
                showNotice(warning)
            } else {
                showNotice("网页通知集成已保存")
            }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func switchWorkMode(_ mode: WorkMode) async {
        guard let client else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.switchWorkMode(mode)
            await refreshOverview(reportErrors: false)
            showNotice("已切换到\(mode.title)")
        } catch {
            handle(error)
        }
    }

    func updateLED(enabled: Bool, nightMode: Bool) async {
        guard let client else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.updateLED(enabled: enabled, nightMode: nightMode)
            await refreshOverview(reportErrors: false)
            if !enabled {
                showNotice("状态灯已关闭")
            } else if nightMode {
                showNotice("夜间模式已开启，仅异常时亮灯")
            } else {
                showNotice("状态灯已恢复当前工作模式颜色")
            }
        } catch {
            handle(error)
        }
    }

    func switchUplinkMode(_ mode: UplinkMode) async {
        guard let client else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.switchUplinkMode(mode)
            await refreshOverview(reportErrors: false)
            showNotice("网络方向已切换为“\(mode.title)”")
        } catch {
            handle(error)
        }
    }

    func updateWiFi(ssid: String, password: String, confirmation: String) async -> Bool {
        guard let client else { return false }
        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssidByteCount = normalizedSSID.lengthOfBytes(using: .utf8)
        guard (1...32).contains(ssidByteCount),
              !normalizedSSID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else {
            errorMessage = "Wi-Fi 名称必须为 1～32 字节，且不能包含控制字符"
            return false
        }
        guard password == confirmation else {
            errorMessage = "两次输入的 Wi-Fi 密码不一致"
            return false
        }
        let byteCount = password.lengthOfBytes(using: .utf8)
        guard (8...63).contains(byteCount),
              !password.contains(":"),
              !password.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else {
            errorMessage = "Wi-Fi 密码必须为 8～63 字节，且不能包含冒号或控制字符"
            return false
        }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.updateWiFi(ssid: normalizedSSID, password: password)
            showNotice("Wi-Fi 名称和密码已更新，热点将在约 8 秒后重启")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func refreshContacts(background: Bool = false) async {
        guard let client, smsEnabled else { return }
        do {
            let updated = try await client.contacts().sorted { $0.lastTimestamp > $1.lastTimestamp }
            let previousIDs = knownLastSMSIDs
            contacts = updated

            if hasSMSBaseline {
                for contact in updated where contact.lastType != 2 {
                    guard let previous = previousIDs[contact.id], contact.lastSMSID > previous else { continue }
                    postSMSNotification(contact)
                }
            }
            for contact in updated {
                knownLastSMSIDs[contact.id] = max(knownLastSMSIDs[contact.id] ?? 0, contact.lastSMSID)
            }
            hasSMSBaseline = true

            if selectedContactID == nil || selectedContact == nil {
                selectedContactID = updated.first?.id
            }
            if smsViewActive, let selectedContact {
                let loaded = await loadThread(selectedContact, reportErrors: !background)
                if loaded { markContactSeen(selectedContact) }
            } else if smsViewActive {
                messages = []
            }
        } catch let apiError as APIClientError where apiError == .unauthorized {
            handle(apiError)
        } catch {
            if !background { handle(error) }
        }
    }

    func runSMSRefreshLoop() async {
        prepareSMSNotifications()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            await refreshContacts(background: true)
        }
    }

    func selectContact(_ contact: SMSContact) async {
        selectedContactID = contact.id
        if await loadThread(contact) { markContactSeen(contact) }
    }

    func setSMSViewActive(_ active: Bool) {
        smsViewActive = active
    }

    @discardableResult
    func loadThread(_ contact: SMSContact, reportErrors: Bool = true) async -> Bool {
        guard let client else { return false }
        do {
            messages = try await client.thread(for: contact).sorted {
                if $0.timestamp == $1.timestamp { return $0.id < $1.id }
                return $0.timestamp < $1.timestamp
            }
            return true
        } catch {
            if reportErrors { handle(error) }
            return false
        }
    }

    func sendSMS(phone: String, message: String, contact: SMSContact?) async -> Bool {
        guard let client else { return false }
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLastMessageID = messages.last?.id ?? 0
        guard !trimmedPhone.isEmpty, !trimmedMessage.isEmpty else {
            errorMessage = "号码和短信内容不能为空"
            return false
        }
        guard smsEnabled else {
            errorMessage = "当前为网卡模式，短信引擎已停用"
            return false
        }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.sendSMS(phone: trimmedPhone, message: trimmedMessage, contact: contact)
            showNotice("短信已提交。最终送达情况以运营商网络为准。")
            await refreshContacts()

            if contact == nil,
               let createdContact = contacts.first(where: { $0.peer == trimmedPhone })
            {
                selectedContactID = createdContact.id
                if await loadThread(createdContact, reportErrors: false) {
                    markContactSeen(createdContact)
                }
            }

            // Some modem paths commit outgoing history just after the send
            // response. One bounded retry keeps a reply visible promptly.
            if let contact,
               !messages.contains(where: { $0.id > previousLastMessageID && $0.outgoing && $0.content == trimmedMessage })
            {
                try? await Task.sleep(nanoseconds: 800_000_000)
                _ = await loadThread(contact, reportErrors: false)
            }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func deleteSMSMessage(_ message: SMSMessage, from contact: SMSContact) async -> Bool {
        guard let client else { return false }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            let response = try await client.deleteSMSMessage(id: message.id)
            messages.removeAll { $0.id == message.id }
            if response.threadEmpty {
                selectedContactID = nil
                messages = []
                clearReadState(for: contact)
            }
            await refreshContacts()
            showNotice("已删除短信")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func deleteSMSThread(_ contact: SMSContact) async -> Bool {
        guard let client else { return false }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            _ = try await client.deleteSMSThread(for: contact)
            if selectedContactID == contact.id {
                selectedContactID = nil
                messages = []
            }
            contacts.removeAll { $0.id == contact.id }
            knownLastSMSIDs.removeValue(forKey: contact.id)
            clearReadState(for: contact)
            await refreshContacts()
            showNotice("已删除整个短信会话")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func refreshLogs() async {
        guard let client else { return }
        do {
            logs = try await client.logs().sorted {
                if $0.time == $1.time { return $0.id > $1.id }
                return $0.time > $1.time
            }
        } catch {
            handle(error)
        }
    }

    func setLoginProtection(enabled: Bool) async {
        guard let client else { return }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            let mode = enabled ? "login-required" : "trusted-network"
            let response = try await client.setAccessMode(mode)
            capabilities = Capabilities(
                status: "ok",
                authRequired: response.authRequired,
                accessMode: response.accessMode,
                workModes: WorkMode.allCases,
                ledControl: capabilities?.ledControl,
                keychainUsed: false
            )
            if enabled {
                client.clearCredentials()
                phase = .loginRequired
                showNotice("登录保护已开启，请重新登录")
            } else {
                showNotice("登录保护已关闭；已启用设备网络免登录管理")
                await refreshOverview()
            }
        } catch {
            handle(error)
        }
    }

    func clearMessages() {
        noticeDismissTask?.cancel()
        notice = nil
        errorMessage = nil
    }

    private func prepareConnection(
        _ url: URL,
        detectedCapabilities: Capabilities? = nil
    ) async throws {
        let candidate = APIClient(baseURL: url)
        let detected: Capabilities
        if let detectedCapabilities {
            detected = detectedCapabilities
        } else {
            detected = try await candidate.capabilities()
        }
        endpoint = url
        capabilities = detected
        client = candidate
        appliance = nil
        devices = []
        managedDevices = []
        selectedDeviceDetail = nil
        selectedDeviceID = nil
        trafficAnalysis = .empty
        trafficRange = .day
        notificationSettings = nil
        contacts = []
        messages = []
        logs = []
        selectedContactID = nil
        knownLastSMSIDs = [:]
        hasSMSBaseline = false
        smsViewActive = false
        if detected.authRequired {
            phase = .loginRequired
        } else {
            phase = .connected
            prepareSMSNotifications()
            await refreshOverview()
            await refreshContacts()
        }
    }

    private func markContactSeen(_ contact: SMSContact) {
        let key = readStateKey(for: contact)
        readThroughSMSIDs[key] = max(readThroughSMSIDs[key] ?? 0, contact.lastSMSID)
        UserDefaults.standard.set(readThroughSMSIDs, forKey: Self.readStateDefaultsKey)
    }

    private func readStateKey(for contact: SMSContact) -> String {
        SHA256.hash(data: Data(contact.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func clearReadState(for contact: SMSContact) {
        readThroughSMSIDs.removeValue(forKey: readStateKey(for: contact))
        UserDefaults.standard.set(readThroughSMSIDs, forKey: Self.readStateDefaultsKey)
    }

    private static func loadReadState() -> [String: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: readStateDefaultsKey) else { return [:] }
        var result: [String: Int] = [:]
        for (key, value) in stored {
            if let number = value as? NSNumber { result[key] = number.intValue }
        }
        return result
    }

    private func showNotice(_ message: String) {
        noticeDismissTask?.cancel()
        errorMessage = nil
        notice = message
        noticeDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func prepareSMSNotifications() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        guard !askedForNotificationPermission else { return }
        askedForNotificationPermission = true
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    private func postSMSNotification(_ contact: SMSContact) {
        let content = UNMutableNotificationContent()
        content.title = "收到新短信"
        content.subtitle = contact.peer
        content.body = contact.lastContent.isEmpty ? "点击查看短信内容" : contact.lastContent
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "wangka-sms-\(contact.lastSMSID)",
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private func handle(_ error: Error) {
        noticeDismissTask?.cancel()
        notice = nil
        errorMessage = error.localizedDescription
        if let apiError = error as? APIClientError, apiError == .unauthorized {
            client?.clearCredentials()
            phase = .loginRequired
        }
    }
}
