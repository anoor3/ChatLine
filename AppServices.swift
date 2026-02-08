import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity
import UIKit

// MARK: - Identity

final class IdentityService: ObservableObject {
    @Published private(set) var identity: LocalIdentity

    private let keychain: KeychainStore
    private let key = "local-identity"

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
        if let data = keychain.data(for: key), let decoded = try? JSONDecoder().decode(LocalIdentity.self, from: data) {
            self.identity = decoded
        } else {
            let generated = LocalIdentity()
            self.identity = generated
            persist()
        }
    }

    func update(displayName: String) {
        identity.displayName = displayName
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        keychain.set(data, for: key)
        objectWillChange.send()
    }
}

struct PeerIdentity: Codable, Hashable {
    let uuid: UUID
    let displayName: String
    let publicKey: Data
}

struct LocalIdentity: Codable {
    var uuid: UUID
    var publicKey: Data
    var privateKey: Data
    var displayName: String

    init() {
        self.uuid = UUID()
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = key.publicKey.rawRepresentation
        self.privateKey = key.rawRepresentation
        self.displayName = Self.defaultDisplayName()
    }

    var broadcastIdentity: PeerIdentity {
        PeerIdentity(uuid: uuid, displayName: displayName, publicKey: publicKey)
    }

    private static func defaultDisplayName() -> String {
        let formatter = PersonNameComponentsFormatter()
        if let givenName = formatter.personNameComponents(from: UIDevice.current.name)?.givenName {
            return givenName
        }
        return "Someone Nearby"
    }
}

// MARK: - Models

struct DiscoveredPeer: Identifiable, Hashable {
    let identity: PeerIdentity
    let peerID: MCPeerID
    let signalStrength: SignalStrength

    var id: UUID { identity.uuid }
    var name: String { identity.displayName }
}

enum SignalStrength: String {
    case weak, medium, strong

    init(rssi: Int) {
        switch rssi {
        case ..<(-75): self = .weak
        case -75...(-55): self = .medium
        default: self = .strong
        }
    }
}

struct Message: Identifiable, Hashable, Codable {
    let id: UUID
    let text: String
    let isOutgoing: Bool
    let timestamp: Date
    let expiresAt: Date
}

struct Conversation: Identifiable, Hashable, Codable {
    enum Status: String, Codable {
        case active
        case pendingSent
        case pendingReceived
    }

    let id: UUID
    var peerName: String
    var messages: [Message]
    var isBlocked: Bool
    var status: Status
    var requestMessage: String?

    init(id: UUID, peerName: String, messages: [Message], isBlocked: Bool, status: Status = .active, requestMessage: String? = nil) {
        self.id = id
        self.peerName = peerName
        self.messages = messages
        self.isBlocked = isBlocked
        self.status = status
        self.requestMessage = requestMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, peerName, messages, isBlocked, status, requestMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        peerName = try container.decode(String.self, forKey: .peerName)
        messages = try container.decode([Message].self, forKey: .messages)
        isBlocked = try container.decode(Bool.self, forKey: .isBlocked)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
        requestMessage = try container.decodeIfPresent(String.self, forKey: .requestMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(peerName, forKey: .peerName)
        try container.encode(messages, forKey: .messages)
        try container.encode(isBlocked, forKey: .isBlocked)
        try container.encode(status, forKey: .status)
        try container.encode(requestMessage, forKey: .requestMessage)
    }
}

// MARK: - Conversation Store

/// Persists transcripts locally using a sealed store so nothing ever leaves this device.
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [UUID: Conversation] = [:]
    @Published var expirationSetting: TimeInterval = 60 * 60 * 24 {
        didSet { persist() }
    }

    private let disk = SecureDiskStore(filename: "conversations.dat", keyIdentifier: "conversation-storage")

