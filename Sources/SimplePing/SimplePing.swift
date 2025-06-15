import Foundation
import Network

/// Controls the IP address version used by SimplePing instances
public enum SimplePingAddressStyle {
    /// Use the first IPv4 or IPv6 address found (default)
    case any
    /// Use the first IPv4 address found
    case icmpv4
    /// Use the first IPv6 address found
    case icmpv6
}

/// Errors that can occur during ping operations
public enum SimplePingError: Error, LocalizedError {
    case invalidHostName
    case noAddressFound
    case socketCreationFailed
    case bindFailed
    case sendFailed
    case receiveFailed
    case invalidPacket
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidHostName:
            return "Invalid host name provided"
        case .noAddressFound:
            return "No suitable address found for host"
        case .socketCreationFailed:
            return "Failed to create socket"
        case .bindFailed:
            return "Failed to bind socket"
        case .sendFailed:
            return "Failed to send ping packet"
        case .receiveFailed:
            return "Failed to receive ping response"
        case .invalidPacket:
            return "Received invalid packet"
        case .timeout:
            return "Ping operation timed out"
        }
    }
}

/// A modern Swift implementation of ping functionality using BSD sockets
@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
public final class SimplePing: @unchecked Sendable {
    
    // MARK: - Public Properties
    
    /// The host name being pinged
    public let hostName: String
    
    /// The delegate for receiving ping events
    public weak var delegate: SimplePingDelegate?
    
    /// Controls the IP address version used
    public var addressStyle: SimplePingAddressStyle = .any
    
    /// The resolved host address
    public private(set) var hostAddress: Data?
    
    /// The address family of the host address
    public var hostAddressFamily: sa_family_t {
        guard let hostAddress = hostAddress,
              hostAddress.count >= MemoryLayout<sockaddr>.size else {
            return sa_family_t(AF_UNSPEC)
        }
        
        return hostAddress.withUnsafeBytes { bytes in
            bytes.load(as: sockaddr.self).sa_family
        }
    }
    
    /// Unique identifier for this ping instance
    public let identifier: UInt16
    
    /// The next sequence number to be used
    public private(set) var nextSequenceNumber: UInt16 = 0
    
    // MARK: - Private Properties
    
    private var isStarted = false
    private var nextSequenceNumberHasWrapped = false
    private let queue = DispatchQueue(label: "com.simpleping.queue", qos: .userInitiated)
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var sendTimes: [UInt16: Date] = [:]
    
    // MARK: - Initialization
    
    /// Initialize a new SimplePing instance
    /// - Parameter hostName: The host name or IP address to ping
    public init(hostName: String) {
        self.hostName = hostName
        self.identifier = UInt16.random(in: 0...UInt16.max)
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    /// Starts the ping operation
    public func start() {
        guard !isStarted else { return }
        
        queue.async { [weak self] in
            self?.startInternal()
        }
    }
    
    /// Sends a ping packet with optional custom data
    /// - Parameter data: Custom data to include in the ping packet, or nil for default payload
    public func sendPing(with data: Data? = nil) {
        queue.async { [weak self] in
            self?.sendPingInternal(with: data)
        }
    }
    
    /// Stops the ping operation
    public func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }
    
    // MARK: - Private Methods
    
    private func startInternal() {
        guard !isStarted else { return }
        
        isStarted = true
        
        // Resolve hostname first
        resolveHostname { [weak self] result in
            switch result {
            case .success(let address):
                self?.hostAddress = address
                self?.createSocket()
            case .failure(let error):
                self?.handleError(error)
            }
        }
    }
    
    private func resolveHostname(completion: @escaping (Result<Data, Error>) -> Void) {
        // Try to parse as IP address first
        if let ipv4 = IPv4Address(hostName) {
            let address = createSocketAddress(from: ipv4)
            completion(.success(address))
            return
        }
        
        if let ipv6 = IPv6Address(hostName) {
            let address = createSocketAddress(from: ipv6)
            completion(.success(address))
            return
        }
        
        // Use getaddrinfo for hostname resolution
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostName, nil, &hints, &result)
        
        guard status == 0, let addrInfo = result else {
            completion(.failure(SimplePingError.noAddressFound))
            return
        }
        
