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
    
    /// Resolves the hostname to a socket address
    /// 
    /// This method handles three types of input:
    /// 1. IPv4 addresses (e.g., "192.168.1.1")
    /// 2. IPv6 addresses (e.g., "2001:db8::1")  
    /// 3. Domain names (e.g., "example.com")
    /// 
    /// For domain names, it uses the system's DNS resolution via getaddrinfo().
    private func resolveHostname(completion: @escaping (Result<Data, Error>) -> Void) {
        // First, try to parse as a direct IP address (faster than DNS lookup)
        if let directAddress = parseDirectIPAddress() {
            completion(.success(directAddress))
            return
        }
        
        // If not a direct IP, resolve the hostname via DNS
        resolveDomainName(completion: completion)
    }
    
    /// Attempts to parse the hostname as a direct IPv4 or IPv6 address
    private func parseDirectIPAddress() -> Data? {
        // Try IPv4 first (more common)
        if let ipv4 = IPv4Address(hostName) {
            return createSocketAddress(from: ipv4)
        }
        
        // Try IPv6
        if let ipv6 = IPv6Address(hostName) {
            return createSocketAddress(from: ipv6)
        }
        
        return nil
    }
    
    /// Resolves a domain name to an IP address using the system's DNS resolver
    private func resolveDomainName(completion: @escaping (Result<Data, Error>) -> Void) {
        // Configure DNS resolution hints
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC    // Accept both IPv4 and IPv6
        hints.ai_socktype = SOCK_DGRAM // UDP socket type (for ICMP)
        
        // Perform DNS resolution
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostName, nil, &hints, &result)
        
        guard status == 0, let addrInfo = result else {
            completion(.failure(SimplePingError.noAddressFound))
            return
        }
        
        defer { freeaddrinfo(result) }
        
        // Find the first address that matches our preferred address style
        if let matchingAddress = findMatchingAddress(from: addrInfo) {
            completion(.success(matchingAddress))
        } else {
            completion(.failure(SimplePingError.noAddressFound))
        }
    }
    
    /// Finds the first address from DNS results that matches the configured address style
    private func findMatchingAddress(from addrInfo: UnsafeMutablePointer<addrinfo>) -> Data? {
        var current: UnsafeMutablePointer<addrinfo>? = addrInfo
        
        while let currentAddr = current {
            let family = currentAddr.pointee.ai_family
            
            let isMatchingFamily = (addressStyle == .any) ||
                                  (addressStyle == .icmpv4 && family == AF_INET) ||
                                  (addressStyle == .icmpv6 && family == AF_INET6)
            
            if isMatchingFamily {
                return Data(bytes: currentAddr.pointee.ai_addr,
                           count: Int(currentAddr.pointee.ai_addrlen))
            }
            
            current = currentAddr.pointee.ai_next
        }
        
        return nil
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
    
    /// Creates and configures a raw ICMP socket for sending/receiving ping packets
    /// 
    /// Raw sockets require special privileges and allow direct access to ICMP protocol.
    /// This method creates the socket, sets up async reading, and notifies the delegate.
    private func createSocket() {
        guard let hostAddress = hostAddress else {
            handleError(SimplePingError.noAddressFound)
            return
        }
        
        let family = hostAddressFamily
        let socketType: Int32
        let protocolType: Int32
        
        // Configure socket parameters based on IP version
        switch family {
        case sa_family_t(AF_INET):
            socketType = SOCK_DGRAM        // Datagram socket for IPv4
            protocolType = IPPROTO_ICMP    // ICMP protocol for IPv4
        case sa_family_t(AF_INET6):
            socketType = SOCK_DGRAM        // Datagram socket for IPv6  
            protocolType = IPPROTO_ICMPV6  // ICMPv6 protocol for IPv6
        default:
            handleError(SimplePingError.socketCreationFailed)
            return
        }
        
        // Create the raw socket (requires elevated privileges on most systems)
        socketFD = socket(Int32(family), socketType, protocolType)
        
        guard socketFD >= 0 else {
            handleError(SimplePingError.socketCreationFailed)
            return
        }
        
        // Set up asynchronous socket reading using Grand Central Dispatch
        // This allows the app to be notified when ping responses arrive
        source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        
        // When data is available to read, call our readData() method
        source?.setEventHandler { [weak self] in
            self?.readData()
        }
        
        // When the source is cancelled, clean up the socket file descriptor
        source?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
        }
        
        // Start monitoring the socket for incoming data
        source?.resume()
        
        // Notify the delegate that ping is ready to send packets
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
    
    /// Validates an IPv4 ping response packet
    /// 
    /// IPv4 packets include both an IP header and ICMP header, so we need to:
    /// 1. Find where the ICMP header starts within the IPv4 packet
    /// 2. Extract just the ICMP portion for processing
    /// 3. Validate the ICMP echo reply fields
    private func validateIPv4PingResponse(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        // Find the ICMP header within the IPv4 packet
        guard let icmpOffset = ICMPUtils.icmpHeaderOffset(in: packet),
              packet.count >= icmpOffset + MemoryLayout<ICMPHeader>.size else {
            return false
        }
        
        // Extract just the ICMP portion (header + payload)
        let icmpData = packet.subdata(in: icmpOffset..<packet.count)
        guard let icmpHeader = icmpData.toICMPHeader() else { return false }
        
        // Validate this is our ping response
        guard isValidPingResponse(header: icmpHeader, expectedReplyType: ICMPType.icmpv4EchoReply) else {
            return false
        }
        
        // Strip the IPv4 header, leaving only ICMP data for the caller
        packet = icmpData
        sequenceNumber = icmpHeader.sequenceNumber
        return true
    }
    
    /// Validates an IPv6 ping response packet
    /// 
    /// IPv6 packets are delivered with the ICMP header at the beginning,
    /// so no header stripping is needed (the OS handles the IPv6 header).
    private func validateIPv6PingResponse(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        guard let icmpHeader = packet.toICMPHeader() else { return false }
        
        // Validate this is our ping response  
        guard isValidPingResponse(header: icmpHeader, expectedReplyType: ICMPType.icmpv6EchoReply) else {
            return false
        }
        
        sequenceNumber = icmpHeader.sequenceNumber
        return true
    }
    
    /// Checks if an ICMP header represents a valid ping response for this instance
    private func isValidPingResponse(header: ICMPHeader, expectedReplyType: UInt8) -> Bool {
        return header.type == expectedReplyType &&       // Correct reply type (0 for IPv4, 129 for IPv6)
               header.code == 0 &&                       // Code should always be 0 for echo replies
               header.identifier == identifier &&        // Must match our unique identifier  
               validateSequenceNumber(header.sequenceNumber) // Must be a sequence we sent
    }
    
    /// Validates that a received sequence number is one we actually sent
    /// 
    /// Sequence numbers are 16-bit values that start at 0 and increment with each ping.
    /// After 65535, they wrap back to 0. We accept responses for recently sent pings
    /// to handle out-of-order or delayed network responses.
    /// 
    /// - Parameter sequenceNumber: The sequence number from a received ping response
    /// - Returns: true if this sequence number represents a ping we sent recently
    private func validateSequenceNumber(_ receivedSequenceNumber: UInt16) -> Bool {
        if nextSequenceNumberHasWrapped {
            // After wraparound, accept sequence numbers within a reasonable window
            // This handles the case where we've sent 65536+ pings
            let difference = nextSequenceNumber &- receivedSequenceNumber
            return difference < 120  // Accept responses from last ~120 pings
        } else {
            // Before wraparound, simply check if sequence number is less than next expected
            return receivedSequenceNumber < nextSequenceNumber
        }
    }
    
    /// Increments the sequence number for the next ping, handling 16-bit wraparound
    /// 
    /// ICMP sequence numbers are 16-bit fields (0-65535). After reaching the maximum,
    /// they wrap back to 0. We track when this happens to correctly validate responses.
    private func incrementSequenceNumber() {
        nextSequenceNumber = nextSequenceNumber &+ 1  // Wrapping addition
        
        // Track when we've wrapped around from 65535 back to 0
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