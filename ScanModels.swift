import Foundation
import CoreBluetooth

struct ScanErrorInfo: Identifiable, Equatable {
    enum Reason: Equatable {
        case bluetoothOff
        case permissionMissing
        case failed(String)
    }

    let id = UUID()
    let reason: Reason
    let message: String
    let actionTitle: String

    static func make(from state: CBManagerState) -> ScanErrorInfo? {
        switch state {
        case .poweredOff:
            return ScanErrorInfo(reason: .bluetoothOff,
                                 message: "Bluetooth is off. Turn it on from Control Center to scan nearby.",
                                 actionTitle: "Open Settings")
        case .unauthorized:
            return ScanErrorInfo(reason: .permissionMissing,
                                 message: "Bluetooth permission is required to discover nearby phones.",
                                 actionTitle: "Allow in Settings")
        case .unsupported:
            return ScanErrorInfo(reason: .failed("unsupported"),
                                 message: "This device doesn’t support Bluetooth scanning.",
                                 actionTitle: "OK")
        case .resetting:
            return ScanErrorInfo(reason: .failed("resetting"),
                                 message: "Bluetooth is resetting. Try again in a moment.",
                                 actionTitle: "Try again")
        case .unknown:
            return ScanErrorInfo(reason: .failed("unknown"),
                                 message: "Bluetooth state is unknown. Try again.",
                                 actionTitle: "Try again")
        default:
            return nil
        }
    }
}
