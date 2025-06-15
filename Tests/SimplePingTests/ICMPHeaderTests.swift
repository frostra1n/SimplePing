import XCTest
@testable import SimplePing

final class ICMPHeaderTests: XCTestCase {
    
    // MARK: - ICMPHeader Tests
    
    func testICMPHeaderInitialization() {
        let header = ICMPHeader(
            type: 8,
            code: 0,
            checksum: 0x1234,
            identifier: 0x5678,
            sequenceNumber: 0x9ABC
        )
        
        XCTAssertEqual(header.type, 8)
        XCTAssertEqual(header.code, 0)
        XCTAssertEqual(header.checksum, 0x1234)
        XCTAssertEqual(header.identifier, 0x5678)
        XCTAssertEqual(header.sequenceNumber, 0x9ABC)
    }
    
    func testICMPHeaderToData() {
        let header = ICMPHeader(
            type: 8,
            code: 0,
            checksum: 0x1234,
            identifier: 0x5678,
            sequenceNumber: 0x9ABC
        )
        
        let data = header.toData()
        XCTAssertEqual(data.count, 8) // ICMPHeader should be 8 bytes
        
        // Verify byte order (big endian)
        XCTAssertEqual(data[0], 8)    // type
        XCTAssertEqual(data[1], 0)    // code
        XCTAssertEqual(data[2], 0x12) // checksum high byte
        XCTAssertEqual(data[3], 0x34) // checksum low byte
        XCTAssertEqual(data[4], 0x56) // identifier high byte
        XCTAssertEqual(data[5], 0x78) // identifier low byte
        XCTAssertEqual(data[6], 0x9A) // sequence number high byte
        XCTAssertEqual(data[7], 0xBC) // sequence number low byte
    }
    
    func testDataToICMPHeader() {
        let data = Data([0x08, 0x00, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])
        
        guard let header = data.toICMPHeader() else {
            XCTFail("Failed to convert data to ICMPHeader")
            return
        }
        
        XCTAssertEqual(header.type, 8)
        XCTAssertEqual(header.code, 0)
        XCTAssertEqual(header.checksum, 0x1234)
        XCTAssertEqual(header.identifier, 0x5678)
        XCTAssertEqual(header.sequenceNumber, 0x9ABC)
    }
    
    func testDataToICMPHeaderInsufficientData() {
        let shortData = Data([0x08, 0x00, 0x12]) // Only 3 bytes
        XCTAssertNil(shortData.toICMPHeader())
    }
    
    func testICMPHeaderRoundTrip() {
        let originalHeader = ICMPHeader(
            type: 129,
            code: 0,
            checksum: 0xABCD,
            identifier: 0x1234,
            sequenceNumber: 0x5678
        )
        
        let data = originalHeader.toData()
        guard let convertedHeader = data.toICMPHeader() else {
            XCTFail("Failed to convert data back to ICMPHeader")
            return
        }
        
        XCTAssertEqual(originalHeader.type, convertedHeader.type)
        XCTAssertEqual(originalHeader.code, convertedHeader.code)
        XCTAssertEqual(originalHeader.checksum, convertedHeader.checksum)
        XCTAssertEqual(originalHeader.identifier, convertedHeader.identifier)
        XCTAssertEqual(originalHeader.sequenceNumber, convertedHeader.sequenceNumber)
    }
    
    // MARK: - ICMPType Tests
    
    func testICMPTypeConstants() {
        XCTAssertEqual(ICMPType.icmpv4EchoRequest, 8)
        XCTAssertEqual(ICMPType.icmpv4EchoReply, 0)
        XCTAssertEqual(ICMPType.icmpv6EchoRequest, 128)
        XCTAssertEqual(ICMPType.icmpv6EchoReply, 129)
    }
    
    // MARK: - ICMPUtils Tests
    
    func testChecksumCalculation() {
        // Test with known values
        let data = Data([0x08, 0x00, 0x00, 0x00, 0x12, 0x34, 0x00, 0x01])
        let checksum = ICMPUtils.calculateChecksum(for: data)
        
        // The checksum should be non-zero for this data
        XCTAssertNotEqual(checksum, 0)
        
        // Test that checksum is consistent
        let checksum2 = ICMPUtils.calculateChecksum(for: data)
        XCTAssertEqual(checksum, checksum2)
    }
    
    func testChecksumWithEmptyData() {
        let emptyData = Data()
        let checksum = ICMPUtils.calculateChecksum(for: emptyData)
        XCTAssertEqual(checksum, 0xFFFF) // All 1s inverted should be 0xFFFF
    }
    
    func testChecksumWithOddLength() {
        let oddData = Data([0x12, 0x34, 0x56]) // 3 bytes
        let checksum = ICMPUtils.calculateChecksum(for: oddData)
        XCTAssertNotEqual(checksum, 0)
    }
    
    func testICMPHeaderOffsetInvalidPacket() {
        let shortPacket = Data([0x45, 0x00]) // Too short
        XCTAssertNil(ICMPUtils.icmpHeaderOffset(in: shortPacket))
    }
    
    func testICMPHeaderOffsetNonIPv4() {
        // Create a packet that doesn't start with IPv4 header
        var packet = Data(count: 28) // Minimum size for IPv4 + ICMP
        packet[0] = 0x60 // IPv6 version instead of IPv4
        
        XCTAssertNil(ICMPUtils.icmpHeaderOffset(in: packet))
    }
    
    func testICMPHeaderOffsetNonICMP() {
        // Create a valid IPv4 header but with wrong protocol
        var packet = Data(count: 28)
        packet[0] = 0x45  // IPv4, 20-byte header
        packet[9] = 6     // TCP protocol instead of ICMP (1)
        
        XCTAssertNil(ICMPUtils.icmpHeaderOffset(in: packet))
    }
    
    func testICMPHeaderOffsetValidPacket() {
        // Create a minimal valid IPv4 + ICMP packet
        var packet = Data(count: 28)
        packet[0] = 0x45  // IPv4, 20-byte header
        packet[9] = 1     // ICMP protocol
        
        let offset = ICMPUtils.icmpHeaderOffset(in: packet)
        XCTAssertEqual(offset, 20) // Standard IPv4 header size
    }
    
    func testICMPHeaderOffsetWithOptions() {
        // Create IPv4 header with options (24-byte header)
        var packet = Data(count: 32)
        packet[0] = 0x46  // IPv4, 24-byte header (6 * 4 = 24)
        packet[9] = 1     // ICMP protocol
        
        let offset = ICMPUtils.icmpHeaderOffset(in: packet)
        XCTAssertEqual(offset, 24)
    }
    
    // MARK: - Performance Tests
    
    func testChecksumPerformance() {
        let largeData = Data(repeating: 0xAB, count: 1024)
        
        measure {
            for _ in 0..<1000 {
                _ = ICMPUtils.calculateChecksum(for: largeData)
            }
        }
    }
    
    func testHeaderConversionPerformance() {
        let header = ICMPHeader(type: 8, code: 0, checksum: 0, identifier: 0x1234, sequenceNumber: 0x5678)
        
        measure {
            for _ in 0..<10000 {
                let data = header.toData()
                _ = data.toICMPHeader()
            }
        }
    }
}