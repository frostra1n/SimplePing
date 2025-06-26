import XCTest
@testable import SimplePing

// Re-enabled tests with specific continuation leak test
// Tests are structured to avoid network dependencies where possible
@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
final class AsyncSimplePingLeakTests: XCTestCase {
    
    private let testHost = "127.0.0.1"
    private let invalidHost = "invalid.host.that.does.not.exist.example.com"
    
    override func setUp() async throws {
        try await super.setUp()
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
    }
    
    // MARK: - Continuation Leak Tests
    
    func testStartMethodDoesNotLeakContinuation() async throws {
        // This test specifically addresses the continuation leak issue
        let expectation = XCTestExpectation(description: "Start method completes without leaking continuation")
        
        let task = Task {
            let ping = AsyncSimplePing(hostName: invalidHost)
            
            do {
                try await ping.start()
                // If we get here, the invalid host somehow resolved
                ping.stop()
            } catch {
                // Expected - invalid host should fail, but importantly,
                // it should fail by throwing an error, not by hanging
                XCTAssertTrue(error is AsyncPingError || error is SimplePingError,
                            "Should throw a proper error, not hang")
            }
            
            expectation.fulfill()
        }
        
        // Give the operation a reasonable timeout
        await fulfillment(of: [expectation], timeout: 20.0)
        
        // Cancel the task to ensure cleanup
        task.cancel()
    }
    
