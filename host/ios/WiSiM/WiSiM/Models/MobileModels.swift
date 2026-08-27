import Foundation

enum EndpointError: LocalizedError, Equatable {
    case invalid, unsupportedScheme, unsupportedHost, credentialsNotAllowed, pathNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalid: return "管理地址无效"
        case .unsupportedScheme: return "管理地址只支持 HTTP 或 HTTPS"
        case .unsupportedHost: return "只允许连接 WiSiM 支持的本地管理地址"
        case .credentialsNotAllowed: return "管理地址不能包含用户名或密码"
        case .pathNotAllowed: return "管理地址不能包含额外路径、查询参数或片段"
        }
    }
}

enum ManagedHardwareKind: String, CaseIterable, Identifiable, Sendable {
    case ufi103s
    case djiQDC507

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ufi103s: return "UFI103S"
        case .djiQDC507: return "大疆 QDC507"
        }
    }

    var symbol: String {
        switch self {
        case .ufi103s: return "simcard.2"
        case .djiQDC507: return "antenna.radiowaves.left.and.right"
        }
    }
}

enum ManagedHardwareAvailability: Equatable, Sendable {
    case connected(String)
    case notConnected(String)
    case macRelayRequired(String)

    var title: String {
        switch self {
        case .connected: return "已连接"
        case .notConnected: return "未连接"
        case .macRelayRequired: return "需要 Mac 中继"
        }
    }

    var detail: String {
        switch self {
        case let .connected(detail), let .notConnected(detail), let .macRelayRequired(detail):
            return detail
        }
    }
}

struct ManagedHardwareStatus: Identifiable, Equatable, Sendable {
    let kind: ManagedHardwareKind
    let availability: ManagedHardwareAvailability
    var id: ManagedHardwareKind { kind }
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
              let host = components.host
        else { throw EndpointError.invalid }
        guard scheme == "http" || scheme == "https" else { throw EndpointError.unsupportedScheme }
        guard allowedHosts.contains(host.lowercased()) else { throw EndpointError.unsupportedHost }
        guard components.user == nil, components.password == nil else { throw EndpointError.credentialsNotAllowed }
        guard components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw EndpointError.pathNotAllowed }
        components.scheme = scheme
        components.path = ""
        guard let url = components.url else { throw EndpointError.invalid }
        return url
    }
}

enum WorkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dual, data, sms
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

struct Capabilities: Decodable, Sendable {
    let status: String
    let authRequired: Bool
    let accessMode: String
    let workModes: [WorkMode]
    enum CodingKeys: String, CodingKey {
        case status
        case authRequired = "auth_required"
        case accessMode = "access_mode"
        case workModes = "work_modes"
    }
}

struct WorkModeStatus: Decodable, Sendable {
    let mode: WorkMode
    let transition: String
    let dataEnabled: Bool
    let smsEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case mode, transition
        case dataEnabled = "data_enabled"
        case smsEnabled = "sms_enabled"
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
    let level: String
    let maximumC: Double?
    let warningC: Double
    let criticalC: Double
    let sensors: [ThermalSensor]
    enum CodingKeys: String, CodingKey {
        case level, sensors
        case maximumC = "maximum_c"
        case warningC = "warning_c"
        case criticalC = "critical_c"
    }
}

struct ApplianceStatus: Decodable, Sendable {
    let wifiSSID: String
    let uplinkMode: String
    let workMode: WorkModeStatus
    let thermal: ThermalStatus
    let accessMode: String
    let authRequired: Bool
    let vohiveActive: Bool
    let systemTime: String
    enum CodingKeys: String, CodingKey {
        case thermal
        case wifiSSID = "wifi_ssid"
        case uplinkMode = "uplink_mode"
        case workMode = "work_mode"
        case accessMode = "access_mode"
        case authRequired = "auth_required"
        case vohiveActive = "vohive_active"
        case systemTime = "system_time"
    }
}

struct ModemStatus: Decodable, Sendable {
    let iccid: String?
    let imsi: String?
    let operatorName: String?
    let networkMode: String?
    let signalDBM: Int?
    enum CodingKeys: String, CodingKey {
        case iccid, imsi
        case operatorName = "operator"
        case networkMode = "network_mode"
        case signalDBM = "signal_dbm"
    }
}

struct ManagedDevice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let healthy: Bool
    let networkConnected: Bool
    let networkEnabled: Bool
    let smsEnabled: Bool
    let publicIP: String?
    let modem: ModemStatus?
    enum CodingKeys: String, CodingKey {
        case id, name, healthy, modem
        case networkConnected = "network_connected"
        case networkEnabled = "network_enabled"
        case smsEnabled = "sms_enabled"
        case publicIP = "public_ip"
    }
}

struct ManagedDevicesResponse: Decodable, Sendable { let devices: [ManagedDevice] }

struct SMSContact: Decodable, Identifiable, Hashable, Sendable {
    let imsi: String
    let peer: String
    let deviceID: String?
    let lastSMSID: Int
    let lastTimestamp: String
    let lastContent: String
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
        case unreadCount = "unread_count"
        case deviceName = "device_name"
        case localPhone = "local_phone"
    }
}

struct SMSMessage: Decodable, Identifiable, Sendable {
    let id: Int
    let content: String
    let type: Int
    let status: Int?
    let timestamp: String
    var outgoing: Bool { type == 2 }
}

struct LoginResponse: Decodable, Sendable { let status: String; let token: String }
struct SendSMSResponse: Decodable, Sendable { let status: String }
struct GenericStatusResponse: Decodable, Sendable { let status: String? }

enum VoiceSupport: Equatable, Sendable {
    case unsupported(String)
    case needsMacRelay(String)
    case ready

    var title: String {
        switch self {
        case .unsupported: return "不支持"
        case .needsMacRelay: return "需要 Mac 中继"
        case .ready: return "可用"
        }
    }
    var detail: String {
        switch self {
        case let .unsupported(reason), let .needsMacRelay(reason): return reason
        case .ready: return "信令与双向音频链路均已验证"
        }
    }
}
