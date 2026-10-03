import Foundation
import Network

/// 局域网扫描：mDNS 发现无线调试服务
/// 服务类型：
///   _adb-tls-pairing._tcp  - 配对服务（37000 端口）
///   _adb-tls-connect._tcp   - 连接服务（无线调试端口）
final class DeviceScanner: ObservableObject {
    struct ScannedDevice: Identifiable, Equatable {
        let name: String
        let host: String
        let port: Int
        let isPairingService: Bool

        var id: String { "\(host):\(port):\(isPairingService)" }
    }

    @Published private(set) var devices: [ScannedDevice] = []
    @Published private(set) var isScanning = false

    var onLog: ((String) -> Void)?

    private var pairingBrowser: NWBrowser?
    private var connectBrowser: NWBrowser?

    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        devices.removeAll()

        pairingBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-pairing._tcp", domain: "local"), using: .tcp)
        connectBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local"), using: .tcp)

        pairingBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results, isPairing: true)
        }
        connectBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results, isPairing: false)
        }
        pairingBrowser?.start(queue: .global())
        connectBrowser?.start(queue: .global())

        // 5 秒后自动停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.stopScanning()
        }
    }

    func stopScanning() {
        pairingBrowser?.cancel()
        connectBrowser?.cancel()
        pairingBrowser = nil
        connectBrowser = nil
        isScanning = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, isPairing: Bool) {
        var found: [ScannedDevice] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .hostPort(let host, let port)? = result.endpoint.destination?() else { continue }
            let device = ScannedDevice(name: name, host: "\(host)", port: Int(port.rawValue), isPairingService: isPairing)
            if !found.contains(device) {
                found.append(device)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for device in found where !self.devices.contains(device) {
                self.devices.append(device)
                self.onLog?("扫描到设备: \(device.name) \(device.host):\(device.port) \(isPairing ? "(配对)" : "(连接)")")
            }
        }
    }
}
