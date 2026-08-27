import Foundation
import UserNotifications

enum ConnectionPhase: Equatable {
    case idle, discovering, loginRequired, connected, failed(String)
}

@MainActor
final class MobileAppState: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var endpoint: URL?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var appliance: ApplianceStatus?
    @Published private(set) var devices: [ManagedDevice] = []
    @Published private(set) var contacts: [SMSContact] = []
    @Published private(set) var messages: [SMSMessage] = []
    @Published var selectedContactID: String?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var notice: String?

    private var client: MobileAPIClient?
    private var refreshLoop: Task<Void, Never>?
    private var knownLastSMSIDs: [String: Int] = [:]
    private var hasSMSBaseline = false

    var selectedContact: SMSContact? { contacts.first { $0.id == selectedContactID } }
    var smsEnabled: Bool { appliance?.workMode.smsEnabled ?? true }
    var managedHardware: [ManagedHardwareStatus] {
        let ufiStatus: ManagedHardwareAvailability
        if phase == .connected || phase == .loginRequired, let endpoint {
            ufiStatus = .connected("通过 \(endpoint.host ?? endpoint.absoluteString) 直接管理")
        } else {
            ufiStatus = .notConnected("连接设备 USB 网络或 Wi-Fi 后可直接管理")
        }
        return [
            ManagedHardwareStatus(kind: .ufi103s, availability: ufiStatus),
            ManagedHardwareStatus(
                kind: .djiQDC507,
                availability: .macRelayRequired("iOS 无法直接读取 USB AT 与音频；请由 Mac WiSiM 识别并中继")
            ),
        ]
    }

    deinit { refreshLoop?.cancel() }

    func start() async {
        guard phase == .idle else { return }
        await discover()
    }

    func discover() async {
        phase = .discovering
        errorMessage = nil
        for pass in 0..<2 {
            for raw in ManagementEndpoint.defaults {
                guard let url = try? ManagementEndpoint.normalize(raw) else { continue }
                do {
                    let probe = MobileAPIClient(baseURL: url, timeout: 3)
                    let detected = try await probe.capabilities()
                    await prepareConnection(url: url, detected: detected, client: probe)
                    return
                } catch { continue }
            }
            if pass == 0 { try? await Task.sleep(for: .milliseconds(700)) }
        }
        phase = .failed("未找到可直接管理的 UFI。大疆 QDC507 已纳入支持范围，但 iOS 无法直接读取它的 USB AT 与音频，需要 Mac WiSiM 中继。")
    }

    func connect(to rawEndpoint: String) async {
        phase = .discovering
        do {
            let url = try ManagementEndpoint.normalize(rawEndpoint)
            let probe = MobileAPIClient(baseURL: url)
            let detected = try await probe.capabilities()
            await prepareConnection(url: url, detected: detected, client: probe)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func login(username: String, password: String) async -> Bool {
        guard let client else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await client.login(username: username, password: password)
            await client.setBearerToken(result.token)
            phase = .connected
            await refreshAll()
            startRefreshLoop()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshAll() async {
        await refreshOverview()
        await refreshContacts()
    }

    func refreshOverview() async {
        guard let client else { return }
        do {
            async let status = client.applianceStatus()
            async let attached = client.devices()
            appliance = try await status
            devices = try await attached
        } catch { handle(error) }
    }

    func refreshContacts() async {
        guard let client else { return }
        do {
            let updated = try await client.contacts()
            notifyNewMessages(in: updated)
            contacts = updated
            if let id = selectedContactID, !updated.contains(where: { $0.id == id }) {
                selectedContactID = nil
                messages = []
            }
        } catch { handle(error) }
    }

    func selectContact(_ contact: SMSContact) async {
        selectedContactID = contact.id
        guard let client else { return }
        do { messages = try await client.thread(for: contact) }
        catch { handle(error) }
    }

    func sendSMS(phone: String, message: String, contact: SMSContact?) async -> Bool {
        guard let client else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.sendSMS(phone: phone, message: message, contact: contact)
            showNotice("短信已提交")
            try? await Task.sleep(for: .milliseconds(500))
            await refreshContacts()
            if let contact { await selectContact(contact) }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func deleteMessage(_ message: SMSMessage) async {
        guard let client, let contact = selectedContact else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.deleteMessage(id: message.id)
            await selectContact(contact)
            await refreshContacts()
            showNotice("短信已删除")
        } catch { handle(error) }
    }

    func switchWorkMode(_ mode: WorkMode) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.switchWorkMode(mode)
            showNotice("已提交切换到\(mode.title)")
            try? await Task.sleep(for: .seconds(2))
            await refreshOverview()
        } catch { handle(error) }
    }

    private func prepareConnection(url: URL, detected: Capabilities, client: MobileAPIClient) async {
        self.endpoint = url
        self.capabilities = detected
        self.client = client
        if detected.authRequired {
            phase = .loginRequired
        } else {
            phase = .connected
            await requestNotifications()
            await refreshAll()
            startRefreshLoop()
        }
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) }
                catch { return }
                await self?.refreshContacts()
                await self?.refreshOverview()
            }
        }
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func notifyNewMessages(in updated: [SMSContact]) {
        defer {
            knownLastSMSIDs = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0.lastSMSID) })
            hasSMSBaseline = true
        }
        guard hasSMSBaseline else { return }
        for contact in updated where contact.lastSMSID > (knownLastSMSIDs[contact.id] ?? 0) {
            let content = UNMutableNotificationContent()
            content.title = "WiSiM 新短信"
            content.body = "\(contact.peer)：\(contact.lastContent)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "sms-\(contact.lastSMSID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        if let apiError = error as? APIClientError, apiError == .unauthorized {
            phase = .loginRequired
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.notice == text { self?.notice = nil }
        }
    }
}