    init() {
        if let data = disk.load(), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.conversations = snapshot.conversations
            self.expirationSetting = snapshot.expiration
        }
    }

    func messages(for identity: UUID) -> [Message] {
        conversations[identity]?.messages ?? []
    }

    func append(text: String, to identity: PeerIdentity, outgoing: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = Message(id: UUID(), text: text, isOutgoing: outgoing, timestamp: Date(), expiresAt: Date().addingTimeInterval(expirationSetting))
        updateConversation(identity: identity.uuid, name: identity.displayName) { convo in
            if convo.status != .active {
                convo.status = .active
                convo.requestMessage = nil
            }
            convo.messages.append(message)
        }
    }

    func pruneExpired() {
        let now = Date()
        conversations = conversations.mapValues { convo in
            var updated = convo
            updated.messages.removeAll { $0.expiresAt < now }
            return updated
        }
        persist()
    }

    func setBlocked(_ blocked: Bool, for identity: PeerIdentity) {
        setBlocked(blocked, identityID: identity.uuid, name: identity.displayName)
    }

    func setBlocked(_ blocked: Bool, identityID: UUID, name: String) {
        updateConversation(identity: identityID, name: name) { convo in
            convo.isBlocked = blocked
        }
    }

    func isBlocked(_ identity: PeerIdentity) -> Bool {
        conversations[identity.uuid]?.isBlocked ?? false
    }

    func blockedConversations() -> [Conversation] {
        conversations.values.filter { $0.isBlocked }
    }

    func status(for identity: UUID) -> Conversation.Status? {
        conversations[identity]?.status
    }

    func conversation(for identity: UUID) -> Conversation? {
        conversations[identity]
    }

    func setPendingSent(message: String?, to identity: PeerIdentity) {
        updateConversation(identity: identity.uuid, name: identity.displayName) { convo in
            convo.status = .pendingSent
            convo.requestMessage = message
        }
    }

    func setPendingReceived(message: String?, from identity: PeerIdentity) {
        updateConversation(identity: identity.uuid, name: identity.displayName) { convo in
            convo.status = .pendingReceived
            convo.requestMessage = message
        }
    }

    func activateConversation(with identity: PeerIdentity) {
        updateConversation(identity: identity.uuid, name: identity.displayName) { convo in
            convo.status = .active
            convo.requestMessage = nil
        }
    }

    func activateConversation(id: UUID, name: String) {
        updateConversation(identity: id, name: name) { convo in
            convo.status = .active
            convo.requestMessage = nil
        }
    }

    func cancelPending(for identity: UUID) {
        guard var conversation = conversations[identity] else { return }
        conversation.status = .active
        conversation.requestMessage = nil
        if conversation.messages.isEmpty && !conversation.isBlocked {
            conversations.removeValue(forKey: identity)
        } else {
            conversations[identity] = conversation
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(conversations: conversations, expiration: expirationSetting)) else { return }
        disk.save(data)
    }

    private struct Snapshot: Codable {
        let conversations: [UUID: Conversation]
        let expiration: TimeInterval
    }

    private func updateConversation(identity: UUID, name: String, transform: (inout Conversation) -> Void) {
        var conversation = conversations[identity] ?? Conversation(id: identity, peerName: name, messages: [], isBlocked: false, status: .active)
        conversation.peerName = name
        transform(&conversation)
        conversations[identity] = conversation
        persist()
    }
}

// MARK: - Discovery + Sessions

final class PeerDiscoveryManager: NSObject {
    private let serviceType = "offgrid-chat"
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private let sessionProvider: () -> MCSession
    private let localIdentity: LocalIdentity
    private let workerQueue = DispatchQueue(label: "PeerDiscoveryWorker", qos: .userInitiated)
    private var isRunning = false

    private var peersByIdentity: [UUID: DiscoveredPeer] = [:]
    private var peersByPeerID: [MCPeerID: DiscoveredPeer] = [:]
    private var pendingNotification: DispatchWorkItem?

    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    var onError: ((ScanErrorInfo) -> Void)?
    var onBluetoothStateChange: ((String) -> Void)?

    init(localIdentity: LocalIdentity, peerID: MCPeerID, sessionProvider: @escaping () -> MCSession) {
        self.localIdentity = localIdentity
        self.sessionProvider = sessionProvider
        super.init()
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        let discoveryInfo: [String: String] = [
            "id": localIdentity.uuid.uuidString,
            "pub": localIdentity.publicKey.base64EncodedString()
        ]
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        browser?.delegate = self
        advertiser?.delegate = self
    }

