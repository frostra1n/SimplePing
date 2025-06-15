import XCTest
import Network
@testable import SimplePing

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
final class SimplePingTests: XCTestCase {
    
    var simplePing: SimplePing!
    var delegate: MockSimplePingDelegate!
    
    override func setUp() {
        super.setUp()
        delegate = MockSimplePingDelegate()
        simplePing = SimplePing(hostName: "127.0.0.1")
        simplePing.delegate = delegate
    }
    
    override func tearDown() {
        simplePing?.stop()
        simplePing = nil
        delegate = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        let ping = SimplePing(hostName: "example.com")
        XCTAssertEqual(ping.hostName, "example.com")
        XCTAssertEqual(ping.addressStyle, .any)
        XCTAssertEqual(ping.nextSequenceNumber, 0)
        XCTAssertEqual(ping.hostAddressFamily, sa_family_t(AF_UNSPEC))
        XCTAssertNil(ping.hostAddress)
        XCTAssertGreaterThan(ping.identifier, 0)
    }
    
    func testUniqueIdentifiers() {
        let ping1 = SimplePing(hostName: "example.com")
        let ping2 = SimplePing(hostName: "example.com")
        XCTAssertNotEqual(ping1.identifier, ping2.identifier)
    }
    
    // MARK: - Address Style Tests
    
    func testAddressStyleConfiguration() {
        simplePing.addressStyle = .icmpv4
        XCTAssertEqual(simplePing.addressStyle, .icmpv4)
        
        simplePing.addressStyle = .icmpv6
        XCTAssertEqual(simplePing.addressStyle, .icmpv6)
        
        simplePing.addressStyle = .any
        XCTAssertEqual(simplePing.addressStyle, .any)
    }
    
    // MARK: - Start/Stop Tests
    
    func testStartWithLocalhost() {
        let expectation = XCTestExpectation(description: "Ping should start successfully")
        
        delegate.onDidStartWithAddress = { _, _ in
            expectation.fulfill()
        }
        
        delegate.onDidFailWithError = { _, error in
            XCTFail("Ping should not fail: \(error)")
        }
        
        simplePing.start()
        
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(simplePing.hostAddress)
    }
    
    func testStartWithInvalidHost() {
        let invalidPing = SimplePing(hostName: "invalid.host.that.does.not.exist.12345")
        invalidPing.delegate = delegate
        
        let expectation = XCTestExpectation(description: "Ping should fail with invalid host")
        
        delegate.onDidFailWithError = { _, _ in
            expectation.fulfill()
        }
        
        delegate.onDidStartWithAddress = { _, _ in
            XCTFail("Ping should not succeed with invalid host")
        }
        
        invalidPing.start()
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testMultipleStartCalls() {
        let expectation = XCTestExpectation(description: "Only one start should succeed")
        expectation.expectedFulfillmentCount = 1
        
        delegate.onDidStartWithAddress = { _, _ in
            expectation.fulfill()
        }
        
        // Call start multiple times
        simplePing.start()
        simplePing.start()
        simplePing.start()
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testStopBeforeStart() {
        // Should not crash
        simplePing.stop()
        XCTAssertNil(simplePing.hostAddress)
    }
    
    // MARK: - Ping Tests
    
    func testSendPingToLocalhost() {
        let startExpectation = XCTestExpectation(description: "Ping should start")
        let sendExpectation = XCTestExpectation(description: "Ping should be sent")
        
        delegate.onDidStartWithAddress = { _, _ in
            startExpectation.fulfill()
        }
        
        delegate.onDidSendPacket = { _, _, _ in
            sendExpectation.fulfill()
        }
        
        simplePing.start()
        
        wait(for: [startExpectation], timeout: 5.0)
        
        simplePing.sendPing()
        
        wait(for: [sendExpectation], timeout: 5.0)
    }
    
    func testSendPingWithCustomData() {
        let startExpectation = XCTestExpectation(description: "Ping should start")
        let sendExpectation = XCTestExpectation(description: "Ping should be sent with custom data")
        
        let customData = "Hello, World!".data(using: .utf8)!
        
        delegate.onDidStartWithAddress = { _, _ in
            startExpectation.fulfill()
        }
        
        delegate.onDidSendPacket = { _, packet, _ in
            // Check that the packet contains our custom data
            XCTAssertTrue(packet.count > customData.count)
            sendExpectation.fulfill()
        }
        
        simplePing.start()
        wait(for: [startExpectation], timeout: 5.0)
        
        simplePing.sendPing(with: customData)
        wait(for: [sendExpectation], timeout: 5.0)
    }
    
    func testSequenceNumberIncrement() {
        let startExpectation = XCTestExpectation(description: "Ping should start")
        let firstPingExpectation = XCTestExpectation(description: "First ping sent")
        let secondPingExpectation = XCTestExpectation(description: "Second ping sent")
        
        var firstSequenceNumber: UInt16?
        var secondSequenceNumber: UInt16?
        
        delegate.onDidStartWithAddress = { _, _ in
            startExpectation.fulfill()
        }
        
        delegate.onDidSendPacket = { _, _, sequenceNumber in
            if firstSequenceNumber == nil {
                firstSequenceNumber = sequenceNumber
                firstPingExpectation.fulfill()
            } else {
                secondSequenceNumber = sequenceNumber
                secondPingExpectation.fulfill()
            }
        }
        
        simplePing.start()
        wait(for: [startExpectation], timeout: 5.0)
        
        simplePing.sendPing()
        wait(for: [firstPingExpectation], timeout: 5.0)
        
        simplePing.sendPing()
        wait(for: [secondPingExpectation], timeout: 5.0)
        
        XCTAssertNotNil(firstSequenceNumber)
        XCTAssertNotNil(secondSequenceNumber)
        if let first = firstSequenceNumber, let second = secondSequenceNumber {
            XCTAssertEqual(second, first + 1)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testSendPingBeforeStart() {
        // Sending ping before start should not crash
        simplePing.sendPing()
        
        // Give it a moment to process
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Delegate Tests
    
    func testDelegateWeakReference() {
        var ping: SimplePing? = SimplePing(hostName: "127.0.0.1")
        var mockDelegate: MockSimplePingDelegate? = MockSimplePingDelegate()
        
        ping?.delegate = mockDelegate
        XCTAssertNotNil(ping?.delegate)
        
        mockDelegate = nil
        XCTAssertNil(ping?.delegate)
        
        ping = nil
    }
}

// MARK: - Mock Delegate

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
final class MockSimplePingDelegate: SimplePingDelegate, @unchecked Sendable {
    
    var onDidStartWithAddress: ((SimplePing, Data) -> Void)?
    var onDidFailWithError: ((SimplePing, Error) -> Void)?
    var onDidSendPacket: ((SimplePing, Data, UInt16) -> Void)?
    var onDidFailToSendPacket: ((SimplePing, Data, UInt16, Error) -> Void)?
    var onDidReceivePingResponsePacket: ((SimplePing, Data, UInt16) -> Void)?
    var onDidReceiveUnexpectedPacket: ((SimplePing, Data) -> Void)?
    
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        onDidStartWithAddress?(pinger, address)
    }
    
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        onDidFailWithError?(pinger, error)
    }
    
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {
        onDidSendPacket?(pinger, packet, sequenceNumber)
    }
    
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error) {
        onDidFailToSendPacket?(pinger, packet, sequenceNumber, error)
    }
    
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {
        onDidReceivePingResponsePacket?(pinger, packet, sequenceNumber)
    }
    
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        onDidReceiveUnexpectedPacket?(pinger, packet)
    }
}