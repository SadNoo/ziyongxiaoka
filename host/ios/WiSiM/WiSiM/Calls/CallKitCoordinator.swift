import AVFAudio
import CallKit
import Foundation

@MainActor
final class CallKitCoordinator: NSObject, ObservableObject {
    @Published private(set) var activeCallID: UUID?
    @Published private(set) var lastError: String?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var actionHandler: ((CallAction) async -> Bool)?

    enum CallAction { case answer(UUID), end(UUID), start(UUID, String) }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func installActionHandler(_ handler: @escaping (CallAction) async -> Bool) {
        actionHandler = handler
    }

    func reportIncoming(number: String) async throws -> UUID {
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.hasVideo = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: id, update: update) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
        activeCallID = id
        return id
    }

    func reportEnded(_ id: UUID, reason: CXCallEndedReason = .remoteEnded) {
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
        if activeCallID == id { activeCallID = nil }
    }
}

extension CallKitCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.activeCallID = nil }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let handler = self.actionHandler, await handler(.answer(action.callUUID)) else {
                action.fail(); return
            }
            self.activeCallID = action.callUUID
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            guard let handler = self.actionHandler, await handler(.end(action.callUUID)) else {
                action.fail(); return
            }
            self.activeCallID = nil
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            let number = action.handle.value
            guard let handler = self.actionHandler, await handler(.start(action.callUUID, number)) else {
                action.fail(); return
            }
            self.activeCallID = action.callUUID
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            action.fulfill()
        }
    }
}
