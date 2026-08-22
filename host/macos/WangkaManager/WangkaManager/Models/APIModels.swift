import Foundation

enum EndpointError: LocalizedError, Equatable {
    case invalid
    case unsupportedScheme
    case unsupportedHost
    case credentialsNotAllowed
    case pathNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalid: return "管理地址无效"
        case .unsupportedScheme: return "管理地址只支持 HTTP 或 HTTPS"
        case .unsupportedHost: return "只允许连接设备的 USB 或 Wi-Fi 管理地址"
        case .credentialsNotAllowed: return "管理地址不能包含用户名或密码"
        case .pathNotAllowed: return "管理地址不能包含额外路径、查询参数或片段"
        }
    }
}

enum ManagementEndpoint {
    static let defaults = ["http://192.168.5.1", "http://192.168.4.1"]
    private static let allowedHosts = Set(["192.168.5.1", "192.168.4.1"])

    static func normalize(_ rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw EndpointError.invalid }
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else { throw EndpointError.invalid }
        guard scheme == "http" || scheme == "https" else {
            throw EndpointError.unsupportedScheme
        }
        guard allowedHosts.contains(host.lowercased()) else {
            throw EndpointError.unsupportedHost
        }
        guard components.user == nil && components.password == nil else {
            throw EndpointError.credentialsNotAllowed
        }
        guard components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw EndpointError.pathNotAllowed }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { throw EndpointError.invalid }
        return result
    }
}

enum WorkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dual
    case data
    case sms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dual: return "双模式"
        case .data: return "网卡模式"
        case .sms: return "短信模式"
        }
    }

    var detail: String {
        switch self {
        case .dual: return "上网与短信同时运行"
        case .data: return "上网运行，短信引擎停用"
        case .sms: return "短信运行，蜂窝数据停用"
        }
    }

    var symbol: String {
        switch self {
        case .dual: return "arrow.triangle.branch"
        case .data: return "network"
        case .sms: return "message.fill"
        }
    }
}

enum UplinkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case deviceUplink = "device-uplink"
    case hostUplink = "host-uplink"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deviceUplink: return "设备上网"
        case .hostUplink: return "USB 反向共享"
        }
    }

    var detail: String {
        switch self {
        case .deviceUplink: return "设备使用 SIM 网络，并通过 Wi-Fi 或 USB 共享"
        case .hostUplink: return "设备通过 USB 使用 Mac 提供的网络"
        }
    }
}

struct Capabilities: Decodable, Sendable {
    let status: String
    let authRequired: Bool
    let accessMode: String
    let workModes: [WorkMode]
    let keychainUsed: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case authRequired = "auth_required"
        case accessMode = "access_mode"
        case workModes = "work_modes"
        case keychainUsed = "keychain_used"
    }
}

struct WorkModeStatus: Decodable, Sendable {
    let status: String
    let mode: WorkMode
    let transition: String
    let dataEnabled: Bool
    let smsEnabled: Bool
    let lastResult: String
    let lastError: String
    let changedAt: Int

    var transitionMode: WorkMode? { WorkMode(rawValue: transition) }

    enum CodingKeys: String, CodingKey {
        case status, mode, transition
        case dataEnabled = "data_enabled"
        case smsEnabled = "sms_enabled"
        case lastResult = "last_result"
        case lastError = "last_error"
        case changedAt = "changed_at"
    }
}

struct ThermalSensor: Decodable, Identifiable, Sendable {
    let name: String
    let temperatureC: Double
    let level: String
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, level
        case temperatureC = "temperature_c"
    }
}

struct ThermalStatus: Decodable, Sendable {
    let status: String
    let level: String
    let maximumC: Double?
    let warningC: Double
    let criticalC: Double
    let sensors: [ThermalSensor]

    enum CodingKeys: String, CodingKey {
        case status, level, sensors
        case maximumC = "maximum_c"
        case warningC = "warning_c"
        case criticalC = "critical_c"
    }
}

struct ApplianceStatus: Decodable, Sendable {
    let initialized: Bool
    let generation: Int
    let wifiSSID: String
    let uplinkMode: String
    let workMode: WorkModeStatus
    let thermal: ThermalStatus
    let accessMode: String
    let authRequired: Bool
    let vohiveActive: Bool
    let systemTime: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case initialized, generation, thermal, timezone
        case wifiSSID = "wifi_ssid"
        case uplinkMode = "uplink_mode"
        case workMode = "work_mode"
        case accessMode = "access_mode"
        case authRequired = "auth_required"
        case vohiveActive = "vohive_active"
        case systemTime = "system_time"
    }
}