        defer { freeaddrinfo(result) }
        
        // Find the first suitable address
        var current: UnsafeMutablePointer<addrinfo>? = addrInfo
        while let currentAddr = current {
            let family = currentAddr.pointee.ai_family
            
            if (addressStyle == .any) ||
               (addressStyle == .icmpv4 && family == AF_INET) ||
               (addressStyle == .icmpv6 && family == AF_INET6) {
                
                let addressData = Data(bytes: currentAddr.pointee.ai_addr,
                                     count: Int(currentAddr.pointee.ai_addrlen))
                completion(.success(addressData))
                return
            }
            
            current = currentAddr.pointee.ai_next
        }
        
        completion(.failure(SimplePingError.noAddressFound))
    }
    
    private func createSocketAddress(from ipv4: IPv4Address) -> Data {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = ipv4.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        return Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
    }
    
    private func createSocketAddress(from ipv6: IPv6Address) -> Data {
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        let ipv6Bytes = ipv6.rawValue
        withUnsafeBytes(of: ipv6Bytes) { bytes in
            addr.sin6_addr = bytes.load(as: in6_addr.self)
        }
        
        return Data(bytes: &addr, count: MemoryLayout<sockaddr_in6>.size)
    }
    
    private func createSocket() {
        guard let hostAddress = hostAddress else {
            handleError(SimplePingError.noAddressFound)
            return
        }
        
        let family = hostAddressFamily
        let sockType: Int32
        let proto: Int32
        
        switch family {
        case sa_family_t(AF_INET):
            sockType = SOCK_DGRAM
            proto = IPPROTO_ICMP
        case sa_family_t(AF_INET6):
            sockType = SOCK_DGRAM
            proto = IPPROTO_ICMPV6
        default:
            handleError(SimplePingError.socketCreationFailed)
            return
        }
        
        socketFD = socket(Int32(family), sockType, proto)
        
        guard socketFD >= 0 else {
            handleError(SimplePingError.socketCreationFailed)
            return
        }
        
        // Set up dispatch source for reading
        source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source?.setEventHandler { [weak self] in
            self?.readData()
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
        }
        source?.resume()
        
        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.simplePing(self, didStartWithAddress: hostAddress)
        }
    }
    
    private func sendPingInternal(with data: Data?) {
        guard isStarted, socketFD >= 0, let hostAddress = hostAddress else {
            return
        }
        
        let payload = data ?? createDefaultPayload()
        let packet = createPingPacket(with: payload)
        
        // Capture sequence number and send time before sending
        let currentSequenceNumber = nextSequenceNumber
        let sendTime = Date()
        
        let bytesSent = hostAddress.withUnsafeBytes { addrBytes in
            packet.withUnsafeBytes { packetBytes in
                sendto(socketFD,
                      packetBytes.baseAddress,
                      packet.count,
                      0,
                      addrBytes.bindMemory(to: sockaddr.self).baseAddress,
                      socklen_t(hostAddress.count))
            }
        }
        
        // Store send time for RTT calculation
        sendTimes[currentSequenceNumber] = sendTime
        
        // Increment sequence number immediately after sending
        incrementSequenceNumber()
        
        if bytesSent == packet.count {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.simplePing(self, didSendPacket: packet, sequenceNumber: currentSequenceNumber)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                self.delegate?.simplePing(self, didFailToSendPacket: packet, sequenceNumber: currentSequenceNumber, error: error)
            }
        }
    }
    
    private func createDefaultPayload() -> Data {
        let payloadString = String(format: "%28d bottles of beer on the wall", 99 - Int(nextSequenceNumber % 100))
        return payloadString.data(using: .ascii) ?? Data(count: 56)
    }
    
    private func createPingPacket(with payload: Data) -> Data {
        let icmpType: UInt8
        let requiresChecksum: Bool
        
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            icmpType = ICMPType.icmpv4EchoRequest
            requiresChecksum = true
        case sa_family_t(AF_INET6):
            icmpType = ICMPType.icmpv6EchoRequest
            requiresChecksum = false
        default:
            icmpType = ICMPType.icmpv4EchoRequest
            requiresChecksum = true
        }
        
        let header = ICMPHeader(
            type: icmpType,
            code: 0,
            checksum: 0,
            identifier: identifier,
            sequenceNumber: nextSequenceNumber
        )
        
        var packet = header.toData()
        packet.append(payload)
        
        if requiresChecksum {
            let checksum = ICMPUtils.calculateChecksum(for: packet)
            packet[2] = UInt8(checksum >> 8)
            packet[3] = UInt8(checksum & 0xFF)
        }
        
        return packet
    }
    
    private func readData() {
        let bufferSize = 65535
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        var addr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        
        let bytesRead = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(socketFD, buffer, bufferSize, 0, sockaddrPtr, &addrLen)
            }
        }
        
        guard bytesRead > 0 else { return }
        
        let data = Data(bytes: buffer, count: bytesRead)
        processReceivedPacket(data)
    }
    
    private func processReceivedPacket(_ packet: Data) {
        var processedPacket = packet
        var sequenceNumber: UInt16 = 0
        
        let isValidPingResponse: Bool
        
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            isValidPingResponse = validateIPv4PingResponse(&processedPacket, sequenceNumber: &sequenceNumber)
        case sa_family_t(AF_INET6):
            isValidPingResponse = validateIPv6PingResponse(&processedPacket, sequenceNumber: &sequenceNumber)
        default:
            isValidPingResponse = false
        }
        
        // Capture values before async dispatch
        let finalProcessedPacket = processedPacket
        let finalSequenceNumber = sequenceNumber
        let originalPacket = packet
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if isValidPingResponse {
                // Check if we have timing information for this sequence number
                if let sendTime = self.sendTimes.removeValue(forKey: finalSequenceNumber) {
                    let timeInterval = Date().timeIntervalSince(sendTime)
                    self.delegate?.simplePing(self, didReceivePingResponsePacket: finalProcessedPacket, sequenceNumber: finalSequenceNumber, timeInterval: timeInterval)
                } else {
                    self.delegate?.simplePing(self, didReceivePingResponsePacket: finalProcessedPacket, sequenceNumber: finalSequenceNumber)
                }
            } else {
                self.delegate?.simplePing(self, didReceiveUnexpectedPacket: originalPacket)
            }
        }
    }
    
    private func validateIPv4PingResponse(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        guard let icmpOffset = ICMPUtils.icmpHeaderOffset(in: packet),
              packet.count >= icmpOffset + MemoryLayout<ICMPHeader>.size else {
            return false
        }
        
        // Extract ICMP portion
        let icmpData = packet.subdata(in: icmpOffset..<packet.count)
        guard let header = icmpData.toICMPHeader() else { return false }
        
        // Validate response
        guard header.type == ICMPType.icmpv4EchoReply,
              header.code == 0,
              header.identifier == identifier,
              validateSequenceNumber(header.sequenceNumber) else {
            return false
        }
        
        // Remove IPv4 header
        packet = icmpData
        sequenceNumber = header.sequenceNumber
        return true
    }
    
    private func validateIPv6PingResponse(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        guard let header = packet.toICMPHeader() else { return false }
        
        guard header.type == ICMPType.icmpv6EchoReply,
              header.code == 0,
              header.identifier == identifier,
              validateSequenceNumber(header.sequenceNumber) else {
            return false
        }
        
        sequenceNumber = header.sequenceNumber
        return true
    }
    
    private func validateSequenceNumber(_ sequenceNumber: UInt16) -> Bool {
        if nextSequenceNumberHasWrapped {
            return (nextSequenceNumber &- sequenceNumber) < 120
        } else {
            return sequenceNumber < nextSequenceNumber
        }
    }
    
    private func incrementSequenceNumber() {
        nextSequenceNumber = nextSequenceNumber &+ 1
        if nextSequenceNumber == 0 {
            nextSequenceNumberHasWrapped = true
        }
    }
    
    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.simplePing(self, didFailWithError: error)
        }
        cleanup()
    }
    
    private func stopInternal() {
        guard isStarted else { return }
        cleanup()
    }
    
    private func cleanup() {
        isStarted = false
        source?.cancel()
        source = nil
        hostAddress = nil
        sendTimes.removeAll()
    }
}