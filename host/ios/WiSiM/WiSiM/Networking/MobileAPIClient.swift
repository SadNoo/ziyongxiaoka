import Foundation

enum APIClientError: LocalizedError, Equatable {
    case invalidURL, invalidResponse, unauthorized, decoding
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "接口地址无效"
        case .invalidResponse: return "设备返回了无效响应"
        case .unauthorized: return "登录已失效，请重新登录"
        case .decoding: return "设备返回的数据格式不兼容"
        case let .server(_, message): return message
        }
    }
}

actor MobileAPIClient {
    let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var bearerToken: String?

    init(baseURL: URL, session: URLSession? = nil, timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout + 4
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func setBearerToken(_ token: String?) { bearerToken = token }
    func capabilities() async throws -> Capabilities { try await get("/wangka/api/capabilities") }
    func applianceStatus() async throws -> ApplianceStatus { try await get("/wangka/api/status") }
    func devices() async throws -> [ManagedDevice] {
        let response: ManagedDevicesResponse = try await get("/api/devices")
        return response.devices
    }
    func contacts() async throws -> [SMSContact] {
        try await get("/api/sms/contacts", query: [URLQueryItem(name: "limit", value: "200")])
    }
    func thread(for contact: SMSContact) async throws -> [SMSMessage] {
        var query = [URLQueryItem(name: "peer", value: contact.peer), URLQueryItem(name: "limit", value: "200")]
        if !contact.imsi.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: "all"))
            query.append(URLQueryItem(name: "imsi", value: contact.imsi))
        } else if let id = contact.deviceID, !id.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: id))
        }
        return try await get("/api/sms/thread", query: query)
    }
    func login(username: String, password: String) async throws -> LoginResponse {
        struct Body: Encodable { let username: String; let password: String }
        return try await post("/api/auth/login", body: Body(username: username, password: password))
    }
    func sendSMS(phone: String, message: String, contact: SMSContact?) async throws -> SendSMSResponse {
        struct Body: Encodable {
            let deviceID: String?
            let imsi: String?
            let phone: String
            let message: String
            enum CodingKeys: String, CodingKey { case deviceID = "device_id"; case imsi, phone, message }
        }
        return try await post(
            "/api/sms/send",
            body: Body(deviceID: contact?.deviceID, imsi: contact?.imsi, phone: phone, message: message)
        )
    }
    func deleteMessage(id: Int) async throws {
        let _: GenericStatusResponse = try await delete("/api/sms/messages/\(id)")
    }
    func switchWorkMode(_ mode: WorkMode) async throws {
        struct Body: Encodable { let mode: String }
        let _: WorkModeStatus = try await post("/wangka/api/work-mode", body: Body(mode: mode.rawValue))
    }

    private func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await perform(method: "GET", path: path, query: query, body: nil)
    }
    private func post<Response: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> Response {
        try await perform(method: "POST", path: path, query: [], body: try encoder.encode(body))
    }
    private func delete<Response: Decodable>(_ path: String) async throws -> Response {
        try await perform(method: "DELETE", path: path, query: [], body: nil)
    }
    private func perform<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Response {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw APIClientError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if http.statusCode == 401 { throw APIClientError.unauthorized }
        guard 200..<300 ~= http.statusCode else {
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = payload?["message"] as? String ?? payload?["error"] as? String ?? "设备请求失败（\(http.statusCode)）"
            throw APIClientError.server(status: http.statusCode, message: message)
        }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw APIClientError.decoding }
    }
}
