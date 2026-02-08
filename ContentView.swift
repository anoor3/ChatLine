//
//  ContentView.swift
//  chat line
//
//  Created by Abdullah Noor on 2/4/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var controller = AppController()

    var body: some View {
        ZStack {
            if controller.showOnboarding {
                OnboardingContainer(initialName: controller.identityService.identity.displayName) { name in
                    controller.finishOnboarding(with: name)
                }
                .transition(.opacity.combined(with: .scale))
            } else {
                MainAppView(controller: controller)
            }
        }
        .animation(.easeInOut, value: controller.showOnboarding)
    }
}

struct MainAppView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        TabView(selection: $controller.selectedTab) {
            HomeView(controller: controller)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppController.AppTab.home)

            NearbyTabView(controller: controller)
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppController.AppTab.nearby)

            ChatsView(controller: controller)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppController.AppTab.chats)
        }
        .sheet(item: $controller.selectedPeer) { peer in
            ChatView(peer: peer,
                     store: controller.store,
                     expiration: controller.store.expirationSetting,
                     isBlocked: controller.isBlocked(peer),
                     sendAction: { controller.send($0) },
                     blockAction: { controller.block(peer) })
        }
        .sheet(item: $controller.requestComposerPeer) { peer in
            ConnectionRequestSheet(peer: peer,
                                   send: { message in controller.submitRequest(message: message, to: peer) },
                                   cancel: { controller.requestComposerPeer = nil })
        }
        .sheet(item: $controller.connectingPeer) { peer in
            ConnectionProgressView(peer: peer) {
                controller.cancelConnectionAttempt(for: peer)
            }
        }
        .sheet(item: $controller.pendingStatusPeer) { peer in
            PendingRequestStatusView(peer: peer,
                                     message: controller.requestMessage(for: peer) ?? "Waiting for approval.") {
                controller.pendingStatusPeer = nil
            } cancel: {
                controller.cancelOutgoingRequest(for: peer)
            }
        }
        .sheet(item: $controller.incomingRequestPeer) { peer in
            IncomingRequestView(peer: peer,
                                message: controller.requestMessage(for: peer) ?? "",
                                accept: {
                                    controller.acceptRequest(for: peer)
                                },
                                decline: {
                                    controller.declineIncomingRequest(for: peer)
                                })
        }
        .alert(item: $controller.connectionErrorPeer) { peer in
            Alert(title: Text("Couldn't connect to \(peer.name)"),
                  message: Text("Make sure both phones keep this screen open and try again."),
                  dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $controller.showPrivacy) {
            PrivacySafetyView(blocked: controller.blockedConversations(),
                              expiration: controller.store.expirationSetting,
                              updateExpiration: controller.updateExpiration,
                              unblock: controller.unblock)
        }
    }
}

struct HomeView: View {
    @ObservedObject var controller: AppController
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    HomeHeroCard(name: controller.identityService.identity.displayName,
                                 lastScan: controller.networkModel?.lastScanFinishedAt,
                                 formatter: dateFormatter) {
                        controller.selectedTab = .nearby
                    }

                    VStack(spacing: 16) {
                        HomeInfoCard(title: "Privacy & Safety",
                                     message: "Block identities, tune expiration, and learn what stays on-device.",
                                     actionTitle: "View privacy") {
                            controller.showPrivacy = true
                        }

                        HomeInfoCard(title: "How it works",
                                     message: "Offline-only Bluetooth links that appear when people stand nearby.",
                                     actionTitle: "See tips") {
                            controller.selectedTab = .nearby
                        }
                    }

                    if let info = controller.networkModel?.debugInfo, let started = info.scanStartedAt {
                        HomeStatusChip(title: "Active scan", value: "Started \(RelativeDateTimeFormatter().localizedString(for: started, relativeTo: Date()))")
                    } else if let last = controller.networkModel?.lastScanFinishedAt {
                        HomeStatusChip(title: "Last scan", value: dateFormatter.string(from: last))
                    } else {
                        HomeStatusChip(title: "Last scan", value: "Never")
                    }
                }
                .padding()
            }
            .background(LinearGradient(colors: [.indigo.opacity(0.1), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea())
            .navigationTitle("Signal")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        controller.showPrivacy = true
                    } label: {
                        Image(systemName: "shield.lefthalf.fill")
                    }
                    .accessibilityLabel("Privacy & Safety")
                }
            }
        }
    }
}

