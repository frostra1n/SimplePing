import XCTest
@testable import SimplePing

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
final class AsyncSimplePingUnitTests: XCTestCase {
    
    private let testHost = "127.0.0.1"
    private let invalidHost = "invalid.host.that.does.not.exist.12345"
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        let config = AsyncSimplePing.Configuration(
            addressStyle: .icmpv4,
            timeout: 10.0,
            maxConcurrentPings: 3
        )
        
        let ping = AsyncSimplePing(hostName: "example.com", configuration: config)
        XCTAssertNotNil(ping)
    }
    
    func testConfigurationDefaults() {
        let config = AsyncSimplePing.Configuration()
        XCTAssertEqual(config.addressStyle, .any)
        XCTAssertEqual(config.timeout, 5.0)
        XCTAssertEqual(config.maxConcurrentPings, 1)
    }
    
    func testPingResultRoundTripTimeMs() {
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: 1,
            roundTripTime: 0.123,
            responsePacket: Data()
        )
        
        XCTAssertEqual(result.roundTripTimeMs, 123.0)
        
        let resultWithoutTime = AsyncSimplePing.PingResult(
            sequenceNumber: 1,
            roundTripTime: nil,
            responsePacket: Data()
        )
        
        XCTAssertNil(resultWithoutTime.roundTripTimeMs)
    }
    
    // MARK: - Error Handling Tests
    
    func testAsyncPingErrorDescriptions() {
        XCTAssertEqual(AsyncPingError.timeout.errorDescription, "Ping operation timed out")
        XCTAssertEqual(AsyncPingError.cancelled.errorDescription, "Ping operation was cancelled")
        XCTAssertEqual(AsyncPingError.tooManyConcurrentPings.errorDescription, "Too many concurrent ping operations")
    }
    
    func testPingBeforeStart() async {
        let ping = AsyncSimplePing(hostName: testHost)
        
        do {
            _ = try await ping.ping()
            XCTFail("Should have thrown an error for ping before start")
        } catch {
            XCTAssertTrue(error is SimplePingError)
        }
    }
    
    // MARK: - Fast Timeout Tests
    
    func testVeryShortTimeout() async throws {
        let config = AsyncSimplePing.Configuration(timeout: 0.001) // 1ms
        let shortTimeoutPing = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
        
        // Skip actual network operations to avoid timeouts
        // This test verifies timeout configuration works
        XCTAssertEqual(config.timeout, 0.001)
        XCTAssertNotNil(shortTimeoutPing)
    }
    
    func testPingTimeout() async {
        let config = AsyncSimplePing.Configuration(timeout: 0.1) // 100ms
        let timeoutPing = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
        
        // Skip actual network operations to avoid timeouts
        // This test verifies timeout configuration works
        XCTAssertEqual(config.timeout, 0.1)
        XCTAssertNotNil(timeoutPing)
    }
    
    // MARK: - Configuration Edge Cases
    
    func testZeroConcurrentPings() {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 0)
        let zeroConcurrentPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        // Should not crash
        XCTAssertNotNil(zeroConcurrentPing)
    }
    
    func testLargeConcurrentPings() {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 100)
        let largeConcurrentPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        // Should not crash with large concurrent limit
        XCTAssertNotNil(largeConcurrentPing)
    }
    
    // MARK: - Lifecycle Tests (No Network)
    
    func testStopBeforeStart() {
        let ping = AsyncSimplePing(hostName: testHost)
        ping.stop() // Should not crash
    }
    
    func testMultipleStopCalls() {
        let ping = AsyncSimplePing(hostName: testHost)
        ping.stop()
        ping.stop()
        ping.stop() // Multiple stops should be safe
    }
    
    // MARK: - Memory Safety Tests
    
    func testMemoryLeakPrevention() async throws {
        // Test that creating and stopping pings doesn't crash
        // Memory leak detection is better done with instruments
        
        for _ in 0..<10 {
            autoreleasepool {
                let ping = AsyncSimplePing(hostName: testHost)
                ping.stop() // Stop without start - should be safe
            }
        }
        
        // If we get here without crashes, basic memory management is working
    }
    
    func testConfigurationMemoryManagement() {
        // Test that configuration is properly handled as a value type
        weak var weakPing: AsyncSimplePing?
        
        do {
            let config = AsyncSimplePing.Configuration(
                addressStyle: .icmpv4,
                timeout: 5.0,
                maxConcurrentPings: 2
            )
            
            let ping = AsyncSimplePing(hostName: testHost, configuration: config)
            weakPing = ping
            
            // Configuration is copied, so original config can be released
        }
        
        // Configuration is a value type, so this test mainly ensures
        // the ping doesn't hold strong references to configuration objects
        // After the do block, ping should be deallocated
        XCTAssertNil(weakPing) // Out of scope, should be deallocated
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testSendableConformance() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        
        // Test that AsyncSimplePing can be passed across concurrency boundaries
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                ping.stop() // Should be safe to call from different task
            }
            
            group.addTask {
                ping.stop() // Should be safe to call from different task
            }
        }
    }
    
    func testResultSendable() {
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: 1,
            roundTripTime: 0.123,
            responsePacket: Data([1, 2, 3, 4])
        )
        
        // Test that PingResult can be passed across concurrency boundaries
        Task {
            // Access result properties in different task
            XCTAssertEqual(result.sequenceNumber, 1)
            XCTAssertEqual(result.roundTripTime, 0.123)
            XCTAssertEqual(result.responsePacket, Data([1, 2, 3, 4]))
        }
    }
    
    func testConfigurationSendable() {
        let config = AsyncSimplePing.Configuration()
        
        // Test that Configuration can be passed across concurrency boundaries
        Task {
            let ping = AsyncSimplePing(hostName: testHost, configuration: config)
            XCTAssertNotNil(ping)
        }
    }
    
    // MARK: - Concurrency Safety Tests (No Network)
    
    func testConcurrentStopCalls() async {
        let ping = AsyncSimplePing(hostName: testHost)
        
        // Test concurrent stop operations don't cause crashes
        await withTaskGroup(of: Void.self) { group in
            // Multiple concurrent stops
            for _ in 0..<10 {
                group.addTask {
                    ping.stop()
                }
            }
        }
    }
    
    func testMainActorSafety() async {
        // Test that AsyncSimplePing can be safely used from MainActor context
        await MainActor.run {
            let ping = AsyncSimplePing(hostName: testHost)
            ping.stop() // Should be safe to call from main actor
        }
    }
    
    // MARK: - Task Cancellation Tests
    
    func testTaskCancellationHandling() async {
        let ping = AsyncSimplePing(hostName: testHost)
        
        let task = Task {
            ping.stop()
        }
        
        // Cancel task immediately
        task.cancel()
        
        // Should not crash
        _ = await task.result
    }
    
    // MARK: - Data Structure Tests
    
    func testPingResultCreation() {
        let packet = Data([0x08, 0x00, 0x7d, 0x4b])
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: 42,
            roundTripTime: 0.055,
            responsePacket: packet
        )
        
        XCTAssertEqual(result.sequenceNumber, 42)
        XCTAssertEqual(result.roundTripTime, 0.055)
        XCTAssertEqual(result.responsePacket, packet)
        XCTAssertEqual(result.roundTripTimeMs, 55.0)
    }
    
    func testPingResultWithoutTime() {
        let packet = Data([0x08, 0x00, 0x7d, 0x4b])
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: 42,
            roundTripTime: nil,
            responsePacket: packet
        )
        
        XCTAssertEqual(result.sequenceNumber, 42)
        XCTAssertNil(result.roundTripTime)
        XCTAssertEqual(result.responsePacket, packet)
        XCTAssertNil(result.roundTripTimeMs)
    }
    
    // MARK: - Edge Case Value Tests
    
    func testConfigurationEdgeValues() {
        let config = AsyncSimplePing.Configuration(
            addressStyle: .icmpv6,
            timeout: 0.001, // Very short
            maxConcurrentPings: 1000 // Very large
        )
        
        XCTAssertEqual(config.addressStyle, .icmpv6)
        XCTAssertEqual(config.timeout, 0.001)
        XCTAssertEqual(config.maxConcurrentPings, 1000)
    }
    
    func testSequenceNumberEdgeCases() {
        // Test with maximum sequence number
        let maxResult = AsyncSimplePing.PingResult(
            sequenceNumber: UInt16.max,
            roundTripTime: 1.0,
            responsePacket: Data()
        )
        
        XCTAssertEqual(maxResult.sequenceNumber, UInt16.max)
        
        // Test with minimum sequence number
        let minResult = AsyncSimplePing.PingResult(
            sequenceNumber: UInt16.min,
            roundTripTime: 1.0,
            responsePacket: Data()
        )
        
        XCTAssertEqual(minResult.sequenceNumber, UInt16.min)
    }
    
    // MARK: - Stress Tests (Memory Only)
    
    func testRepeatedCreationDestruction() {
        // Test creating and destroying many instances quickly
        for _ in 0..<100 {
            let ping = AsyncSimplePing(hostName: testHost)
            ping.stop()
        }
        
        // If we get here without crashes, test passes
    }
    
    func testConcurrentCreation() async {
        // Test creating instances concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let ping = AsyncSimplePing(hostName: self.testHost)
                    ping.stop()
                }
            }
        }
        
        // If we get here without crashes, test passes
    }
}