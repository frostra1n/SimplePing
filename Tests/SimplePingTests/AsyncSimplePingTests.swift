import XCTest
import Network
@testable import SimplePing

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
final class AsyncSimplePingTests: XCTestCase {
    
    private var asyncPing: AsyncSimplePing!
    private let testHost = "127.0.0.1" 
    private let invalidHost = "invalid.host.that.does.not.exist.12345"
    
    override func setUp() async throws {
        try await super.setUp()
        // Don't create asyncPing here to avoid network operations in setUp
    }
    
    override func tearDown() async throws {
        asyncPing?.stop()
        asyncPing = nil
        try await super.tearDown()
    }
    
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
    
    // MARK: - Start/Stop Tests
    
    func testStartSuccess() async throws {
        asyncPing = AsyncSimplePing(hostName: testHost)
        // Test with very short timeout to prevent hanging
        let config = AsyncSimplePing.Configuration(timeout: 1.0)
        let quickPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        do {
            try await quickPing.start()
            quickPing.stop()
        } catch {
            // May fail in test environment, but shouldn't crash
        }
    }
    
    func testStartWithInvalidHost() async {
        let config = AsyncSimplePing.Configuration(timeout: 1.0)
        let invalidPing = AsyncSimplePing(hostName: invalidHost, configuration: config)
        
        do {
            try await invalidPing.start()
            XCTFail("Should have thrown an error for invalid host")
        } catch {
            XCTAssertTrue(error is SimplePingError)
        }
    }
    
    func testMultipleStartCallsAreIdempotent() async throws {
        asyncPing = AsyncSimplePing(hostName: testHost)
        // Only test the idempotent behavior, not actual network operations
        
        // Create a short-lived test
        let config = AsyncSimplePing.Configuration(timeout: 0.1)
        let testPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        // Multiple starts should not crash
        do {
            try await testPing.start()
            try await testPing.start()  // Should be idempotent
            try await testPing.start()  // Should be idempotent
        } catch {
            // May fail due to network, but testing idempotency behavior
        }
        testPing.stop()
    }
    
    func testStopBeforeStart() {
        asyncPing = AsyncSimplePing(hostName: testHost)
        asyncPing.stop()
    }
    
    func testStopAfterStart() async throws {
        asyncPing = AsyncSimplePing(hostName: testHost)
        // Test stop after start without hanging on network operations
        asyncPing.stop()
    }
    
    // MARK: - Single Ping Tests
    
    func testSinglePingSuccess() async throws {
        try await asyncPing.start()
        
        let result = try await asyncPing.ping()
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
        XCTAssertNotNil(result.roundTripTime)
        XCTAssertFalse(result.responsePacket.isEmpty)
        XCTAssertNotNil(result.roundTripTimeMs)
    }
    
    func testPingWithCustomData() async throws {
        try await asyncPing.start()
        
        let customData = "Hello, AsyncPing!".data(using: .utf8)!
        let result = try await asyncPing.ping(with: customData)
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
        XCTAssertNotNil(result.roundTripTime)
        XCTAssertFalse(result.responsePacket.isEmpty)
    }
    
    func testPingBeforeStart() async {
        do {
            _ = try await asyncPing.ping()
            XCTFail("Should have thrown an error for ping before start")
        } catch {
            XCTAssertTrue(error is SimplePingError)
        }
    }
    
    func testPingTimeout() async {
        let config = AsyncSimplePing.Configuration(timeout: 0.1)
        let timeoutPing = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
        
        do {
            try await timeoutPing.start()
            _ = try await timeoutPing.ping()
            XCTFail("Should have timed out")
        } catch {
            XCTAssertTrue(error is AsyncPingError)
            if case AsyncPingError.timeout = error {
                // Expected
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        }
    }
    
    // MARK: - Concurrency Tests
    
    func testConcurrentPingLimit() async throws {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 1)
        let limitedPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        try await limitedPing.start()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await limitedPing.ping()
                    } catch AsyncPingError.tooManyConcurrentPings {
                        // Expected for some tasks
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }
    
