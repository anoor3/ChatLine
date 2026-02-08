import Foundation
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class NetworkScreenModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case noResults
        case results
        case error(ScanErrorInfo)
    }

    struct DebugInfo: Equatable {
        var scanStartedAt: Date?
        var lastEventAt: Date?
        var peerCallbackCount: Int = 0
        var bluetoothState: String = "unknown"
    }

    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedDescription: String = "0s"
    @Published private(set) var lastScanFinishedAt: Date?
    @Published private(set) var debugInfo: DebugInfo = .init()

    private let discovery: PeerDiscoveryManager
    private let permission: BluetoothPermissionMonitoring
    private var hasStarted = false
    private var scanStartDate: Date?
    private var elapsedTimer: Timer?

    init(discovery: PeerDiscoveryManager, permission: BluetoothPermissionMonitoring) {
        self.discovery = discovery
        self.permission = permission
        self.debugInfo.bluetoothState = permission.stateDescription

        discovery.onPeersChanged = { [weak self] peers in
            Task { @MainActor in
                self?.handlePeerUpdate(peers)
            }
        }

        discovery.onError = { [weak self] info in
            Task { @MainActor in
                self?.handleError(info)
            }
        }

        discovery.onBluetoothStateChange = { [weak self] state in
            Task { @MainActor in
                self?.debugInfo.bluetoothState = state
            }
        }

        permission.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.debugInfo.bluetoothState = self?.permission.stateDescription ?? "unknown"
                self?.handleBluetoothState(state)
            }
        }
    }

    func beginScanningIfNeeded() {
        guard !hasStarted else { return }
        guard permission.state == .poweredOn else {
            presentBluetoothIssue(for: permission.state)
            permission.requestAuthorization()
            return
        }
        hasStarted = true
        phase = .scanning
        scanStartDate = Date()
        debugInfo.scanStartedAt = scanStartDate
        debugInfo.peerCallbackCount = 0
        debugInfo.lastEventAt = nil
        startElapsedTimer()
        discovery.start()
    }

    func stopScanning() {
        guard hasStarted else { return }
        hasStarted = false
        discovery.stop()
        endScanSession()
        phase = .idle
    }

    func restartScan() {
        stopScanning()
        beginScanningIfNeeded()
    }

    func connect(_ peer: DiscoveredPeer) {
        discovery.connect(to: peer)
    }

    func peer(with id: UUID) -> DiscoveredPeer? {
        peers.first { $0.id == id }
    }

    func handleErrorAction(_ info: ScanErrorInfo) {
        switch info.reason {
        case .bluetoothOff:
            permission.requestAuthorization()
            openSettings()
        case .permissionMissing:
            openSettings()
        case .failed:
            restartScan()
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return "Not scanning"
        case .scanning, .noResults, .results:
            return "Scanning is on"
        case .error:
            return "Scanning unavailable"
        }
    }

    var statusSubtitle: String {
        switch phase {
        case .idle:
            return "Scanning uses Bluetooth and only runs while this screen stays open."
        case .scanning:
            return "Bluetooth only • App must stay open"
        case .noResults:
            return "Scanning is active, but no nearby devices detected yet."
        case .results:
            return "Tap a name below to start a secure chat."
        case .error:
            return "Fix the issue below to resume scanning."
        }
    }

    var isActive: Bool {
        switch phase {
        case .scanning, .noResults, .results:
            return true
        default:
            return false
        }
    }

    private func handlePeerUpdate(_ peers: [DiscoveredPeer]) {
        debugInfo.peerCallbackCount += 1
        debugInfo.lastEventAt = Date()
        self.peers = peers
        if peers.isEmpty {
            phase = hasStarted ? .noResults : .idle
        } else {
            phase = .results
        }
    }

    private func handleError(_ info: ScanErrorInfo) {
        stopScanning()
        phase = .error(info)
    }

    private func handleBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if case .error = phase {
                phase = .idle
            }
        default:
            presentBluetoothIssue(for: state)
        }
    }

    private func presentBluetoothIssue(for state: CBManagerState) {
        guard let info = ScanErrorInfo.make(from: state) else { return }
        phase = .error(info)
    }

    private func openSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
    }

    private func endScanSession() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        lastScanFinishedAt = Date()
        elapsedDescription = "0s"
        scanStartDate = nil
    }

    private func updateElapsed() {
        guard let start = scanStartDate else {
            elapsedDescription = "0s"
            return
        }
        let interval = Date().timeIntervalSince(start)
        elapsedDescription = Self.elapsedFormatter.string(from: interval) ?? "\(Int(interval))s"
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
