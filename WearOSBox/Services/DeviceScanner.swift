import Foundation
import Network

/// 局域网扫描：mDNS 发现无线调试服务并解析 IP/端口
/// 服务类型：
///   _adb-tls-pairing._tcp  - 配对服务
///   _adb-tls-connect._tcp   - 连接服务
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
    private var resolveQueue = DispatchQueue(label: "scanner.resolve.queue")

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

        // 8 秒后自动停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
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
        for result in results {
            guard case .service(let name, let regType, let domain, _) = result.endpoint else { continue }
            let type = String(describing: regType)
            resolveQueue.async { [weak self] in
                guard let self = self else { return }
                // DNS-SD 解析：获取 hostname + 端口 + IPv4
                if let resolved = BonjourResolver.resolve(name: name, regType: type, domain: String(describing: domain)) {
                    let ip = resolved.ipv4 ?? resolved.hostname
                    let device = ScannedDevice(name: name,
                                               host: ip,
                                               port: Int(resolved.port),
                                               isPairingService: isPairing)
                    DispatchQueue.main.async {
                        if !self.devices.contains(device) {
                            self.devices.append(device)
                            self.onLog?("扫描到设备: \(device.host):\(device.port) \(isPairing ? "(配对)" : "(连接)")")
                        }
                    }
                }
            }
        }
    }
}
