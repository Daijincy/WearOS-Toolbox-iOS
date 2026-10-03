import Foundation

/// DNS-SD 服务解析：将 mDNS 发现的 Bonjour 服务解析为 IP 与端口
/// 安卓无线调试的 mDNS 广播不含 IP/端口，必须通过 DNSServiceResolve 获取
/// （dns_sd.h 通过 Bridging Header 引入）
final class BonjourResolver {
    struct ResolvedService {
        let name: String
        let hostname: String
        let port: UInt16
        var ipv4: String?
    }

    /// 解析回调上下文
    private final class ResolveContext {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var hostname = ""
        var port: UInt16 = 0
        var resolvedFlag = false
        var errorCode: DNSServiceErrorType?
    }

    /// 同步解析 Bonjour 服务
    /// - Parameters:
    ///   - name: 服务名（NWBrowser 结果中的 name）
    ///   - regType: 服务类型（如 "_adb-tls-pairing._tcp"）
    ///   - domain: 域（默认 "local."）
    ///   - timeout: 总超时
    static func resolve(name: String, regType: String, domain: String = "local.",
                        timeout: TimeInterval = 3.0) -> ResolvedService? {
        var serviceRef: DNSServiceRef?
        let ctx = ResolveContext()
        let contextPtr = Unmanaged.passRetained(ctx).toOpaque()

        let callback: DNSServiceResolveReply = { _, _, _, errorCode, _, hosttarget, port, _, _, context in
            guard let context = context else { return }
            let c = Unmanaged<ResolveContext>.fromOpaque(context).takeUnretainedValue()
            if errorCode == kDNSServiceErr_NoError {
                c.lock.lock()
                c.hostname = String(cString: hosttarget)
                c.port = port.bigEndian
                c.resolvedFlag = true
                c.lock.unlock()
            } else {
                c.errorCode = errorCode
            }
            c.semaphore.signal()
        }

        let err = DNSServiceResolve(&serviceRef, 0, 0, name, regType, domain, callback, contextPtr)
        guard err == kDNSServiceErr_NoError, let ref = serviceRef else {
            Unmanaged<ResolveContext>.fromOpaque(contextPtr).release()
            return nil
        }

        // 轮询 socket 直到回调或超时
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ctx.resolvedFlag || ctx.errorCode != nil { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 100)
            if ret > 0 {
                DNSServiceProcessResult(ref)
            } else if ret < 0 {
                break
            }
        }
        DNSServiceRefDeallocate(ref)
        Unmanaged<ResolveContext>.fromOpaque(contextPtr).release()

        guard ctx.resolvedFlag else { return nil }
        var service = ResolvedService(name: name, hostname: ctx.hostname, port: ctx.port)
        service.ipv4 = resolveIPv4(hostname: ctx.hostname, timeout: 1.5)
        return service
    }

    /// 解析主机名对应的 IPv4 地址
    private static func resolveIPv4(hostname: String, timeout: TimeInterval) -> String? {
        var addrRef: DNSServiceRef?
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        let lock = NSLock()

        let contextPtr = Unmanaged.passRetained(AddrContext(semaphore: semaphore, lock: lock)).toOpaque()
        let callback: DNSServiceGetAddrInfoReply = { _, _, _, errorCode, _, sockaddr, _, context in
            guard let context = context, let sockaddr = sockaddr else { return }
            let c = Unmanaged<AddrContext>.fromOpaque(context).takeUnretainedValue()
            if errorCode == kDNSServiceErr_NoError && sockaddr.pointee.sa_family == sa_family_t(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr4 = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                _ = inet_ntop(AF_INET, &addr4.sin_addr, &buffer, socklen_t(buffer.count))
                let ip = String(cString: buffer)
                c.lock.lock()
                if result == nil { result = ip }
                c.lock.unlock()
            }
            c.semaphore.signal()
        }

        let err = DNSServiceGetAddrInfo(&addrRef, 0, 0, kDNSServiceProtocol_IPv4,
                                        hostname, callback, contextPtr)
        guard err == kDNSServiceErr_NoError, let ref = addrRef else {
            Unmanaged<AddrContext>.fromOpaque(contextPtr).release()
            return nil
        }

        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 100)
            if ret > 0 {
                DNSServiceProcessResult(ref)
            } else if ret < 0 {
                break
            }
        }
        DNSServiceRefDeallocate(ref)
        Unmanaged<AddrContext>.fromOpaque(contextPtr).release()
        return result
    }

    private final class AddrContext {
        let semaphore: DispatchSemaphore
        let lock: NSLock
        init(semaphore: DispatchSemaphore, lock: NSLock) {
            self.semaphore = semaphore
            self.lock = lock
        }
    }
}
