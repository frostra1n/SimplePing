import Foundation

/// ICMP packet header structure for both IPv4 and IPv6
public struct ICMPHeader {
    public var type: UInt8
    public var code: UInt8
    public var checksum: UInt16
    public var identifier: UInt16
    public var sequenceNumber: UInt16
    
    public init(type: UInt8, code: UInt8, checksum: UInt16, identifier: UInt16, sequenceNumber: UInt16) {
        self.type = type
        self.code = code
        self.checksum = checksum
        self.identifier = identifier
        self.sequenceNumber = sequenceNumber
    }
}

/// IPv4 packet header structure
struct IPv4Header {
    var versionAndHeaderLength: UInt8
    var differentiatedServices: UInt8
    var totalLength: UInt16
    var identification: UInt16
    var flagsAndFragmentOffset: UInt16
    var timeToLive: UInt8
    var `protocol`: UInt8
    var headerChecksum: UInt16
    var sourceAddress: (UInt8, UInt8, UInt8, UInt8)
    var destinationAddress: (UInt8, UInt8, UInt8, UInt8)
}

/// ICMP type constants
public enum ICMPType {
    /// ICMPv4 Echo Request type
    public static let icmpv4EchoRequest: UInt8 = 8
    /// ICMPv4 Echo Reply type
    public static let icmpv4EchoReply: UInt8 = 0
    /// ICMPv6 Echo Request type
    public static let icmpv6EchoRequest: UInt8 = 128
    /// ICMPv6 Echo Reply type
    public static let icmpv6EchoReply: UInt8 = 129
}

/// Utility functions for ICMP operations
public enum ICMPUtils {
    
    /// Calculates the Internet Checksum for ICMP packets (IPv4 only)
    /// 
    /// The Internet Checksum is calculated by:
    /// 1. Treating the data as a sequence of 16-bit words in network byte order
    /// 2. Summing all these words with carry propagation
    /// 3. Taking the one's complement of the final sum
    /// 
    /// - Parameter data: The packet data to calculate checksum for
    /// - Returns: The calculated checksum in network byte order
    public static func calculateChecksum(for data: Data) -> UInt16 {
        guard !data.isEmpty else { return 0xFFFF }
        
        var runningSum: UInt32 = 0
        var byteIndex = 0
        
        // Process data in 16-bit chunks (network byte order: big-endian)
        while byteIndex < data.count - 1 {
            let highByte = UInt16(data[byteIndex]) << 8
            let lowByte = UInt16(data[byteIndex + 1])
            let word = highByte + lowByte
            runningSum += UInt32(word)
            byteIndex += 2
        }
        
        // Handle any remaining odd byte by padding with zero
        if byteIndex < data.count {
            let paddedByte = UInt16(data[byteIndex]) << 8
            runningSum += UInt32(paddedByte)
        }
        
        // Fold carry bits back into the sum (handle overflow)
        while (runningSum >> 16) != 0 {
            runningSum = (runningSum & 0xFFFF) + (runningSum >> 16)
        }
        
        // Return the one's complement of the final sum
        return UInt16(~runningSum & 0xFFFF)
    }
    
    /// Finds the offset of the ICMP header within an IPv4 packet
    /// 
    /// IPv4 packets have a variable-length header (20-60 bytes) followed by the payload.
    /// For ping packets, the payload is the ICMP header and data.
    /// This function parses the IPv4 header to find where the ICMP portion begins.
    /// 
    /// - Parameter packet: The complete IPv4 packet data received from the network
    /// - Returns: The byte offset where the ICMP header starts, or nil if not a valid IPv4 ICMP packet
    public static func icmpHeaderOffset(in packet: Data) -> Int? {
        // Ensure packet is large enough to contain both IPv4 and ICMP headers
        let minimumPacketSize = MemoryLayout<IPv4Header>.size + MemoryLayout<ICMPHeader>.size
        guard packet.count >= minimumPacketSize else { return nil }
        
        // Parse the IPv4 header from the beginning of the packet
        let ipv4Header = packet.withUnsafeBytes { $0.load(as: IPv4Header.self) }
        
        // Verify this is an IPv4 packet (version = 4) with ICMP payload (protocol = 1)
        let ipVersion = (ipv4Header.versionAndHeaderLength & 0xF0) >> 4
        let protocolICMP: UInt8 = 1
        guard ipVersion == 4, ipv4Header.`protocol` == protocolICMP else {
            return nil
        }
        
        // Calculate IPv4 header length (lower 4 bits * 4 = header length in bytes)
        let headerLengthWords = ipv4Header.versionAndHeaderLength & 0x0F
        let ipv4HeaderLength = Int(headerLengthWords) * 4
        
        // Ensure the packet is large enough to contain the full headers
        guard packet.count >= ipv4HeaderLength + MemoryLayout<ICMPHeader>.size else {
            return nil
        }
        
        return ipv4HeaderLength
    }
}

// MARK: - Data Extensions for ICMP

extension Data {
    /// Parses ICMP header from raw packet data
    /// 
    /// ICMP headers are 8 bytes with this structure:
    /// - Type (1 byte): ICMP message type (e.g., 8 = Echo Request, 0 = Echo Reply)
    /// - Code (1 byte): ICMP message code (usually 0 for Echo Request/Reply)
    /// - Checksum (2 bytes): Internet checksum of ICMP header + data
    /// - Identifier (2 bytes): Used to match requests with replies
    /// - Sequence Number (2 bytes): Incremented for each ping sent
    /// 
    /// All multi-byte fields are in network byte order (big-endian).
    /// 
    /// - Returns: Parsed ICMPHeader or nil if data is too short
    func toICMPHeader() -> ICMPHeader? {
        guard count >= MemoryLayout<ICMPHeader>.size else { return nil }
        
        return withUnsafeBytes { rawBytes in
            // Parse each field from network byte order (big-endian)
            let type = rawBytes[0]
            let code = rawBytes[1]
            let checksum = UInt16(rawBytes[2]) << 8 | UInt16(rawBytes[3])
            let identifier = UInt16(rawBytes[4]) << 8 | UInt16(rawBytes[5])
            let sequenceNumber = UInt16(rawBytes[6]) << 8 | UInt16(rawBytes[7])
            
            return ICMPHeader(
                type: type,
                code: code,
                checksum: checksum,
                identifier: identifier,
                sequenceNumber: sequenceNumber
            )
        }
    }
}

extension ICMPHeader {
    /// Converts ICMP header structure to raw packet data
    /// 
    /// Serializes the header fields into network byte order (big-endian) for transmission.
    /// The resulting 8-byte Data can be sent over the network as part of an ICMP packet.
    /// 
    /// - Returns: 8 bytes of data representing the ICMP header in network format
    func toData() -> Data {
        var packetData = Data(capacity: MemoryLayout<ICMPHeader>.size)
        packetData.append(type)
        packetData.append(code)
        packetData.append(contentsOf: checksum.toNetworkBytes())
        packetData.append(contentsOf: identifier.toNetworkBytes())
        packetData.append(contentsOf: sequenceNumber.toNetworkBytes())
        return packetData
    }
}

// MARK: - Helper Extensions

private extension UInt16 {
    /// Converts a UInt16 to network byte order (big-endian) bytes
    func toNetworkBytes() -> [UInt8] {
        return [UInt8(self >> 8), UInt8(self & 0xFF)]
    }
}