struct DashboardDevice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String?
    let healthy: Bool
    let operatorName: String?
    let networkMode: String?
    let signalDBM: Int?
    let publicIP: String?
    let networkConnected: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, healthy
        case operatorName = "operator"
        case networkMode = "network_mode"
        case signalDBM = "signal_dbm"
        case publicIP = "public_ip"
        case networkConnected = "network_connected"
    }
}

enum TrafficRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var periodTitle: String {
        switch self {
        case .day: return "本日"
        case .week: return "本周"
        case .month: return "本月"
        }
    }
}

struct TrafficBucket: Decodable, Identifiable, Sendable {
    let bucket: String
    let receivedBytes: Double
    let transmittedBytes: Double
    let totalBytes: Double

    var id: String { bucket }

    enum CodingKeys: String, CodingKey {
        case bucket
        case receivedBytes = "rx_bytes"
        case transmittedBytes = "tx_bytes"
        case totalBytes = "total_bytes"
    }
}

struct TrafficChart: Decodable, Sendable {
    let timestamps: [String]
    let devices: [String]
    let series: [String: [Double]]
}

struct TrafficAnalysis: Decodable, Sendable {
    let buckets: [TrafficBucket]
    let chart: TrafficChart?

    static let empty = TrafficAnalysis(buckets: [], chart: nil)

    var receivedBytes: Double { buckets.reduce(0) { $0 + $1.receivedBytes } }
    var transmittedBytes: Double { buckets.reduce(0) { $0 + $1.transmittedBytes } }
    var totalBytes: Double { receivedBytes + transmittedBytes }
}

struct ModemStatus: Decodable, Sendable {
    let imei: String?
    let iccid: String?
    let imsi: String?
    let nativeSPN: String?
    let nativeMCC: String?
    let nativeMNC: String?
    let firmware: String?
    let operatorName: String?
    let networkMode: String?
    let networkDuplex: String?
    let radioBand: String?
    let radioChannel: Int?
    let apn: String?
    let signalDBM: Int?
    let signalRSRP: Int?
    let signalRSRQ: Int?
    let signalSINR: Int?
    let registrationStatus: Int?
    let registrationText: String?
    let operatingMode: Int?

    enum CodingKeys: String, CodingKey {
        case imei, iccid, imsi, firmware, apn
        case nativeSPN = "native_spn"
        case nativeMCC = "native_mcc"
        case nativeMNC = "native_mnc"
        case operatorName = "operator"
        case networkMode = "network_mode"
        case networkDuplex = "network_duplex"
        case radioBand = "radio_band"
        case radioChannel = "radio_channel"
        case signalDBM = "signal_dbm"
        case signalRSRP = "signal_rsrp"
        case signalRSRQ = "signal_rsrq"
        case signalSINR = "signal_sinr"
        case registrationStatus = "reg_status"
        case registrationText = "reg_status_text"
        case operatingMode = "operating_mode"
    }
}

struct ManagedDevice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let running: Bool
    let healthy: Bool
    let networkConnected: Bool
    let networkEnabled: Bool
    let smsEnabled: Bool
    let registrationState: String?
    let publicIP: String?
    let interface: String?
    let lifecyclePhase: String?
    let lifecycleReason: String?
    let modem: ModemStatus?

    enum CodingKeys: String, CodingKey {
        case id, name, running, healthy, interface, modem
        case networkConnected = "network_connected"
        case networkEnabled = "network_enabled"
        case smsEnabled = "sms_enabled"
        case registrationState = "registration_state_label"
        case publicIP = "public_ip"
        case lifecyclePhase = "lifecycle_phase"
        case lifecycleReason = "lifecycle_reason"
    }
}

struct ManagedDevicesResponse: Decodable, Sendable {
    let devices: [ManagedDevice]
    let deviceLimit: Int?

    enum CodingKeys: String, CodingKey {
        case devices
        case deviceLimit = "device_limit"
    }
}

struct DeviceTrafficFormatted: Decodable, Sendable {
    let transmitted: String?
    let received: String?
    let rate: String?
    let connections: String?
    let activeConnections: String?

    enum CodingKeys: String, CodingKey {
        case transmitted = "tx"
        case received = "rx"
        case rate, connections
        case activeConnections = "active_conns"
    }
}