struct HomeHeroCard: View {
    let name: String
    let lastScan: Date?
    let formatter: DateFormatter
    let goAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome, \(name.isEmpty ? "friend" : name)")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Create a nearby network without internet or numbers. Your presence is local only.")
                .foregroundStyle(.white.opacity(0.8))
            Button(action: goAction) {
                Label("Go online nearby", systemImage: "wave.3.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.black)
            }
            if let lastScan {
                Text("Last scan: \(formatter.string(from: lastScan))")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("You haven’t scanned yet.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }
}

struct HomeInfoCard: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Text(actionTitle)
                    .font(.footnote.bold())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct HomeStatusChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct NearbyTabView: View {
    @ObservedObject var controller: AppController
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            if let model = controller.networkModel {
                NearbyScanLayout(model: model,
                                 showDebug: $showDebug,
                                 statusProvider: { controller.status(for: $0) },
                                 peerAction: { controller.handlePeerTap($0) })
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            controller.showPrivacy = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Preparing Bluetooth session…")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Nearby")
            }
        }
    }
}

struct NearbyScanLayout: View {
    @ObservedObject var model: NetworkScreenModel
    @Binding var showDebug: Bool
    let statusProvider: (DiscoveredPeer) -> Conversation.Status?
    let peerAction: (DiscoveredPeer) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ScanStatusHeader(title: model.statusTitle,
                                 subtitle: model.statusSubtitle,
                                 elapsed: model.elapsedDescription,
                                 isActive: model.isActive)

                stateContent

                scanControls
            }
            .padding()
        }
        .background(LinearGradient(colors: [.purple.opacity(0.05), .white], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .navigationTitle("Nearby")
        .simultaneousGesture(LongPressGesture(minimumDuration: 1.0).onEnded { _ in
            withAnimation { showDebug.toggle() }
        })
        .onAppear { model.beginScanningIfNeeded() }
        .overlay(alignment: .bottom) {
            if showDebug {
                DebugPanel(model: model)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.phase {
        case .idle:
            IdleStateCard(startAction: model.beginScanningIfNeeded)
        case .scanning:
            ScanningActiveCard()
        case .noResults:
            NoResultsCard()
        case .results:
            DevicesSection(peers: model.peers,
                           statusProvider: statusProvider,
                           openChat: peerAction)
        case .error(let info):
            ErrorStateCard(info: info,
                           primaryAction: { model.handleErrorAction(info) },
                           retry: model.restartScan)
        }
    }

    private var scanControls: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle:
                Button(action: model.beginScanningIfNeeded) {
                    Label("Start scanning", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .error(let info):
                Button(info.actionTitle) {
                    model.handleErrorAction(info)
                }
                .buttonStyle(.borderedProminent)
                Button("Retry scan") {
                    model.restartScan()
                }
            case .scanning, .noResults, .results:
                Button(action: model.stopScanning) {
                    Label("Pause scanning", systemImage: "pause.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if model.isActive {
                Button("Restart scan") {
                    model.restartScan()
                }
                .font(.footnote)
            }
        }
    }
}

struct ScanStatusHeader: View {
    let title: String
    let subtitle: String
    let elapsed: String
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if isActive {
                    ScanningPulse()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text(elapsed)
                        .font(.footnote.monospacedDigit())
                        .padding(8)
                        .background(Color(.systemGray6), in: Capsule())
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ScanningPulse: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Color.blue.opacity(0.3))
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .stroke(Color.blue, lineWidth: 2)
                    .scaleEffect(animate ? 1.4 : 0.8)
                    .opacity(animate ? 0.2 : 0.8)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever()) {
                    animate = true
                }
            }
    }
}