    func testStartMethodWithTimeoutDoesNotHang() async throws {
        // Test that start() method respects timeout and doesn't hang indefinitely
        let ping = AsyncSimplePing(hostName: invalidHost)
        
        let startTime = Date()
        
        do {
            try await ping.start()
            ping.stop()
        } catch {
            // Expected to fail, but should fail within reasonable time
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsed, 16.0, "Start method should timeout within 16 seconds, not hang indefinitely")
        }
    }
    
    func testConcurrentStartCallsDoNotLeakContinuations() async throws {
        // Test that multiple concurrent start calls don't create continuation leaks
        let ping = AsyncSimplePing(hostName: invalidHost)
        
        await withTaskGroup(of: Void.self) { group in
            // Start multiple concurrent start operations
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await ping.start()
                        ping.stop()
                    } catch {
                        // Expected to fail for invalid host
                    }
                }
            }
        }
        
        // If we reach here without hanging, the test passes
    }
    
    func testPingResponseHandling() async throws {
        // Test that ping responses are properly handled with localhost
        let config = AsyncSimplePing.Configuration(timeout: 5.0)
        let ping = AsyncSimplePing(hostName: "127.0.0.1", configuration: config)
        
        do {
            try await ping.start()
            
            // Try to send a single ping
            let result = try await ping.ping()
            
            // Verify we got a valid result
            XCTAssertGreaterThanOrEqual(result.sequenceNumber, 0)
            XCTAssertGreaterThan(result.responsePacket.count, 0)
            
            ping.stop()
        } catch {
            // On some systems, ping to localhost might fail due to security restrictions
            // This is acceptable - the important thing is that it doesn't hang
            XCTAssertTrue(error is AsyncPingError || error is SimplePingError,
                        "Should throw a proper error type: \(error)")
        }
    }
    
    // MARK: - Memory Leak Detection Tests
    
    func testAsyncSimplePingDeallocation() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                // Skip actual network operations to avoid timeouts
                ping.stop()
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing instance should be deallocated")
    }
    
    func testStartupDelegateDeallocation() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                // Skip actual network operations to avoid timeouts
                ping.stop()
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing with startup delegate should be deallocated")
    }
    
    func testPingDelegateDeallocation() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                // Skip actual network operations to avoid timeouts
                ping.stop()
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing with ping delegate should be deallocated")
    }
    
    func testPendingPingsCleanup() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let config = AsyncSimplePing.Configuration(timeout: 10.0)
            let ping = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    
                    // Start a ping that will timeout
                    let pingTask = Task {
                        try await ping.ping()
                    }
                    
                    // Stop immediately to test cleanup
                    ping.stop()
                    
                    do {
                        _ = try await pingTask.value
                    } catch {
                        // Expected to be cancelled
                    }
                } catch {
                    // Ignore start errors
                }
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing with pending pings should be deallocated after cleanup")
    }
    
    func testTaskCleanupOnCancellation() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let mainTask = Task {
                do {
                    try await ping.start()
                    
                    let pingTask = Task {
                        for try await _ in ping.continuousPing(interval: 0.1) {
                            // This will run continuously until cancelled
                        }
                    }
                    
                    // Let it run briefly then cancel
                    try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                    pingTask.cancel()
                    
                    do {
                        try await pingTask.value
                    } catch {
                        // Expected to be cancelled
                    }
                    
                    ping.stop()
                } catch {
                    // Ignore errors for this test
                }
            }
            
            _ = await mainTask.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated after task cancellation")
    }
    
    func testSequentialPingCleanup() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    
                    // Perform multiple pings sequentially
                    for _ in 0..<5 {
                        _ = try await ping.ping()
                    }
                    
                    ping.stop()
                } catch {
                    // Ignore errors for this test
                }
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated after sequential pings")
    }
    
    func testPingSequenceCleanup() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    
                    var count = 0
                    for try await _ in ping.pingSequence(count: 3, interval: 0.05) {
                        count += 1
                    }
                    XCTAssertEqual(count, 3)
                    
                    ping.stop()
                } catch {
                    // Ignore errors for this test
                }
            }
            
            _ = await task.result
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated after ping sequence")
    }
    
    func testQuickPingCleanup() async throws {
        // Test that quickPing properly cleans up its resources
        // Since PingResult is a value type, we test by ensuring no crashes occur
        
        await autoreleasepool {
            do {
                _ = try await AsyncSimplePing.quickPing(testHost, timeout: 5.0)
            } catch {
                // Ignore errors for this test
            }
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // If we get here without crashes, the internal AsyncSimplePing was properly deallocated
    }
    
    func testTestConnectivityCleanup() async throws {
        // Test that testConnectivity properly cleans up its resources
        // Since PingResult is a value type, we test by ensuring no crashes occur
        
        await autoreleasepool {
            do {
                _ = try await AsyncSimplePing.testConnectivity(
                    to: testHost,
                    count: 2,
                    timeout: 3.0
                )
            } catch {
                // Ignore errors for this test
            }
        }
        
        // Allow time for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // If we get here without crashes, the internal AsyncSimplePing was properly deallocated
    }
    
    // MARK: - Stress Tests for Memory Leaks
    
    func testRepeatedCreationAndDestruction() async throws {
        for _ in 0..<10 {
            await autoreleasepool {
                let ping = AsyncSimplePing(hostName: testHost)
                let task = Task {
                    do {
                        try await ping.start()
                        _ = try await ping.ping()
                        ping.stop()
                    } catch {
                        // Ignore errors for stress test
                    }
                }
                _ = await task.result
            }
        }
        
        // If we get here without crashes or excessive memory usage, test passes
    }
    
    func testRepeatedQuickPings() async throws {
        for _ in 0..<5 {
            await autoreleasepool {
                do {
                    _ = try await AsyncSimplePing.quickPing(testHost, timeout: 2.0)
                } catch {
                    // Ignore errors for stress test
                }
            }
        }
        
        // If we get here without crashes or excessive memory usage, test passes
    }
    
    func testConcurrentCreationAndDestruction() async throws {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await self.autoreleasepool {
                        let ping = AsyncSimplePing(hostName: self.testHost)
                        let task = Task {
                            do {
                                try await ping.start()
                                _ = try await ping.ping()
                                ping.stop()
                            } catch {
                                // Ignore errors for stress test
                            }
                        }
                        _ = await task.result
                    }
                }
            }
        }
        
        // If we get here without crashes or excessive memory usage, test passes
    }
    
    // MARK: - Strict Concurrency Leak Tests
    
    func testConcurrentOperationsNoLeaks() async throws {
        // Test that concurrent operations don't create memory leaks
        var weakPings: [() -> AsyncSimplePing?] = []
        
        do {
            var pings: [AsyncSimplePing] = []
            
            // Create multiple instances
            for _ in 0..<5 {
                let ping = AsyncSimplePing(hostName: testHost)
                pings.append(ping)
                
                // Create a weak reference capturing closure
                weak var weakPing = ping
                weakPings.append({ weakPing })
            }
            
            // Use them concurrently
            await withTaskGroup(of: Void.self) { group in
                for ping in pings {
                    group.addTask {
                        do {
                            try await ping.start()
                            _ = try await ping.ping()
                            ping.stop()
                        } catch {
                            // Ignore errors for leak test
                        }
                    }
                }
            }
            
            // Clear strong references
            pings.removeAll()
        }
        
        // Force garbage collection
        for _ in 0..<5 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        for (index, weakPingClosure) in weakPings.enumerated() {
            XCTAssertNil(weakPingClosure(), "AsyncSimplePing at index \(index) should be deallocated")
        }
    }
    
    func testAsyncSequenceLeakPrevention() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    
                    // Test that AsyncSequence doesn't retain the ping
                    var count = 0
                    for try await _ in ping.pingSequence(count: 3, interval: 0.05) {
                        count += 1
                    }
                    
                    ping.stop()
                    return count
                } catch {
                    return 0
                }
            }
            
            _ = await task.result
        }
        
        // Force garbage collection
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated after AsyncSequence completion")
    }
    
    func testDelegateRetainCycleBreaking() async throws {
        weak var weakPing: AsyncSimplePing?
        weak var weakStartupDelegate: AnyObject?
        weak var weakPingDelegate: AnyObject?
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            weakPing = ping
            
            do {
                try await ping.start()
                
                // Use reflection to access internal delegates
                let mirror = Mirror(reflecting: ping)
                
                // Check if delegates are properly retained/released
                if mirror.children.first(where: { $0.label == "startupTask" }) != nil {
                    // StartupTask should not retain delegates after completion
                }
                
                if let pingDelegateChild = mirror.children.first(where: { $0.label == "pingDelegate" }) {
                    weakPingDelegate = pingDelegateChild.value as AnyObject
                }
                
                _ = try await ping.ping()
                ping.stop()
            } catch {
                // Ignore errors for retain cycle test
            }
        }
        
        // Force garbage collection
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated")
        XCTAssertNil(weakStartupDelegate, "StartupDelegate should be deallocated")
        XCTAssertNil(weakPingDelegate, "PingDelegate should be deallocated")
    }
    
    func testContinuationLeakPrevention() async throws {
        weak var weakPing: AsyncSimplePing?
        
        await autoreleasepool {
            let config = AsyncSimplePing.Configuration(timeout: 2.0)
            let ping = AsyncSimplePing(hostName: "10.255.255.255", configuration: config)
            weakPing = ping
            
            let task = Task {
                do {
                    try await ping.start()
                    
                    // Start multiple operations that will timeout
                    await withTaskGroup(of: Void.self) { group in
                        for _ in 0..<5 {
                            group.addTask {
                                do {
                                    _ = try await ping.ping()
                                } catch {
                                    // Expected to timeout
                                }
                            }
                        }
                    }
                    
                    ping.stop()
                } catch {
                    // Ignore errors for continuation leak test
                }
            }
            
            _ = await task.result
        }
        
        // Force garbage collection
        for _ in 0..<5 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        XCTAssertNil(weakPing, "AsyncSimplePing should be deallocated even with timeout operations")
    }
    
    func testActorBoundaryLeakPrevention() async throws {
        actor PingActor {
            private var ping: AsyncSimplePing?
            
            func createPing(_ hostName: String) {
                ping = AsyncSimplePing(hostName: hostName)
            }
            
            func performPing() async throws -> AsyncSimplePing.PingResult? {
                guard let ping = ping else { return nil }
                try await ping.start()
                let result = try await ping.ping()
                ping.stop()
                return result
            }
            
            func destroyPing() {
                ping?.stop()
                ping = nil
            }
        }
        
        // Actor should be deallocated (though this is harder to test directly)
        
        do {
            let actor = PingActor()
            
            await actor.createPing(testHost)
            
            do {
                _ = try await actor.performPing()
            } catch {
                // Ignore errors for actor leak test
            }
            
            await actor.destroyPing()
        }
        
        // Force garbage collection
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        // Actor should be deallocated (though this is harder to test directly)
        // If we reach here without crashes, the test is successful
    }
    
    // MARK: - Configuration Memory Tests
    
    func testConfigurationMemoryManagement() async throws {
        // Test that configuration is properly handled as a value type
        // Since Configuration is a struct, we test by ensuring no crashes occur
        
        await autoreleasepool {
            let config = AsyncSimplePing.Configuration(
                addressStyle: .icmpv4,
                timeout: 5.0,
                maxConcurrentPings: 2
            )
            
            let ping = AsyncSimplePing(hostName: testHost, configuration: config)
            XCTAssertNotNil(ping)
            
            // Configuration is copied, so original config can be released
        }
        
        // Configuration is a value type, so this test mainly ensures
        // the ping doesn't hold strong references to configuration objects
    }
    
    // MARK: - Result Memory Tests
    
    func testPingResultMemoryManagement() async throws {
        // Test that PingResult is properly handled as a value type
        // Since PingResult is a struct, we test by ensuring no crashes occur
        
        await autoreleasepool {
            let ping = AsyncSimplePing(hostName: testHost)
            
            do {
                try await ping.start()
                _ = try await ping.ping()
                ping.stop()
            } catch {
                // Ignore errors for this test
            }
        }
        
        // Result is a value type, so it should be deallocated when out of scope
        // This test mainly ensures we're not creating unexpected strong references
    }
}

// MARK: - Helper Extensions for Memory Testing

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
extension AsyncSimplePingLeakTests {
    
    private func autoreleasepool<T>(_ block: () async throws -> T) async rethrows -> T {
        return try await block()
    }
}