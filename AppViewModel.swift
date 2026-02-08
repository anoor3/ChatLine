import Foundation
import SwiftUI
import MultipeerConnectivity

@MainActor
final class AppController: ObservableObject {
    enum AppTab: Hashable {
        case home, nearby, chats
    }
    

    @Published var showOnboarding: Bool
    @Published var selectedPeer: DiscoveredPeer?
    @Published var showPrivacy = false
    @Published var selectedTab: AppTab = .home
    @Published private(set) var networkModel: NetworkScreenModel?
    @Published var requestComposerPeer: DiscoveredPeer?
    @Published var pendingStatusPeer: DiscoveredPeer?
    @Published var incomingRequestPeer: DiscoveredPeer?
    @Published var connectingPeer: DiscoveredPeer?
    @Published var connectionErrorPeer: DiscoveredPeer?

    let identityService: IdentityService
    let store: ConversationStore
    private var router: MessageRouter?
    private var secureSessionManager: SecureSessionManager?
    private var discovery: PeerDiscoveryManager?
    private let bluetoothPermission = BluetoothPermissionManager()
    private var connectionTimeouts: [UUID: DispatchWorkItem] = [:]

    init() {
        identityService = IdentityService()
        store = ConversationStore()
        let hasFinished = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        self.showOnboarding = !hasFinished
        if hasFinished {
            bluetoothPermission.requestAuthorization()
            configureNetworking()
        }
    }

    func finishOnboarding(with name: String) {
        identityService.update(displayName: name)
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        bluetoothPermission.requestAuthorization()
        configureNetworking()
        withAnimation(.spring()) {
            showOnboarding = false
        }
    }

    func handlePeerTap(_ peer: DiscoveredPeer) {
        selectedTab = .nearby
        networkModel?.connect(peer)
        guard let status = store.status(for: peer.identity.uuid) else {
            beginConnectionFlow(peer)
            return
        }
        switch status {
        case .active:
            selectedPeer = peer
        case .pendingSent:
            pendingStatusPeer = peer
        case .pendingReceived:
            incomingRequestPeer = peer
        }
    }

    func send(_ text: String) {
        guard let peer = selectedPeer else { return }
        guard !store.isBlocked(peer.identity) else { return }
        router?.sendMessage(text, to: peer)
    }

    func submitRequest(message: String?, to peer: DiscoveredPeer) {
        router?.sendRequest(message: message, to: peer)
        requestComposerPeer = nil
        pendingStatusPeer = peer
    }

    func acceptRequest(for peer: DiscoveredPeer) {
        router?.sendAcceptance(to: peer)
        incomingRequestPeer = nil
    }

    func cancelOutgoingRequest(for peer: DiscoveredPeer) {
        store.cancelPending(for: peer.identity.uuid)
        pendingStatusPeer = nil
    }

    func declineIncomingRequest(for peer: DiscoveredPeer) {
        store.cancelPending(for: peer.identity.uuid)
        incomingRequestPeer = nil
    }

    func cancelConnectionAttempt(for peer: DiscoveredPeer) {
        connectionTimeouts[peer.id]?.cancel()
        connectionTimeouts.removeValue(forKey: peer.id)
        if connectingPeer?.id == peer.id {
            connectingPeer = nil
        }
    }

    func block(_ peer: DiscoveredPeer) {
        store.setBlocked(true, for: peer.identity)
    }

    func unblock(_ identity: UUID) {
        guard let conversation = store.conversations[identity] else { return }
        store.setBlocked(false, identityID: conversation.id, name: conversation.peerName)
    }

    func isBlocked(_ peer: DiscoveredPeer) -> Bool {
        store.isBlocked(peer.identity)
    }

    func blockedConversations() -> [Conversation] {
        store.blockedConversations()
    }

    func status(for peer: DiscoveredPeer) -> Conversation.Status? {
        store.status(for: peer.identity.uuid)
    }

    func requestMessage(for peer: DiscoveredPeer) -> String? {
        store.conversation(for: peer.identity.uuid)?.requestMessage
    }

    func peer(for conversation: Conversation) -> DiscoveredPeer? {
        networkModel?.peer(with: conversation.id)
    }

    func updateExpiration(_ interval: TimeInterval) {
        store.expirationSetting = interval
        store.pruneExpired()
    }

    private static let onboardingKey = "didFinishOnboarding"

private func configureNetworking() {
        let identity = identityService.identity
        let peerID = MCPeerID(displayName: identity.displayName)
        let sessionManager = SecureSessionManager(localIdentity: identity)
        self.secureSessionManager = sessionManager
        let router = MessageRouter(identity: peerID, store: store, sessionManager: sessionManager) { [weak self] peerID in
            self?.discovery?.peer(for: peerID)
        }
        self.router = router
        let discovery = PeerDiscoveryManager(localIdentity: identity, peerID: peerID, sessionProvider: { router.mcSession })
        self.discovery = discovery

        // Networking is only exposed through a view model so SwiftUI never touches Multipeer components directly.
        self.networkModel = NetworkScreenModel(discovery: discovery, permission: bluetoothPermission)
    }

    private func beginConnectionFlow(_ peer: DiscoveredPeer) {
        connectingPeer = peer
        scheduleTimeout(for: peer)
    }

    private func scheduleTimeout(for peer: DiscoveredPeer) {
        connectionTimeouts[peer.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.connectingPeer?.id == peer.id {
                self.connectingPeer = nil
                self.connectionErrorPeer = peer
            }
        }
        connectionTimeouts[peer.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
}

extension AppController: MessageRouterDelegate {
    func messageRouter(_ router: MessageRouter, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard let peer = resolvedPeer(from: peerID) else { return }
        DispatchQueue.main.async {
            self.connectionTimeouts[peer.id]?.cancel()
            self.connectionTimeouts.removeValue(forKey: peer.id)
            switch state {
            case .connected:
                if self.connectingPeer?.id == peer.id {
                    self.connectingPeer = nil
                    self.requestComposerPeer = peer
                }
            case .notConnected:
                if self.connectingPeer?.id == peer.id {
                    self.connectingPeer = nil
                    self.connectionErrorPeer = peer
                }
            default:
                break
            }
        }
    }

    private func resolvedPeer(from peerID: MCPeerID) -> DiscoveredPeer? {
        if let peer = discovery?.peer(for: peerID) {
            return peer
        }
        if let peer = networkModel?.peers.first(where: { $0.peerID == peerID }) {
            return peer
        }
        if let current = connectingPeer, current.peerID == peerID {
            return current
        }
        return nil
    }
}