struct IdleStateCard: View {
    let startAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not scanning")
                .font(.headline)
            Text("Scanning uses Bluetooth and stays off until you start it. Keep the app open once you begin.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button(action: startAction) {
                Text("Start scanning")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ScanningActiveCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Scanning for nearby devices")
                .font(.headline)
            Text("Keep this screen open. Signals are shared only over Bluetooth.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView()
                .progressViewStyle(.circular)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct NoResultsCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Scanning is active, but no nearby devices detected.")
                .font(.headline)
            Text("Ask someone nearby to open the app. Bluetooth reach is roughly 30 feet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct DevicesSection: View {
    let peers: [DiscoveredPeer]
    let statusProvider: (DiscoveredPeer) -> Conversation.Status?
    let openChat: (DiscoveredPeer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices nearby")
                .font(.headline)
            Text("Tap a name to start a secure chat.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 12) {
                ForEach(peers) { peer in
                    Button {
                        openChat(peer)
                    } label: {
                        PeerRow(peer: peer, status: statusProvider(peer))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ErrorStateCard: View {
    let info: ScanErrorInfo
    let primaryAction: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(info.message)
                .multilineTextAlignment(.center)
            Button(info.actionTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
            Button("Try again", action: retry)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ConnectionRequestSheet: View {
    let peer: DiscoveredPeer
    let send: (String?) -> Void
    let cancel: () -> Void
    @State private var message: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Request to connect with \(peer.name)")
                    .font(.title2.bold())
                Text("Send a short note so they know who's asking. They must approve before the chat opens.")
                    .foregroundStyle(.secondary)
                TextField("Optional message", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    send(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message)
                } label: {
                    Label("Send request", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Request access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
        }
    }
}

struct ConnectionProgressView: View {
    let peer: DiscoveredPeer
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Connecting to \(peer.name)…")
                .font(.headline)
            Text("Both devices must keep this app open while the secure link is established.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
        }
        .padding()
    }
}

struct PendingRequestStatusView: View {
    let peer: DiscoveredPeer
    let message: String
    let dismiss: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Waiting for \(peer.name) to accept")
                .font(.headline)
            if !message.isEmpty {
                Text("You wrote: \(message)")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text("They need this app open to receive your request.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Close", action: dismiss)
            Button("Cancel request", role: .destructive, action: cancel)
        }
        .padding()
    }
}

struct IncomingRequestView: View {
    let peer: DiscoveredPeer
    let message: String
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("\(peer.name) wants to chat")
                    .font(.title2.bold())
                if !message.isEmpty {
                    Text("“\(message)”")
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("No message included.")
                        .foregroundStyle(.secondary)
                }
                Button("Accept & open chat", action: accept)
                    .buttonStyle(.borderedProminent)
                Button("Not now", role: .cancel, action: decline)
            Spacer()
        }
        .padding()
        .navigationTitle("Approve request")
        }
    }
}

struct PeerRow: View {
    let peer: DiscoveredPeer
    let status: Conversation.Status?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.name)
                    .font(.headline)
                Text(statusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusDescription: String {
        if let status {
            switch status {
            case .active:
                return proximityText
            case .pendingSent:
                return "Request sent"
            case .pendingReceived:
                return "Request waiting for you"
            }
        }
        return proximityText
    }

    private var proximityText: String {
        switch peer.signalStrength {
        case .weak: return "A bit far"
        case .medium: return "Within reach"
        case .strong: return "Very close"
        }
    }
}

struct DebugPanel: View {
    @ObservedObject var model: NetworkScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .font(.headline)
            Text("Scan started: \(formatted(model.debugInfo.scanStartedAt) ?? "–")")
            Text("Elapsed: \(model.elapsedDescription)")
            Text("Bluetooth: \(model.debugInfo.bluetoothState)")
            Text("Peer callbacks: \(model.debugInfo.peerCallbackCount)")
            Text("Last callback: \(formatted(model.debugInfo.lastEventAt) ?? "–")")
        }
        .font(.caption)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
    }

    private func formatted(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct ChatsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        NavigationStack {
            if sortedConversations.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Chats appear after you connect with someone nearby.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .navigationTitle("Chats")
            } else {
                List(sortedConversations) { conversation in
                    ChatSummaryRow(conversation: conversation,
                                   status: conversation.status,
                                   lastMessage: conversation.messages.last,
                                   statusAction: {
                        guard let peer = controller.peer(for: conversation) else { return }
                        switch conversation.status {
                        case .active:
                            controller.handlePeerTap(peer)
                        case .pendingSent:
                            controller.pendingStatusPeer = peer
                        case .pendingReceived:
                            controller.incomingRequestPeer = peer
                        }
                    })
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Chats")
            }
        }
    }

    private var sortedConversations: [Conversation] {
        controller.store.conversations.values.sorted { lhs, rhs in
            (lhs.messages.last?.timestamp ?? .distantPast) > (rhs.messages.last?.timestamp ?? .distantPast)
        }
    }
}

struct ChatSummaryRow: View {
    let conversation: Conversation
    let status: Conversation.Status
    let lastMessage: Message?
    let statusAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(conversation.peerName)
                    .font(.headline)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let last = lastMessage {
                Text("\(last.isOutgoing ? "You" : conversation.peerName): \(last.text)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Text("No messages yet")
                    .foregroundStyle(.secondary)
            }
            if let expires = lastMessage?.expiresAt, status == .active {
                Text("Expires " + expires.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: statusAction) {
                Text(actionTitle)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        switch status {
        case .active: return "Active"
        case .pendingSent: return "Waiting"
        case .pendingReceived: return "Needs approval"
        }
    }

    private var actionTitle: String {
        switch status {
        case .active: return "Open chat"
        case .pendingSent: return "View request"
        case .pendingReceived: return "Review request"
        }
    }
}

struct OnboardingContainer: View {
    enum Stage {
        case name, explain
    }

    @State private var stage: Stage = .name
    @State private var displayName: String
    let finish: (String) -> Void

    init(initialName: String, finish: @escaping (String) -> Void) {
        _displayName = State(initialValue: initialName)
        self.finish = finish
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()
                switch stage {
                case .name:
                    NameEntryStage(name: $displayName) {
                        withAnimation(.spring()) {
                            stage = .explain
                        }
                    }
                case .explain:
                    ExplanationStage(name: displayName) {
                        var trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { trimmed = "Someone Nearby" }
                        finish(trimmed)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct NameEntryStage: View {
    @Binding var name: String
    let continueAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a name")
                .font(.largeTitle).bold()
            Text("This name stays on this iPhone. It helps nearby people recognize you.")
                .font(.body)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $name)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
            Button(action: continueAction) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("continueButton")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct ExplanationStage: View {
    let name: String
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ready to connect, \(name.isEmpty ? "someone nearby" : name)?")
                .font(.largeTitle).bold()
            VStack(alignment: .leading, spacing: 12) {
                labeledPoint(icon: "antenna.radiowaves.left.and.right", text: "Works without internet – Bluetooth only")
                labeledPoint(icon: "lock.shield", text: "Messages never leave your device")
                labeledPoint(icon: "person.crop.circle.badge.checkmark", text: "You control who can contact you")
            }
            Button(action: finish) {
                Text("Start scanning")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func labeledPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(.tint)
            Text(text)
        }
    }
}

// Old scanning components removed in favor of NearbyScanLayout.

struct ChatView: View {
    let peer: DiscoveredPeer
    @ObservedObject var store: ConversationStore
    let expiration: TimeInterval
    let isBlocked: Bool
    let sendAction: (String) -> Void
    let blockAction: () -> Void
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(peer.name)
                    .font(.title2.bold())
                Label("Secure session active", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Messages disappear in \(expirationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if isBlocked {
                Label("Blocked – unblock from Privacy & Safety", systemImage: "hand.raised")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                HStack(spacing: 12) {
                    TextField("Message", text: $message, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        sendAction(trimmed)
                        message = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .padding(10)
                            .background(Circle().fill(.tint))
                            .foregroundStyle(.white)
                    }
                }
                .padding()
            }

            Button(role: .destructive) {
                blockAction()
            } label: {
                Label("Block this identity", systemImage: "hand.raised.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding([.horizontal, .bottom])
            .disabled(isBlocked)
        }
        .presentationDetents([.large])
    }

    private var expirationText: String {
        let hours = Int(expiration / 3600)
        return "\(hours)h"
    }

    private var messages: [Message] {
        store.messages(for: peer.identity.uuid)
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(12)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isOutgoing { Spacer() }
        }
        .transition(.move(edge: message.isOutgoing ? .trailing : .leading).combined(with: .opacity))
    }

    private var bubbleColor: Color {
        message.isOutgoing ? Color.accentColor : Color(.secondarySystemBackground)
    }
}

struct PrivacySafetyView: View {
    @Environment(\.dismiss) private var dismiss
    let blocked: [Conversation]
    let expiration: TimeInterval
    let updateExpiration: (TimeInterval) -> Void
    let unblock: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Data Residency")) {
                    Label("Messages stay on this iPhone only", systemImage: "lock.circle")
                    Label("No analytics, no tracking, no uploads", systemImage: "nosign")
                }

                Section(header: Text("Expiration")) {
                    Picker("Messages disappear after", selection: Binding(get: {
                        expiration
                    }, set: { newValue in
                        updateExpiration(newValue)
                    })) {
                        Text("6 hours").tag(TimeInterval(6 * 3600))
                        Text("24 hours").tag(TimeInterval(24 * 3600))
                        Text("72 hours").tag(TimeInterval(72 * 3600))
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Blocked identities")) {
                    if blocked.isEmpty {
                        Text("No one is blocked.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(blocked) { conversation in
                            HStack {
                                Text(conversation.peerName)
                                Spacer()
                                Button("Unblock") {
                                    unblock(conversation.id)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Transparency")) {
                    Text("What you send never leaves the peer devices. There is no contact graph, no history stored anywhere else.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Privacy & Safety")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
