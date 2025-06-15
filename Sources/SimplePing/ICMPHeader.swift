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
    
    /// Calculates checksum for ICMP packet (IPv4 only)
    /// - Parameters:
    ///   - data: The data to calculate checksum for
    /// - Returns: The calculated checksum in network byte order
    public static func calculateChecksum(for data: Data) -> UInt16 {
        guard !data.isEmpty else { return 0xFFFF }
        
        var sum: UInt32 = 0
        var index = 0
        
        // Sum all 16-bit words
        while index < data.count - 1 {
            let word = UInt16(data[index]) << 8 + UInt16(data[index + 1])
            sum += UInt32(word)
            index += 2
        }
        
        // Handle odd byte if present
        if index < data.count {
            let lastByte = UInt16(data[index]) << 8
            sum += UInt32(lastByte)
        }
        
        // Add carry bits
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        
        // One's complement
        return UInt16(~sum & 0xFFFF)
    }
    
    /// Finds the offset of ICMP header in IPv4 packet
    /// - Parameter packet: The IPv4 packet data
    /// - Returns: The offset of ICMP header, or nil if not found
    public static func icmpHeaderOffset(in packet: Data) -> Int? {
        guard packet.count >= MemoryLayout<IPv4Header>.size + MemoryLayout<ICMPHeader>.size else {
            return nil
        }
        
        let ipHeader = packet.withUnsafeBytes { $0.load(as: IPv4Header.self) }
        
        // Check if it's IPv4 and ICMP protocol
        guard (ipHeader.versionAndHeaderLength & 0xF0) == 0x40,
              ipHeader.`protocol` == 1 else { // IPPROTO_ICMP = 1
            return nil
        }
        
        let ipHeaderLength = Int(ipHeader.versionAndHeaderLength & 0x0F) * 4
        
        guard packet.count >= ipHeaderLength + MemoryLayout<ICMPHeader>.size else {
            return nil
        }
        
        return ipHeaderLength
    }
}

// MARK: - Data Extensions for ICMP

extension Data {
    /// Converts Data to ICMPHeader
    func toICMPHeader() -> ICMPHeader? {
        guard count >= MemoryLayout<ICMPHeader>.size else { return nil }
        
        return withUnsafeBytes { bytes in
            let type = bytes[0]
            let code = bytes[1]
            let checksum = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let identifier = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let sequenceNumber = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
            
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
    /// Converts ICMPHeader to Data
    func toData() -> Data {
        var data = Data(capacity: MemoryLayout<ICMPHeader>.size)
        data.append(type)
        data.append(code)
        data.append(contentsOf: checksum.toBytes())
        data.append(contentsOf: identifier.toBytes())
        data.append(contentsOf: sequenceNumber.toBytes())
        return data
    }
}

// MARK: - Helper Extensions

private extension UInt16 {
    func toBytes() -> [UInt8] {
        return [UInt8(self >> 8), UInt8(self & 0xFF)]
    }
}