    /// Discovery is intentionally started only after onboarding completes so typing/animations stay responsive.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        workerQueue.async { [weak self] in
            self?.browser?.startBrowsingForPeers()
            self?.advertiser?.startAdvertisingPeer()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onBluetoothStateChange?("poweredOn")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        workerQueue.async { [weak self] in
            self?.browser?.stopBrowsingForPeers()
            self?.advertiser?.stopAdvertisingPeer()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onBluetoothStateChange?("idle")
        }
    }

    func connect(to peer: DiscoveredPeer) {
        guard let browser else { return }
        workerQueue.async { [weak self, weak browser] in
            guard let self else { return }
            let context = try? JSONEncoder().encode(self.localIdentity.broadcastIdentity)
            browser?.invitePeer(peer.peerID, to: self.sessionProvider(), withContext: context, timeout: 15)
        }
    }

    func peer(for peerID: MCPeerID) -> DiscoveredPeer? {
        peersByPeerID[peerID]
    }

    private func register(_ peer: DiscoveredPeer) {
        peersByIdentity[peer.id] = peer
        peersByPeerID[peer.peerID] = peer
        schedulePeerNotification()
    }

    private func unregister(peerID: MCPeerID) {
        if let peer = peersByPeerID.removeValue(forKey: peerID) {
            peersByIdentity.removeValue(forKey: peer.id)
        }
        schedulePeerNotification()
    }

    /// Debounce peer list notifications so the UI isn't redrawn for every heartbeat.
    private func schedulePeerNotification() {
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.peersByIdentity.values.sorted { $0.name < $1.name }
            DispatchQueue.main.async {
                self.onPeersChanged?(snapshot)
            }
        }
        pendingNotification = work
        workerQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

extension PeerDiscoveryManager: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            let info = ScanErrorInfo(reason: .failed(error.localizedDescription), message: "Unable to start scanning (\(error.localizedDescription)).", actionTitle: "Try again")
            self?.onError?(info)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard
            let info,
            let idString = info["id"],
            let uuid = UUID(uuidString: idString),
            let pubString = info["pub"],
            let pubData = Data(base64Encoded: pubString)
        else { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            let remoteIdentity = PeerIdentity(uuid: uuid, displayName: peerID.displayName, publicKey: pubData)
            let signalStrength = SignalStrength(rssi: Int.random(in: -90 ... -30))
            let discovered = DiscoveredPeer(identity: remoteIdentity, peerID: peerID, signalStrength: signalStrength)
            self.register(discovered)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        workerQueue.async { [weak self] in
            self?.unregister(peerID: peerID)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            if let context, let identity = try? JSONDecoder().decode(PeerIdentity.self, from: context) {
                let signalStrength = SignalStrength(rssi: Int.random(in: -90 ... -30))
                let discovered = DiscoveredPeer(identity: identity, peerID: peerID, signalStrength: signalStrength)
                self.register(discovered)
            }
            invitationHandler(true, self.sessionProvider())
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            let info = ScanErrorInfo(reason: .failed(error.localizedDescription), message: "Scanning can't start because \(error.localizedDescription).", actionTitle: "Try again")
            self?.onError?(info)
        }
    }
}

// MARK: - Message Router

protocol MessageRouterDelegate: AnyObject {
    func messageRouter(_ router: MessageRouter, peer peerID: MCPeerID, didChange state: MCSessionState)
}

final class MessageRouter: NSObject {
    private let session: MCSession
    private let store: ConversationStore
    private let rateLimiter = RateLimiter(maxMessagesPerMinute: 10)
    private let sessionManager: SecureSessionManager
    private let peerLookup: (MCPeerID) -> DiscoveredPeer?
    private var pendingPayloads: [MCPeerID: [MessageEnvelope.Payload]] = [:]
    weak var delegate: MessageRouterDelegate?