struct DeviceDetail: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let running: Bool
    let healthy: Bool
    let networkConnected: Bool
    let networkEnabled: Bool
    let registrationState: String?
    let privateIP: String?
    let publicIP: String?
    let localPhone: String?
    let interface: String?
    let lifecyclePhase: String?
    let lifecycleReason: String?
    let modem: ModemStatus?
    let traffic: DeviceTrafficFormatted?

    var flightModeEnabled: Bool {
        guard let mode = modem?.operatingMode else { return false }
        return mode == 0 || mode == 4
    }

    enum CodingKeys: String, CodingKey {
        case id, name, running, healthy, interface, modem, traffic
        case networkConnected = "network_connected"
        case networkEnabled = "network_enabled"
        case registrationState = "registration_state_label"
        case privateIP = "private_ip"
        case publicIP = "public_ip"
        case localPhone = "local_phone"
        case lifecyclePhase = "lifecycle_phase"
        case lifecycleReason = "lifecycle_reason"
    }
}

struct DeviceOverviewResponse: Decodable, Sendable {
    let devices: [DeviceDetail]
}

struct DeviceNetworkResponse: Decodable, Sendable {
    let networkConnected: Bool?
    let privateIP: String?
    let publicIP: String?

    enum CodingKeys: String, CodingKey {
        case networkConnected = "network_connected"
        case privateIP = "private_ip"
        case publicIP = "public_ip"
    }
}

struct FlightModeResponse: Decodable, Sendable {
    let operatingMode: Int?
    let flightMode: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case operatingMode = "operating_mode"
        case flightMode = "flight_mode"
        case message
    }
}

struct GenericStatusResponse: Decodable, Sendable {
    let status: String?
    let message: String?
}

struct NotificationSettings: Codable, Equatable, Sendable {
    var telegram = TelegramNotificationSettings()
    var feishu = FeishuNotificationSettings()
    var qq = QQNotificationSettings()
    var email = EmailNotificationSettings()
    var pushplus = PushPlusNotificationSettings()
    var webhook = WebhookNotificationSettings()
    var bark = BarkNotificationSettings()

    static let empty = NotificationSettings()

    enum CodingKeys: String, CodingKey {
        case telegram, feishu, qq, email, pushplus, webhook, bark
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        telegram = try container.decodeIfPresent(TelegramNotificationSettings.self, forKey: .telegram) ?? .init()
        feishu = try container.decodeIfPresent(FeishuNotificationSettings.self, forKey: .feishu) ?? .init()
        qq = try container.decodeIfPresent(QQNotificationSettings.self, forKey: .qq) ?? .init()
        email = try container.decodeIfPresent(EmailNotificationSettings.self, forKey: .email) ?? .init()
        pushplus = try container.decodeIfPresent(PushPlusNotificationSettings.self, forKey: .pushplus) ?? .init()
        webhook = try container.decodeIfPresent(WebhookNotificationSettings.self, forKey: .webhook) ?? .init()
        bark = try container.decodeIfPresent(BarkNotificationSettings.self, forKey: .bark) ?? .init()
    }
}

struct TelegramNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var botToken = ""
    var chatID: Int64 = 0
    var adminID: Int64 = 0
    var baseURL = ""
    var proxy = ""

    enum CodingKeys: String, CodingKey {
        case enabled
        case botToken = "bot_token"
        case chatID = "chat_id"
        case adminID = "admin_id"
        case baseURL = "base_url"
        case proxy
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        botToken = try container.decodeIfPresent(String.self, forKey: .botToken) ?? ""
        chatID = try container.decodeIfPresent(Int64.self, forKey: .chatID) ?? 0
        adminID = try container.decodeIfPresent(Int64.self, forKey: .adminID) ?? 0
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        proxy = try container.decodeIfPresent(String.self, forKey: .proxy) ?? ""
    }
}

struct FeishuNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var appID = ""
    var appSecret = ""
    var chatIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case enabled
        case appID = "app_id"
        case appSecret = "app_secret"
        case chatIDs = "chat_ids"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
        appSecret = try container.decodeIfPresent(String.self, forKey: .appSecret) ?? ""
        chatIDs = try container.decodeIfPresent([String].self, forKey: .chatIDs) ?? []
    }
}

struct QQNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var appID = ""
    var appSecret = ""
    var groupIDs = ""
    var directIDs = ""

    enum CodingKeys: String, CodingKey {
        case enabled
        case appID = "app_id"
        case appSecret = "app_secret"
        case groupIDs = "group_ids"
        case directIDs = "direct_ids"
    }

    init() {}
}

