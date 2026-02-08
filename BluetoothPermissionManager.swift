import Foundation
import CoreBluetooth

protocol BluetoothPermissionMonitoring: AnyObject {
    var stateDescription: String { get }
    var state: CBManagerState { get }
    var onStateChange: ((CBManagerState) -> Void)? { get set }
    func requestAuthorization()
}

final class BluetoothPermissionManager: NSObject, BluetoothPermissionMonitoring {
    private var centralManager: CBCentralManager?
    private(set) var state: CBManagerState = .unknown {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((CBManagerState) -> Void)?

    var stateDescription: String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .resetting: return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        default: return "unknown"
        }
    }

    func requestAuthorization() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            centralManager?.delegate = self
        }
    }
}

extension BluetoothPermissionManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
    }
}
