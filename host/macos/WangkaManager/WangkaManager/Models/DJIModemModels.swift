import Foundation

struct DJIModemSnapshot: Codable, Equatable, Sendable {
    let status: String
    let version: String
    let device: DJIDeviceInfo
    let sim: DJISIMInfo
    let network: DJINetworkInfo
    let voice: DJIVoiceInfo
    let initialization: DJIInitializationInfo?
    let call: DJICallInfo
    let error: String?
}

struct DJIDeviceInfo: Codable, Equatable, Sendable {
    let id: String
    let family: String
    let vendor: String
    let model: String
    let firmware: String
    let usbID: String
    let imeiSuffix: String?

    enum CodingKeys: String, CodingKey {
        case id, family, vendor, model, firmware
        case usbID = "usb_id"
        case imeiSuffix = "imei_suffix"
    }
}

struct DJISIMInfo: Codable, Equatable, Sendable {
    let state: String
    let iccid: String?

    var label: String {
        switch state {
        case "ready": return "已就绪"
        case "absent": return "未插卡"
        case "pin_required": return "需要 PIN"
        case "unavailable": return "不可用"
        default: return "未知"
        }
    }
}

struct DJINetworkInfo: Codable, Equatable, Sendable {
    let registration: String
    let signalDBM: Int?

    enum CodingKeys: String, CodingKey {
        case registration
        case signalDBM = "signal_dbm"
    }

    var registrationLabel: String {
        switch registration {
        case "registered": return "已注册"
        case "roaming": return "漫游中"
        case "searching": return "搜索网络中"
        case "denied": return "注册被拒绝"
        case "not_registered": return "未注册"
        default: return "未知"
        }
    }
}

struct DJIVoiceInfo: Codable, Equatable, Sendable {
    let hardwareSupported: Bool
    let controlAvailable: Bool
    let adbEnabled: Bool
    let uacEnabled: Bool
    let imsEnabled: Bool
    let volteCapability: Int?
    let volteEnabled: Bool
    let availability: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case availability, reason
        case hardwareSupported = "hardware_supported"
        case controlAvailable = "control_available"
        case adbEnabled = "adb_enabled"
        case uacEnabled = "uac_enabled"
        case imsEnabled = "ims_enabled"
        case volteCapability = "volte_capability"
        case volteEnabled = "volte_enabled"
    }
}

struct DJIInitializationInfo: Codable, Equatable, Sendable {
    let adbUACInitialized: Bool
    let backupAvailable: Bool
    let backupCount: Int
    let latestBackupAt: String?
    let canInitialize: Bool
    let canRestore: Bool
    let state: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case state, reason
        case adbUACInitialized = "adb_uac_initialized"
        case backupAvailable = "backup_available"
        case backupCount = "backup_count"
        case latestBackupAt = "latest_backup_at"
        case canInitialize = "can_initialize"
        case canRestore = "can_restore"
    }
}

struct DJIDeviceOperationResult: Codable, Equatable, Sendable {
    let status: String
    let stage: String
    let message: String?
    let imeiSuffix: String?
    let backupCount: Int?
    let changed: Bool
    let rebootRequested: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, stage, message, changed, error
        case imeiSuffix = "imei_suffix"
        case backupCount = "backup_count"
        case rebootRequested = "reboot_requested"
    }
}

struct DJICallInfo: Codable, Equatable, Sendable {
    let state: String
    let number: String?
    let incoming: Bool
    let active: Bool

    var isIdle: Bool { state == "idle" }

    var label: String {
        switch state {
        case "idle": return "空闲"
        case "incoming": return "来电"
        case "dialing": return "拨号中"
        case "alerting": return "等待接听"
        case "active": return "通话中"
        default: return "状态未知"
        }
    }
}

enum VoiceAvailability: Equatable {
    case unsupported(String)
    case unavailable(String)
    case needsSetup(String)
    case needsRuntime(String)
    case ready

    var title: String {
        switch self {
        case .unsupported: return "不支持"
        case .unavailable: return "暂不可用"
        case .needsSetup: return "需要初始化"
        case .needsRuntime: return "需要语音运行时"
        case .ready: return "可用"
        }
    }

    var detail: String {
        switch self {
        case let .unsupported(reason), let .unavailable(reason), let .needsSetup(reason), let .needsRuntime(reason):
            return reason
        case .ready:
            return "呼叫控制、IMS、USB 音频与主机音频桥均已就绪"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .needsSetup, .needsRuntime: return "wrench.and.screwdriver.fill"
        case .unsupported: return "nosign"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}