struct EmailNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var useSSL = true
    var smtpHost = ""
    var smtpPort = 465
    var username = ""
    var password = ""
    var fromAddress = ""
    var toAddresses: [String] = []

    enum CodingKeys: String, CodingKey {
        case enabled
        case useSSL = "use_ssl"
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case username, password
        case fromAddress = "from_address"
        case toAddresses = "to_addresses"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        useSSL = try container.decodeIfPresent(Bool.self, forKey: .useSSL) ?? true
        smtpHost = try container.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 465
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        fromAddress = try container.decodeIfPresent(String.self, forKey: .fromAddress) ?? ""
        toAddresses = try container.decodeIfPresent([String].self, forKey: .toAddresses) ?? []
    }
}

struct PushPlusNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var token = ""
    var topic = ""
    var channel = ""

    init() {}
}

struct WebhookNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var urls: [String] = []
    var secret = ""
    var timeoutMs = 10_000
    var retryMax = 2
    var textTemplate = ""
    var headers: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case enabled, urls, secret, headers
        case timeoutMs = "timeout_ms"
        case retryMax = "retry_max"
        case textTemplate = "text_template"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        secret = try container.decodeIfPresent(String.self, forKey: .secret) ?? ""
        timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 10_000
        retryMax = try container.decodeIfPresent(Int.self, forKey: .retryMax) ?? 2
        textTemplate = try container.decodeIfPresent(String.self, forKey: .textTemplate) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

struct BarkNotificationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var urls: [String] = []
    var group = ""
    var icon = ""
    var level = "active"

    enum CodingKeys: String, CodingKey {
        case enabled, urls, group, icon, level
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
        level = try container.decodeIfPresent(String.self, forKey: .level) ?? "active"
    }
}

struct NotificationSaveResponse: Decodable, Sendable {
    let status: String?
    let applied: Bool?
    let warning: String?
}

struct SMSContact: Decodable, Identifiable, Hashable, Sendable {
    let imsi: String
    let peer: String
    let deviceID: String?
    let lastSMSID: Int
    let lastTimestamp: String
    let lastContent: String
    let lastType: Int?
    let unreadCount: Int
    let deviceName: String?
    let localPhone: String?

    var id: String { "\(imsi)|\(peer)" }

    enum CodingKeys: String, CodingKey {
        case imsi, peer
        case deviceID = "device_id"
        case lastSMSID = "last_sms_id"
        case lastTimestamp = "last_timestamp"
        case lastContent = "last_content"
        case lastType = "last_type"
        case unreadCount = "unread_count"
        case deviceName = "device_name"
        case localPhone = "local_phone"
    }
}

struct SMSMessage: Decodable, Identifiable, Sendable {
    let id: Int
    let imsi: String?
    let peer: String?
    let sender: String
    let recipient: String?
    let content: String
    let type: Int
    let status: Int?
    let timestamp: String
    let deviceName: String?

    var outgoing: Bool { type == 2 }

    enum CodingKeys: String, CodingKey {
        case id, imsi, peer, sender, recipient, content, type, status, timestamp
        case deviceName = "device_name"
    }
}

struct LogEntry: Decodable, Identifiable, Sendable {
    let time: String
    let level: String
    let caller: String
    let message: String
    let fields: String?
    var id: String { "\(time)|\(caller)|\(message)|\(fields ?? "")" }
}

struct LoginResponse: Decodable, Sendable {
    let status: String
    let token: String
}

struct AccessModeResponse: Decodable, Sendable {
    let status: String
    let accessMode: String
    let authRequired: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case accessMode = "access_mode"
        case authRequired = "auth_required"
    }
}

struct UplinkModeResponse: Decodable, Sendable {
    let status: String
    let mode: String
}

struct CredentialUpdateResponse: Decodable, Sendable {
    let status: String
    let initialized: Bool?
}

struct SendSMSResponse: Decodable, Sendable {
    let status: String
    let messageID: String?
    let partsTotal: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case messageID = "message_id"
        case partsTotal = "parts_total"
    }
}

struct DeleteSMSMessageResponse: Decodable, Sendable {
    let status: String
    let threadEmpty: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case threadEmpty = "thread_empty"
    }
}

struct DeleteSMSThreadResponse: Decodable, Sendable {
    let status: String
    let deleted: Int
}

struct LogsResponse: Decodable, Sendable {
    let logs: [LogEntry]
}

struct APIErrorPayload: Decodable {
    let message: String?
    let error: String?
}