    init(identity: MCPeerID, store: ConversationStore, sessionManager: SecureSessionManager, peerLookup: @escaping (MCPeerID) -> DiscoveredPeer?) {
        self.store = store
        self.sessionManager = sessionManager
        self.peerLookup = peerLookup
        self.session = MCSession(peer: identity, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    var mcSession: MCSession { session }

    func sendMessage(_ text: String, to peer: DiscoveredPeer) {
        queueOrSend(.message(text), to: peer)
        store.append(text: text, to: peer.identity, outgoing: true)
    }

    func sendRequest(message: String?, to peer: DiscoveredPeer) {
        queueOrSend(.request(message), to: peer)
        store.setPendingSent(message: message, to: peer.identity)
    }

    func sendAcceptance(to peer: DiscoveredPeer) {
        queueOrSend(.accept, to: peer)
        store.activateConversation(with: peer.identity)
    }

    private func queueOrSend(_ payload: MessageEnvelope.Payload, to peer: DiscoveredPeer) {
        guard rateLimiter.canSend(to: peer.peerID) else { return }
        if session.connectedPeers.contains(peer.peerID) {
            sendPayload(payload, to: peer)
        } else {
            var queue = pendingPayloads[peer.peerID] ?? []
            queue.append(payload)
            pendingPayloads[peer.peerID] = queue
        }
    }

    private func sendPayload(_ payload: MessageEnvelope.Payload, to peer: DiscoveredPeer) {
        guard let data = try? encode(payload: payload, for: peer.identity) else { return }
        do {
            try session.send(data, toPeers: [peer.peerID], with: .reliable)
        } catch {
            print("Send error: \(error)")
            var queue = pendingPayloads[peer.peerID] ?? []
            queue.append(payload)
            pendingPayloads[peer.peerID] = queue
        }
    }

    private func encode(payload: MessageEnvelope.Payload, for identity: PeerIdentity) throws -> Data {
        let key = try sessionManager.key(for: identity)
        let envelope = MessageEnvelope(payload: payload, timestamp: Date())
        let data = try JSONEncoder().encode(envelope)
        let sealed = try ChaChaPoly.seal(data, using: key)
        return sealed.combined
    }

    private func decode(_ data: Data, from peerID: MCPeerID) -> MessageEnvelope? {
        guard let peer = peerLookup(peerID), let key = try? sessionManager.key(for: peer.identity) else { return nil }
        do {
            let sealed = try ChaChaPoly.SealedBox(combined: data)
            let decrypted = try ChaChaPoly.open(sealed, using: key)
            return try JSONDecoder().decode(MessageEnvelope.self, from: decrypted)
        } catch {
            print("Decrypt error: \(error)")
            return nil
        }
    }

    private struct MessageEnvelope: Codable {
        enum Payload: Codable {
            case message(String)
            case request(String?)
            case accept

            private enum CodingKeys: String, CodingKey { case type, value }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .message(let text):
                    try container.encode("message", forKey: .type)
                    try container.encode(text, forKey: .value)
                case .request(let text):
                    try container.encode("request", forKey: .type)
                    try container.encodeIfPresent(text, forKey: .value)
                case .accept:
                    try container.encode("accept", forKey: .type)
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "message":
                    let text = try container.decode(String.self, forKey: .value)
                    self = .message(text)
                case "request":
                    let text = try container.decodeIfPresent(String.self, forKey: .value)
                    self = .request(text)
                case "accept":
                    self = .accept
                default:
                    self = .message(try container.decode(String.self, forKey: .value))
                }
            }
        }

        let payload: Payload
        let timestamp: Date
    }
}

extension MessageRouter: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected, let peer = peerLookup(peerID) {
            if var queue = pendingPayloads[peerID], !queue.isEmpty {
                pendingPayloads[peerID] = []
                queue.forEach { payload in
                    sendPayload(payload, to: peer)
                }
            }
        }
        delegate?.messageRouter(self, peer: peerID, didChange: state)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let envelope = decode(data, from: peerID), let peer = peerLookup(peerID) else { return }
        guard !store.isBlocked(peer.identity) else { return }
        DispatchQueue.main.async {
            switch envelope.payload {
            case .message(let text):
                self.store.append(text: text, to: peer.identity, outgoing: false)
            case .request(let text):
                self.store.setPendingReceived(message: text, from: peer.identity)
            case .accept:
                self.store.activateConversation(with: peer.identity)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

// MARK: - Rate limiter

final class RateLimiter {
    private let maxMessagesPerMinute: Int
    private var history: [MCPeerID: [Date]] = [:]

    init(maxMessagesPerMinute: Int) {
        self.maxMessagesPerMinute = maxMessagesPerMinute
    }

    func canSend(to peer: MCPeerID) -> Bool {
        let windowStart = Date().addingTimeInterval(-60)
        let timestamps = (history[peer] ?? []).filter { $0 > windowStart }
        history[peer] = timestamps
        guard timestamps.count < maxMessagesPerMinute else { return false }
        history[peer]?.append(Date())
        return true
    }
}
