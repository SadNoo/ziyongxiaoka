import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(status: Int, message: String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "接口地址无效"
        case .invalidResponse: return "设备返回了无效响应"
        case .unauthorized: return "登录已失效，请重新登录"
        case let .server(_, message): return message
        case .decoding: return "设备返回的数据格式不兼容"
        }
    }
}

final class APIClient {
    let baseURL: URL
    private let session: URLSession
    private var bearerToken: String?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let workModePollAttempts: Int
    private let workModePollDelayNanoseconds: UInt64

    init(
        baseURL: URL,
        session: URLSession? = nil,
        workModePollAttempts: Int = 75,
        workModePollDelayNanoseconds: UInt64 = 2_000_000_000,
        requestTimeout: TimeInterval = 12,
        resourceTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.workModePollAttempts = max(workModePollAttempts, 1)
        self.workModePollDelayNanoseconds = workModePollDelayNanoseconds
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = resourceTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func setBearerToken(_ token: String?) {
        bearerToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if bearerToken?.isEmpty == true { bearerToken = nil }
    }

    func clearCredentials() {
        bearerToken = nil
    }

    func capabilities() async throws -> Capabilities {
        try await get("/wangka/api/capabilities")
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        struct Body: Encodable { let username: String; let password: String }
        return try await post("/api/auth/login", body: Body(username: username, password: password))
    }

    func applianceStatus() async throws -> ApplianceStatus {
        try await get("/wangka/api/status")
    }

    func dashboardDevices() async throws -> [DashboardDevice] {
        try await get("/api/dashboard/devices")
    }

    func trafficAnalysis(range: TrafficRange, deviceID: String? = nil) async throws -> TrafficAnalysis {
        var query = [URLQueryItem(name: "range", value: range.rawValue)]
        if let deviceID, !deviceID.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        return try await get("/api/traffic/analysis", query: query)
    }

    func managedDevices() async throws -> ManagedDevicesResponse {
        try await get("/api/devices")
    }

    func deviceOverview(id: String) async throws -> DeviceDetail? {
        let response: DeviceOverviewResponse = try await get("/api/devices/\(id)/overview")
        return response.devices.first
    }

    func refreshDevice(id: String) async throws {
        let _: GenericStatusResponse = try await post("/api/devices/\(id)/actions/refresh", body: EmptyBody())
    }

    func setDeviceNetwork(id: String, enabled: Bool) async throws -> DeviceNetworkResponse {
        struct Body: Encodable { let enabled: Bool }
        return try await patch("/api/devices/\(id)/network", body: Body(enabled: enabled))
    }

    func setFlightMode(id: String, enabled: Bool) async throws -> FlightModeResponse {
        struct Body: Encodable { let enabled: Bool }
        return try await patch("/api/devices/\(id)/flight-mode", body: Body(enabled: enabled))
    }

    func rotateDeviceIP(id: String) async throws {
        struct Body: Encodable {
            let deviceID: String
            enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
        }
        let _: GenericStatusResponse = try await post("/api/rotateip", body: Body(deviceID: id))
    }

    func notificationSettings() async throws -> NotificationSettings {
        try await get("/api/settings/notifications")
    }

    func saveNotificationSettings(_ settings: NotificationSettings) async throws -> NotificationSaveResponse {
        try await put("/api/settings/notifications", body: settings)
    }

    func switchWorkMode(_ mode: WorkMode) async throws -> WorkModeStatus {
        struct Body: Encodable { let mode: String }
        var submittedError: Error?
        do {
            let submitted: WorkModeStatus = try await post(
                "/wangka/api/work-mode",
                body: Body(mode: mode.rawValue)
            )
            if workModeSettled(submitted, at: mode) { return submitted }
        } catch {
            guard shouldRecoverWorkModeSwitch(from: error) else { throw error }
            submittedError = error
        }

        for attempt in 0..<workModePollAttempts {
            if attempt > 0 && workModePollDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: workModePollDelayNanoseconds)
            }
            let status: WorkModeStatus
            do {
                status = try await applianceStatus().workMode
            } catch let error as APIClientError where error == .unauthorized {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The management service or USB link may still be restarting.
                // Continue polling until the bounded recovery window expires.
                continue
            }
            if workModeSettled(status, at: mode) { return status }
            if status.transitionMode == nil,
               status.mode != mode,
               status.lastResult == "rolled-back"
            {
                throw submittedError ?? APIClientError.server(
                    status: 500,
                    message: status.lastError.isEmpty ? "工作模式切换已回滚" : status.lastError
                )
            }
        }
        throw submittedError ?? APIClientError.server(
            status: 504,
            message: "模式切换后未能确认设备最终状态"
        )
    }

    func updateLED(enabled: Bool, nightMode: Bool) async throws -> LEDStatus {
        struct Body: Encodable {
            let enabled: Bool
            let nightMode: Bool

            enum CodingKeys: String, CodingKey {
                case enabled
                case nightMode = "night_mode"
            }
        }
        return try await post(
            "/wangka/api/led",
            body: Body(enabled: enabled, nightMode: nightMode)
        )
    }

    func setAccessMode(_ mode: String) async throws -> AccessModeResponse {
        struct Body: Encodable { let mode: String }
        return try await post("/wangka/api/access-mode", body: Body(mode: mode))
    }

    func switchUplinkMode(_ mode: UplinkMode) async throws -> UplinkModeResponse {
        struct Body: Encodable { let mode: String }
        return try await post("/wangka/api/uplink", body: Body(mode: mode.rawValue))
    }

    func updateWiFi(ssid: String, password: String) async throws -> CredentialUpdateResponse {
        struct Body: Encodable {
            let targets: [String]
            let newPassword: String
            let confirmPassword: String
            let currentVoHivePassword: String
            let wifiSSID: String

            enum CodingKeys: String, CodingKey {
                case targets
                case newPassword = "new_password"
                case confirmPassword = "confirm_password"
                case currentVoHivePassword = "current_vohive_password"
                case wifiSSID = "wifi_ssid"
            }
        }
        return try await post(
            "/wangka/api/credentials",
            body: Body(
                targets: ["wifi"],
                newPassword: password,
                confirmPassword: password,
                currentVoHivePassword: "",
                wifiSSID: ssid
            )
        )
    }

    func contacts() async throws -> [SMSContact] {
        try await get("/api/sms/contacts", query: [
            URLQueryItem(name: "limit", value: "200")
        ])
    }

    func thread(for contact: SMSContact) async throws -> [SMSMessage] {
        var query = [
            URLQueryItem(name: "peer", value: contact.peer),
            URLQueryItem(name: "limit", value: "200")
        ]
        // The contacts endpoint is an all-device view. Query the matching
        // thread by IMSI as the upstream web UI does; resolving it through a
        // currently attached device can point at a different ICCID after a
        // SIM swap and produce an empty conversation.
        if !contact.imsi.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: "all"))
            query.append(URLQueryItem(name: "imsi", value: contact.imsi))
        } else if let deviceID = contact.deviceID, !deviceID.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        return try await get("/api/sms/thread", query: query)
    }

    func sendSMS(phone: String, message: String, contact: SMSContact?) async throws -> SendSMSResponse {
        struct Body: Encodable {
            let deviceID: String?
            let imsi: String?
            let phone: String
            let message: String

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case imsi, phone, message
            }
        }
        return try await post(
            "/api/sms/send",
            body: Body(deviceID: contact?.deviceID, imsi: contact?.imsi, phone: phone, message: message)
        )
    }

    func deleteSMSMessage(id: Int) async throws -> DeleteSMSMessageResponse {
        guard id > 0 else { throw APIClientError.invalidURL }
        return try await delete("/api/sms/messages/\(id)")
    }

    func deleteSMSThread(for contact: SMSContact) async throws -> DeleteSMSThreadResponse {
        var query = [URLQueryItem(name: "peer", value: contact.peer)]
        if !contact.imsi.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: "all"))
            query.append(URLQueryItem(name: "imsi", value: contact.imsi))
        } else if let deviceID = contact.deviceID, !deviceID.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        return try await delete("/api/sms/thread", query: query)
    }

    func logs(lines: Int = 500) async throws -> [LogEntry] {
        let response: LogsResponse = try await get("/api/logs/history", query: [
            URLQueryItem(name: "lines", value: String(min(max(lines, 1), 2_000)))
        ])
        return response.logs
    }

    private func workModeSettled(_ status: WorkModeStatus, at target: WorkMode) -> Bool {
        status.mode == target
            && status.transitionMode == nil
            && status.lastResult != "switching"
            && status.lastResult != "rolled-back"
    }

    private func shouldRecoverWorkModeSwitch(from error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        guard let apiError = error as? APIClientError else { return false }
        switch apiError {
        case .invalidResponse, .decoding:
            return true
        case let .server(status, _):
            return status == 409 || status >= 500
        case .invalidURL, .unauthorized:
            return false
        }
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await perform(method: "GET", path: path, query: query, body: nil)
    }

    private func post<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(method: "POST", path: path, query: [], body: data)
    }

    private func put<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(method: "PUT", path: path, query: [], body: data)
    }

    private func patch<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(method: "PATCH", path: path, query: [], body: data)
    }

    private func delete<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await perform(method: "DELETE", path: path, query: query, body: nil)
    }

    private func perform<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Response {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw APIClientError.invalidURL }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if http.statusCode == 401 { throw APIClientError.unauthorized }
        guard 200..<300 ~= http.statusCode else {
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            let message = payload?.message ?? payload?.error ?? "设备请求失败（\(http.statusCode)）"
            throw APIClientError.server(status: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }
}

private struct EmptyBody: Encodable {}