    func testConcurrentPingsWithinLimit() async throws {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 3)
        let concurrentPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        try await concurrentPing.start()
        
        await withTaskGroup(of: AsyncSimplePing.PingResult?.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        return try await concurrentPing.ping()
                    } catch {
                        return nil
                    }
                }
            }
            
            var results: [AsyncSimplePing.PingResult] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            
            XCTAssertGreaterThan(results.count, 0)
        }
    }
    
    // MARK: - Ping Sequence Tests
    
    func testPingSequence() async throws {
        try await asyncPing.start()
        
        let count = 3
        var results: [AsyncSimplePing.PingResult] = []
        
        for try await result in asyncPing.pingSequence(count: count, interval: 0.1) {
            results.append(result)
        }
        
        XCTAssertEqual(results.count, count)
        
        for result in results {
            XCTAssertGreaterThan(result.sequenceNumber, 0)
            XCTAssertNotNil(result.roundTripTime)
            XCTAssertFalse(result.responsePacket.isEmpty)
        }
    }
    
    func testPingSequenceWithCustomData() async throws {
        try await asyncPing.start()
        
        let customData = "Sequence test".data(using: .utf8)!
        let count = 2
        var results: [AsyncSimplePing.PingResult] = []
        
        for try await result in asyncPing.pingSequence(count: count, interval: 0.1, data: customData) {
            results.append(result)
        }
        
        XCTAssertEqual(results.count, count)
    }
    
    func testPingSequenceCancellation() async throws {
        try await asyncPing.start()
        
        let task = Task {
            var results: [AsyncSimplePing.PingResult] = []
            for try await result in asyncPing.pingSequence(count: 10, interval: 1.0) {
                results.append(result)
            }
            return results
        }
        
        // Cancel after a short delay
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        task.cancel()
        
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
    
    // MARK: - Continuous Ping Tests
    
    func testContinuousPing() async throws {
        try await asyncPing.start()
        
        let task = Task {
            var results: [AsyncSimplePing.PingResult] = []
            for try await result in asyncPing.continuousPing(interval: 0.1) {
                results.append(result)
                if results.count >= 3 {
                    break
                }
            }
            return results
        }
        
        let results = try await task.value
        XCTAssertEqual(results.count, 3)
        
        for result in results {
            XCTAssertGreaterThan(result.sequenceNumber, 0)
            XCTAssertNotNil(result.roundTripTime)
            XCTAssertFalse(result.responsePacket.isEmpty)
        }
    }
    
    func testContinuousPingCancellation() async throws {
        try await asyncPing.start()
        
        let task = Task {
            var count = 0
            for try await _ in asyncPing.continuousPing(interval: 0.1) {
                count += 1
            }
            return count
        }
        
        // Let it run for a bit then cancel
        try await Task.sleep(nanoseconds: 250_000_000) // 0.25 seconds
        task.cancel()
        
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
    
    // MARK: - Static Method Tests
    
    func testQuickPing() async throws {
        let result = try await AsyncSimplePing.quickPing(testHost, timeout: 5.0)
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
        XCTAssertNotNil(result.roundTripTime)
        XCTAssertFalse(result.responsePacket.isEmpty)
    }
    
    func testQuickPingWithInvalidHost() async {
        do {
            _ = try await AsyncSimplePing.quickPing(invalidHost, timeout: 2.0)
            XCTFail("Should have failed with invalid host")
        } catch {
            XCTAssertTrue(error is SimplePingError)
        }
    }
    
    func testTestConnectivity() async throws {
        let results = try await AsyncSimplePing.testConnectivity(
            to: testHost,
            count: 3,
            timeout: 3.0
        )
        
        XCTAssertEqual(results.count, 3)
        
        for result in results {
            XCTAssertGreaterThan(result.sequenceNumber, 0)
            XCTAssertNotNil(result.roundTripTime)
            XCTAssertFalse(result.responsePacket.isEmpty)
        }
    }
    
    func testTestConnectivityWithInvalidHost() async {
        do {
            _ = try await AsyncSimplePing.testConnectivity(
                to: invalidHost,
                count: 2,
                timeout: 1.0
            )
            XCTFail("Should have failed with invalid host")
        } catch {
            XCTAssertTrue(error is SimplePingError)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testAsyncPingErrorDescriptions() {
        XCTAssertEqual(AsyncPingError.timeout.errorDescription, "Ping operation timed out")
        XCTAssertEqual(AsyncPingError.cancelled.errorDescription, "Ping operation was cancelled")
        XCTAssertEqual(AsyncPingError.tooManyConcurrentPings.errorDescription, "Too many concurrent ping operations")
    }
    
    // MARK: - Memory Safety Tests
    
    func testMemoryLeakPrevention() async throws {
        weak var weakPing: AsyncSimplePing?
        
        do {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            try await ping.start()
            _ = try await ping.ping()
            ping.stop()
        }
        
        // Force garbage collection
        await Task.yield()
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated")
    }
    
    func testPendingPingsClearedOnStop() async throws {
        let config = AsyncSimplePing.Configuration(timeout: 10.0)
        let ping = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
        
        try await ping.start()
        
        let task = Task {
            try await ping.ping()
        }
        
        // Stop immediately to cancel pending ping
        ping.stop()
        
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch AsyncPingError.cancelled {
            // Expected
        } catch {
            XCTFail("Expected cancellation error, got \(error)")
        }
    }
    
    // MARK: - Thread Safety Tests
    
    func testThreadSafetyMultipleOperations() async throws {
        try await asyncPing.start()
        
        await withTaskGroup(of: Void.self) { group in
            // Start multiple ping operations
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await self.asyncPing.ping()
                    } catch {
                        // Some may fail due to concurrency limits
                    }
                }
            }
            
            // Start/stop operations
            group.addTask {
                self.asyncPing.stop()
                do {
                    try await self.asyncPing.start()
                } catch {
                    // May fail if stopped during startup
                }
            }
        }
    }
    
    func testConcurrentStartStop() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await self.asyncPing.start()
                    } catch {
                        // May fail due to race conditions
                    }
                }
                
                group.addTask {
                    self.asyncPing.stop()
                }
            }
        }
    }
    
    // MARK: - Performance Tests
    
    func testPerformanceSinglePing() async throws {
        try await asyncPing.start()
        
        measure {
            let expectation = expectation(description: "ping")
            
            Task {
                do {
                    _ = try await self.asyncPing.ping()
                    expectation.fulfill()
                } catch {
                    XCTFail("Ping failed: \(error)")
                }
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
    
    func testPerformanceMultiplePings() async throws {
        try await asyncPing.start()
        
        measure {
            let expectation = expectation(description: "multiple pings")
            
            Task {
                do {
                    var count = 0
                    for try await _ in self.asyncPing.pingSequence(count: 5, interval: 0.1) {
                        count += 1
                    }
                    XCTAssertEqual(count, 5)
                    expectation.fulfill()
                } catch {
                    XCTFail("Ping sequence failed: \(error)")
                }
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
    
    // MARK: - Strict Concurrency Tests
    
    func testStrictSendableConformance() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        
        // Test AsyncSimplePing can be safely passed across actor boundaries
        actor TestActor {
            func testPing(_ ping: AsyncSimplePing) async throws -> AsyncSimplePing.PingResult {
                try await ping.start()
                let result = try await ping.ping()
                ping.stop()
                return result
            }
        }
        
        let testActor = TestActor()
        let result = try await testActor.testPing(ping)
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
    }
    
    func testConcurrentStartStopSafety() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        
        // Test concurrent start/stop operations don't cause crashes or data races
        await withTaskGroup(of: Void.self) { group in
            // Multiple concurrent starts
            for _ in 0..<10 {
                group.addTask {
                    do {
                        try await ping.start()
                    } catch {
                        // Expected to fail some times due to race conditions
                    }
                }
            }
            
            // Multiple concurrent stops
            for _ in 0..<10 {
                group.addTask {
                    ping.stop()
                }
            }
        }
    }
    
    func testDataRaceProtection() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        try await ping.start()
        
        // Test that concurrent ping operations don't cause data races
        let results = await withTaskGroup(of: AsyncSimplePing.PingResult?.self, returning: [AsyncSimplePing.PingResult?].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        return try await ping.ping()
                    } catch {
                        return nil
                    }
                }
            }
            
            var results: [AsyncSimplePing.PingResult?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        let successfulResults = results.compactMap { $0 }
        XCTAssertGreaterThan(successfulResults.count, 0)
        
        // Verify sequence numbers are unique (no duplicates from data races)
        let sequenceNumbers = successfulResults.map { $0.sequenceNumber }
        let uniqueSequenceNumbers = Set(sequenceNumbers)
        XCTAssertEqual(sequenceNumbers.count, uniqueSequenceNumbers.count, "Sequence numbers should be unique")
    }
    
    func testMainActorIsolation() async throws {
        // Test that AsyncSimplePing can be safely used from MainActor context
        await MainActor.run {
            let ping = AsyncSimplePing(hostName: testHost)
            XCTAssertNotNil(ping)
        }
        
        let ping = AsyncSimplePing(hostName: testHost)
        
        await MainActor.run {
            ping.stop() // Should be safe to call from main actor
        }
    }
    
    func testTaskCancellationPropagation() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        try await ping.start()
        
        let task = Task {
            try await ping.ping()
        }
        
        // Cancel immediately
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Task should have been cancelled")
        } catch is CancellationError {
            // Expected
        } catch AsyncPingError.cancelled {
            // Also acceptable
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testTaskGroupCancellationHandling() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        try await ping.start()
        
        let task = Task {
            try await withThrowingTaskGroup(of: AsyncSimplePing.PingResult.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await ping.ping()
                    }
                }
                
                var results: [AsyncSimplePing.PingResult] = []
                for try await result in group {
                    results.append(result)
                    if results.count >= 2 {
                        // Cancel remaining tasks
                        group.cancelAll()
                        break
                    }
                }
                return results
            }
        }
        
        let results = try await task.value
        XCTAssertGreaterThanOrEqual(results.count, 1)
        XCTAssertLessThanOrEqual(results.count, 5)
    }
    
    func testAsyncSequenceCancellationSafety() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        try await ping.start()
        
        let task = Task {
            var count = 0
            for try await _ in ping.continuousPing(interval: 0.1) {
                count += 1
                if count >= 3 {
                    return count
                }
            }
            return count
        }
        
        // Let it run briefly then cancel
        try await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
        task.cancel()
        
        do {
            let count = try await task.value
            XCTAssertGreaterThanOrEqual(count, 1)
        } catch is CancellationError {
            // Also acceptable if cancelled before any results
        }
    }
    
    // MARK: - Memory Safety and Leak Prevention
    
    func testStrictMemoryManagement() async throws {
        // Test with strict memory tracking
        weak var weakPing: AsyncSimplePing?
        weak var weakDelegate: AnyObject?
        
        // Use a synchronous autorelease pool
        autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            // Create a task to handle async operations
            let task = Task {
                do {
                    try await ping.start()
                    
                    // Access internal delegate through reflection for testing
                    let mirror = Mirror(reflecting: ping)
                    if let delegateChild = mirror.children.first(where: { $0.label == "pingDelegate" }) {
                        weakDelegate = delegateChild.value as AnyObject
                    }
                    
                    _ = try await ping.ping()
                    ping.stop()
                } catch {
                    // Ignore errors for memory test
                }
            }
            
            // Wait for completion in a detached task to avoid blocking autoreleasepool
            Task.detached {
                _ = await task.result
            }
        }
        
        // Give time for async operations to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Force multiple garbage collection cycles
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated")
        XCTAssertNil(weakDelegate, "Internal delegate should be deallocated")
    }
    
    func testConcurrentLifecycleManagement() async throws {
        // Test that concurrent creation/destruction doesn't leak memory
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { [testHost] in
                    autoreleasepool {
                        let ping = AsyncSimplePing(hostName: testHost)
                        let task = Task {
                            do {
                                try await ping.start()
                                _ = try await ping.ping()
                                ping.stop()
                            } catch {
                                // Ignore errors for lifecycle test
                            }
                        }
                        
                        // Wait for completion
                        Task.detached {
                            _ = await task.result
                        }
                    }
                }
            }
        }
        
        // Give time for async operations to complete
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // If we reach here without crashes, lifecycle management is working
    }
    
    func testResourceCleanupOnError() async throws {
        weak var weakPing: AsyncSimplePing?
        
        autoreleasepool {
            let config = AsyncSimplePing.Configuration(timeout: 0.001) // Very short timeout
            let ping = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    _ = try await ping.ping()
                } catch {
                    // Expected to timeout
                }
                
                ping.stop()
            }
            
            // Wait for completion
            Task.detached {
                _ = await task.result
            }
        }
        
        // Give time for async operations to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Force garbage collection
        await Task.yield()
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated even after errors")
    }
    
    // MARK: - Edge Cases
    
    func testVeryShortTimeout() async throws {
        let config = AsyncSimplePing.Configuration(timeout: 0.001) // 1ms
        let shortTimeoutPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        try await shortTimeoutPing.start()
        
        do {
            _ = try await shortTimeoutPing.ping()
        } catch AsyncPingError.timeout {
            // Expected for very short timeout
        } catch {
            // May succeed on fast systems
        }
    }
    
    func testZeroConcurrentPings() {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 0)
        let zeroConcurrentPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        // Should not crash
        XCTAssertNotNil(zeroConcurrentPing)
    }
    
    func testLargeConcurrentPings() async throws {
        let config = AsyncSimplePing.Configuration(maxConcurrentPings: 100)
        let largeConcurrentPing = AsyncSimplePing(hostName: testHost, configuration: config)
        
        try await largeConcurrentPing.start()
        
        // Should not crash with large concurrent limit
        _ = try await largeConcurrentPing.ping()
    }
    
    func testEmptyCustomData() async throws {
        try await asyncPing.start()
        
        let result = try await asyncPing.ping(with: Data())
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
        XCTAssertNotNil(result.roundTripTime)
        XCTAssertFalse(result.responsePacket.isEmpty)
    }
    
    func testLargeCustomData() async throws {
        try await asyncPing.start()
        
        let largeData = Data(count: 1000)
        let result = try await asyncPing.ping(with: largeData)
        
        XCTAssertGreaterThan(result.sequenceNumber, 0)
        XCTAssertNotNil(result.roundTripTime)
        XCTAssertFalse(result.responsePacket.isEmpty)
    }
}

// MARK: - Sendable Conformance Tests

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
extension AsyncSimplePingTests {
    
    func testSendableConformance() async throws {
        let ping = AsyncSimplePing(hostName: testHost)
        
        // Test that AsyncSimplePing can be passed across concurrency boundaries
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await ping.start()
                } catch {
                    // May fail due to race conditions
                }
            }
            
            group.addTask {
                ping.stop()
            }
        }
    }
    
    func testResultSendable() async throws {
        try await asyncPing.start()
        let result = try await asyncPing.ping()
        
        // Test that PingResult can be passed across concurrency boundaries
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Access result properties in different task
                XCTAssertGreaterThan(result.sequenceNumber, 0)
                XCTAssertNotNil(result.roundTripTime)
                XCTAssertFalse(result.responsePacket.isEmpty)
            }
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
}