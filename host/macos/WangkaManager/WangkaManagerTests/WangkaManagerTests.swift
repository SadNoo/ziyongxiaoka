import XCTest

final class WangkaManagerTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testEndpointNormalizationUsesHTTPAndRemovesTrailingSlash() throws {
        XCTAssertEqual(
            try ManagementEndpoint.normalize(" 192.168.5.1/ ").absoluteString,
            "http://192.168.5.1"
        )
        XCTAssertEqual(
            try ManagementEndpoint.normalize("HTTPS://192.168.4.1").absoluteString,
            "https://192.168.4.1"
        )
    }

    func testEndpointNormalizationRejectsCredentialsAndPaths() {
        XCTAssertThrowsError(try ManagementEndpoint.normalize("ftp://192.168.5.1")) { error in
            XCTAssertEqual(error as? EndpointError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try ManagementEndpoint.normalize("http://user:pass@192.168.5.1")) { error in
            XCTAssertEqual(error as? EndpointError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(try ManagementEndpoint.normalize("http://192.168.5.1/admin")) { error in
            XCTAssertEqual(error as? EndpointError, .pathNotAllowed)
        }
        XCTAssertThrowsError(try ManagementEndpoint.normalize("https://example.test")) { error in
            XCTAssertEqual(error as? EndpointError, .unsupportedHost)
        }
    }

    func testAutomaticDiscoveryPrefersUSBThenWiFi() {
        XCTAssertEqual(
            ManagementEndpoint.defaults,
            ["http://192.168.5.1", "http://192.168.4.1"]
        )
    }

    func testCapabilitiesDecodeOptionalLoginAndAllModes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/wangka/api/capabilities")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return Self.response(
                for: request,
                json: #"{"status":"ok","auth_required":true,"access_mode":"login-required","work_modes":["dual","data","sms"],"keychain_used":false}"#
            )
        }

        let result = try await client.capabilities()
        XCTAssertTrue(result.authRequired)
        XCTAssertEqual(result.accessMode, "login-required")
        XCTAssertEqual(result.workModes, [.dual, .data, .sms])
        XCTAssertNil(result.ledControl)
        XCTAssertFalse(result.keychainUsed)
    }

    func testLEDSettingsUseDedicatedManagementEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/wangka/api/led")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(object["enabled"] as? Bool, false)
            XCTAssertEqual(object["night_mode"] as? Bool, true)
            return Self.response(
                for: request,
                json: #"{"status":"ok","available":true,"enabled":false,"night_mode":true,"mode_color":"white","mode_color_label":"白色","color":"off","color_label":"熄灭","pattern":"off","pattern_label":"熄灭","meaning":"状态灯已关闭","source":"setting"}"#
            )
        }

        let result = try await client.updateLED(enabled: false, nightMode: true)
        XCTAssertFalse(result.enabled)
        XCTAssertTrue(result.nightMode)
        XCTAssertEqual(result.modeColor, "white")
        XCTAssertEqual(result.currentAppearance, "熄灭")
    }

    func testBearerTokenIsOnlyAddedAfterBeingSet() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return Self.response(
                    for: request,
                    json: #"{"status":"ok","auth_required":false,"access_mode":"trusted-network","work_modes":["dual","data","sms"],"keychain_used":false}"#
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-token")
            return Self.response(for: request, json: Self.statusFixture)
        }

        _ = try await client.capabilities()
        client.setBearerToken("memory-token")
        let status = try await client.applianceStatus()
        XCTAssertEqual(status.workMode.mode, .dual)
        XCTAssertNil(status.workMode.transitionMode)
        XCTAssertEqual(status.thermal.maximumC, 47.5)

        client.clearCredentials()
        XCTAssertEqual(requestCount, 2)
    }

    func testServerMessageIsPreservedForModeConflict() async {
        let client = makeClient { request in
            Self.response(
                for: request,
                status: 409,
                json: #"{"status":"error","message":"当前为网卡模式，短信引擎已停用"}"#
            )
        }

        do {
            _ = try await client.sendSMS(phone: "+999000000000", message: "test", contact: nil)
            XCTFail("request should fail")
        } catch let error as APIClientError {
            XCTAssertEqual(
                error,
                .server(status: 409, message: "当前为网卡模式，短信引擎已停用")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSMSRequestKeepsInternationalNumberAndEncodesJSON() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sms/send")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(object["phone"] as? String, "+999000000000")
            XCTAssertEqual(object["message"] as? String, "hello")
            XCTAssertNil(object["device_id"])
            return Self.response(
                for: request,
                json: #"{"status":"ok","message_id":"","parts_total":1}"#
            )
        }

        let result = try await client.sendSMS(phone: "+999000000000", message: "hello", contact: nil)
        XCTAssertEqual(result.partsTotal, 1)
    }

    func testThreadQueryUsesAllDeviceIMSIPath() async throws {
        let contact = SMSContact(
            imsi: "test-imsi",
            peer: "+999000000000",
            deviceID: "onboard-qmi",
            lastSMSID: 8,
            lastTimestamp: "2026-08-22T05:00:00+08:00",
            lastContent: "hello",
            lastType: 1,
            unreadCount: 1,
            deviceName: "test device",
            localPhone: nil
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sms/thread")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first(where: { $0.name == "device_id" })?.value, "all")
            XCTAssertEqual(items?.first(where: { $0.name == "imsi" })?.value, "test-imsi")
            XCTAssertEqual(items?.first(where: { $0.name == "peer" })?.value, "+999000000000")
            return Self.response(for: request, json: "[]")
        }

        let result = try await client.thread(for: contact)
        XCTAssertTrue(result.isEmpty)
    }

    func testDeleteSingleSMSUsesDeleteEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sms/messages/42")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertNil(request.httpBody)
            return Self.response(
                for: request,
                json: #"{"status":"ok","thread_empty":false,"imsi":"test-imsi","peer":"+999000000000"}"#
            )
        }

        let result = try await client.deleteSMSMessage(id: 42)
        XCTAssertEqual(result.status, "ok")
        XCTAssertFalse(result.threadEmpty)
    }

    func testDeleteThreadUsesAllDeviceIMSIPath() async throws {
        let contact = SMSContact(
            imsi: "test-imsi",
            peer: "+999000000000",
            deviceID: "onboard-qmi",
            lastSMSID: 8,
            lastTimestamp: "2026-08-22T05:00:00+08:00",
            lastContent: "hello",
            lastType: 1,
            unreadCount: 1,
            deviceName: "test device",
            localPhone: nil
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sms/thread")
            XCTAssertEqual(request.httpMethod, "DELETE")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first(where: { $0.name == "device_id" })?.value, "all")
            XCTAssertEqual(items?.first(where: { $0.name == "imsi" })?.value, "test-imsi")
            XCTAssertEqual(items?.first(where: { $0.name == "peer" })?.value, "+999000000000")
            return Self.response(
                for: request,
                json: #"{"status":"ok","deleted":3,"iccid":"test-iccid","peer":"+999000000000"}"#
            )
        }

        let result = try await client.deleteSMSThread(for: contact)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.deleted, 3)
    }

    func testWiFiConfigurationUpdateOnlyTargetsWiFi() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/wangka/api/credentials")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(object["targets"] as? [String], ["wifi"])
            XCTAssertEqual(object["wifi_ssid"] as? String, "Wangka-Renamed")
            XCTAssertEqual(object["new_password"] as? String, "test-password")
            XCTAssertEqual(object["confirm_password"] as? String, "test-password")
            XCTAssertEqual(object["current_vohive_password"] as? String, "")
            return Self.response(for: request, json: #"{"status":"ok","initialized":true}"#)
        }

        let result = try await client.updateWiFi(ssid: "Wangka-Renamed", password: "test-password")
        XCTAssertTrue(result.initialized == true)
    }

    func testUplinkModeRequestUsesSelectedDirection() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/wangka/api/uplink")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(object["mode"] as? String, "host-uplink")
            return Self.response(for: request, json: #"{"status":"ok","mode":"host-uplink"}"#)
        }

        let result = try await client.switchUplinkMode(.hostUplink)
        XCTAssertEqual(result.mode, "host-uplink")
    }

    func testModeSwitchRecoversAfterExpectedConnectionLoss() async throws {
        var statusRequests = 0
        let client = makeClient(workModePollAttempts: 3, workModePollDelayNanoseconds: 0) { request in
            if request.url?.path == "/wangka/api/work-mode" {
                throw URLError(.networkConnectionLost)
            }
            XCTAssertEqual(request.url?.path, "/wangka/api/status")
            statusRequests += 1
            if statusRequests == 1 {
                return Self.response(
                    for: request,
                    json: Self.makeStatusFixture(
                        mode: "data",
                        transition: "data",
                        lastResult: "switching"
                    )
                )
            }
            return Self.response(
                for: request,
                json: Self.makeStatusFixture(mode: "data")
            )
        }

        let result = try await client.switchWorkMode(.data)
        XCTAssertEqual(result.mode, .data)
        XCTAssertNil(result.transitionMode)
        XCTAssertEqual(statusRequests, 2)
    }

    func testModeSwitchReconcilesInvalidHelperResponseWithFinalDeviceState() async throws {
        var requestCount = 0
        let client = makeClient(workModePollAttempts: 2, workModePollDelayNanoseconds: 0) { request in
            requestCount += 1
            if request.url?.path == "/wangka/api/work-mode" {
                return Self.response(
                    for: request,
                    status: 500,
                    json: #"{"status":"error","message":"modem helper returned an invalid result"}"#
                )
            }
            return Self.response(
                for: request,
                json: Self.makeStatusFixture(mode: "data")
            )
        }

        let result = try await client.switchWorkMode(.data)
        XCTAssertEqual(result.mode, .data)
        XCTAssertEqual(requestCount, 2)
    }

    func testModeSwitchAcceptsReachedTargetWithStaleHelperError() async throws {
        let client = makeClient(workModePollAttempts: 2, workModePollDelayNanoseconds: 0) { request in
            if request.url?.path == "/wangka/api/work-mode" {
                throw URLError(.networkConnectionLost)
            }
            return Self.response(
                for: request,
                json: Self.makeStatusFixture(
                    mode: "data",
                    lastResult: "error",
                    lastError: "modem helper returned an invalid result"
                )
            )
        }

        let result = try await client.switchWorkMode(.data)
        XCTAssertEqual(result.mode, .data)
        XCTAssertNil(result.transitionMode)
    }

    func testModeSwitchDoesNotRetryUnrecoverableClientError() async {
        var requestCount = 0
        let client = makeClient(workModePollAttempts: 2, workModePollDelayNanoseconds: 0) { request in
            requestCount += 1
            return Self.response(
                for: request,
                status: 400,
                json: #"{"status":"error","message":"工作模式无效"}"#
            )
        }

        do {
            _ = try await client.switchWorkMode(.data)
            XCTFail("request should fail")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .server(status: 400, message: "工作模式无效"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testTrafficAnalysisUsesSelectedRangeAndDecodesTotals() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/traffic/analysis")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first(where: { $0.name == "range" })?.value, "week")
            XCTAssertEqual(items?.first(where: { $0.name == "device_id" })?.value, "onboard-qmi")
            return Self.response(
                for: request,
                json: #"{"buckets":[{"bucket":"2026-08-22","rx_bytes":1024,"tx_bytes":512,"total_bytes":1536}],"chart":{"timestamps":["20:00"],"devices":["onboard-qmi"],"series":{"onboard-qmi":[1536]}}}"#
            )
        }

        let result = try await client.trafficAnalysis(range: .week, deviceID: "onboard-qmi")
        XCTAssertEqual(result.receivedBytes, 1024)
        XCTAssertEqual(result.transmittedBytes, 512)
        XCTAssertEqual(result.totalBytes, 1536)
        XCTAssertEqual(result.chart?.series["onboard-qmi"], [1536])
    }

    func testManagedDevicesDecodeSIMAndNetworkState() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/devices")
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(
                for: request,
                json: #"{"devices":[{"id":"onboard-qmi","name":"Test Device","running":true,"healthy":true,"network_connected":true,"network_enabled":true,"sms_enabled":true,"registration_state_label":"registered","public_ip":"203.0.113.10","interface":"wwan0","lifecycle_phase":"online","modem":{"operator":"Test Carrier","network_mode":"LTE","signal_dbm":-72,"iccid":"test-iccid"}}],"device_limit":4}"#
            )
        }

        let result = try await client.managedDevices()
        XCTAssertEqual(result.deviceLimit, 4)
        XCTAssertEqual(result.devices.first?.id, "onboard-qmi")
        XCTAssertEqual(result.devices.first?.modem?.operatorName, "Test Carrier")
        XCTAssertEqual(result.devices.first?.modem?.signalDBM, -72)
        XCTAssertTrue(result.devices.first?.networkConnected == true)
    }

    func testDeviceNetworkToggleUsesPatch() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/devices/onboard-qmi/network")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(object["enabled"] as? Bool, false)
            return Self.response(
                for: request,
                json: #"{"network_connected":false,"private_ip":"","public_ip":""}"#
            )
        }

        let result = try await client.setDeviceNetwork(id: "onboard-qmi", enabled: false)
        XCTAssertFalse(result.networkConnected == true)
        XCTAssertEqual(result.privateIP, "")
    }

    func testNotificationSettingsDecodeNullListsAndSaveWithPut() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.url?.path, "/api/settings/notifications")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(
                    for: request,
                    json: #"{"telegram":{"enabled":false,"bot_token":"","chat_id":0,"admin_id":0,"base_url":"","proxy":""},"feishu":{"enabled":false,"app_id":"","app_secret":"","chat_ids":null},"qq":{"enabled":false,"app_id":"","app_secret":"","group_ids":"","direct_ids":""},"email":{"enabled":false,"use_ssl":true,"smtp_host":"","smtp_port":465,"username":"","password":"","from_address":"","to_addresses":null},"pushplus":{"enabled":false,"token":"","topic":"","channel":""},"webhook":{"enabled":false,"urls":null,"secret":"","timeout_ms":10000,"retry_max":2,"text_template":"","headers":null},"bark":{"enabled":false,"urls":null,"group":"","icon":"","level":"active"}}"#
                )
            }

            XCTAssertEqual(request.url?.path, "/api/settings/notifications")
            XCTAssertEqual(request.httpMethod, "PUT")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            let webhook = try XCTUnwrap(object["webhook"] as? [String: Any])
            XCTAssertEqual(webhook["enabled"] as? Bool, true)
            XCTAssertEqual(webhook["urls"] as? [String], ["https://example.invalid/hook"])
            return Self.response(for: request, json: #"{"status":"ok","applied":true}"#)
        }

        var settings = try await client.notificationSettings()
        XCTAssertTrue(settings.feishu.chatIDs.isEmpty)
        XCTAssertTrue(settings.email.toAddresses.isEmpty)
        XCTAssertTrue(settings.webhook.urls.isEmpty)
        XCTAssertTrue(settings.webhook.headers.isEmpty)
        XCTAssertTrue(settings.bark.urls.isEmpty)

        settings.webhook.enabled = true
        settings.webhook.urls = ["https://example.invalid/hook"]
        let response = try await client.saveNotificationSettings(settings)
        XCTAssertEqual(response.status, "ok")
        XCTAssertTrue(response.applied == true)
        XCTAssertEqual(requestCount, 2)
    }

    private func makeClient(
        workModePollAttempts: Int = 75,
        workModePollDelayNanoseconds: UInt64 = 2_000_000_000,
        handler: @escaping MockURLProtocol.Handler
    ) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return APIClient(
            baseURL: URL(string: "http://192.168.5.1")!,
            session: URLSession(configuration: configuration),
            workModePollAttempts: workModePollAttempts,
            workModePollDelayNanoseconds: workModePollDelayNanoseconds
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func makeStatusFixture(
        mode: String,
        transition: String = "",
        lastResult: String = "ok",
        lastError: String = ""
    ) -> String {
        #"""
        {
          "initialized": true,
          "generation": 2,
          "wifi_ssid": "Wangka-UFI103S",
          "uplink_mode": "device-uplink",
          "work_mode": {
            "status": "ok",
            "mode": "\#(mode)",
            "transition": "\#(transition)",
            "data_enabled": true,
            "sms_enabled": false,
            "last_result": "\#(lastResult)",
            "last_error": "\#(lastError)",
            "changed_at": 0
          },
          "thermal": {
            "status": "ok",
            "level": "normal",
            "maximum_c": 47.5,
            "warning_c": 85,
            "critical_c": 92,
            "sensors": []
          },
          "led": {
            "status": "ok",
            "available": true,
            "enabled": true,
            "night_mode": false,
            "mode_color": "white",
            "mode_color_label": "白色",
            "color": "white",
            "color_label": "白色",
            "pattern": "steady",
            "pattern_label": "常亮",
            "meaning": "双模式运行正常",
            "source": "work-mode"
          },
          "access_mode": "login-required",
          "auth_required": true,
          "vohive_active": true,
          "system_time": "2026-08-22 06:00:00 CST",
          "timezone": "Asia/Shanghai"
        }
        """#
    }

    private static let statusFixture = #"""
    {
      "initialized": true,
      "generation": 2,
      "wifi_ssid": "Wangka-UFI103S",
      "uplink_mode": "device-uplink",
      "work_mode": {
        "status": "ok",
        "mode": "dual",
        "transition": "",
        "data_enabled": true,
        "sms_enabled": true,
        "last_result": "ok",
        "last_error": "",
        "changed_at": 0
      },
      "thermal": {
        "status": "ok",
        "level": "normal",
        "maximum_c": 47.5,
        "warning_c": 85,
        "critical_c": 92,
        "sensors": [{"name":"cpu-thermal","temperature_c":47.5,"level":"normal"}]
      },
      "led": {
        "status": "ok",
        "available": true,
        "enabled": true,
        "night_mode": false,
        "mode_color": "white",
        "mode_color_label": "白色",
        "color": "white",
        "color_label": "白色",
        "pattern": "steady",
        "pattern_label": "常亮",
        "meaning": "双模式运行正常",
        "source": "work-mode"
      },
      "access_mode": "login-required",
      "auth_required": true,
      "vohive_active": true,
      "system_time": "2026-08-22 06:00:00 CST",
      "timezone": "Asia/Shanghai"
    }
    """#
}
