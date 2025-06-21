import Foundation

/// A modern async/await wrapper around SimplePing
/// 
/// This class provides a Swift Concurrency-friendly interface to SimplePing,
/// converting the delegate pattern to async/await for cleaner, more readable code.
@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
public final class AsyncSimplePing: @unchecked Sendable {
    
    // MARK: - Public Types
    
    /// Result of a ping operation
    public struct PingResult {
        /// The sequence number of this ping
        public let sequenceNumber: UInt16
        /// Round-trip time in seconds (nil if timing unavailable)
        public let roundTripTime: TimeInterval?
        /// The complete response packet data
        public let responsePacket: Data
        
        /// Round-trip time in milliseconds for convenience
        public var roundTripTimeMs: Double? {
            roundTripTime.map { $0 * 1000 }
        }
    }
    
    /// Configuration for ping operations
    public struct Configuration {
        /// IP address style preference
        public var addressStyle: SimplePingAddressStyle = .any
        /// Timeout for individual ping operations (default: 5 seconds)
        public var timeout: TimeInterval = 5.0
        /// Maximum number of concurrent pings (default: 1)
        public var maxConcurrentPings: Int = 1
        
        public init(
            addressStyle: SimplePingAddressStyle = .any,
            timeout: TimeInterval = 5.0,
            maxConcurrentPings: Int = 1
        ) {
            self.addressStyle = addressStyle
            self.timeout = timeout
            self.maxConcurrentPings = maxConcurrentPings
        }
    }
    
    // MARK: - Private Properties
    
    private let simplePing: SimplePing
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "AsyncSimplePing", qos: .userInitiated)
    
    private var isStarted = false
    private var startupTask: Task<Void, Error>?
    private var pingDelegate: PingDelegate?
    
    // Track pending pings for async/await coordination (protected by queue)
    private var pendingPings: [UInt16: CheckedContinuation<PingResult, Error>] = [:]
    private var activePingCount = 0
    
    // MARK: - Initialization
    
    /// Creates a new AsyncSimplePing instance
    /// - Parameters:
    ///   - hostName: The hostname or IP address to ping
    ///   - configuration: Configuration options for ping behavior
    public init(hostName: String, configuration: Configuration = Configuration()) {
        self.simplePing = SimplePing(hostName: hostName)
        self.configuration = configuration
        
        // Configure the underlying SimplePing
        self.simplePing.addressStyle = configuration.addressStyle
    }
    
    // MARK: - Public Methods
    
    /// Starts the ping service and waits for it to be ready
    /// - Throws: SimplePingError if startup fails
    public func start() async throws {
        guard !isStarted else { return }
        
        // Cancel any existing startup task
        startupTask?.cancel()
        
        startupTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = StartupDelegate(continuation: continuation)
                simplePing.delegate = delegate
                simplePing.start()
            }
        }
        
        try await startupTask!.value
        isStarted = true
        
        // Switch to ping delegate after startup and keep a strong reference
        let delegate = PingDelegate(asyncPing: self)
        self.pingDelegate = delegate
        simplePing.delegate = delegate
    }
    
    /// Sends a single ping and waits for the response
    /// - Parameter data: Optional custom payload data
    /// - Returns: PingResult containing response information
    /// - Throws: SimplePingError or TimeoutError
    public func ping(with data: Data? = nil) async throws -> PingResult {
        guard isStarted else {
            throw SimplePingError.invalidHostName // Reusing existing error for "not started"
        }
        
        return try await withThrowingTaskGroup(of: PingResult.self) { group in
            // Start the ping operation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        // Respect concurrent ping limit
                        guard self.activePingCount < self.configuration.maxConcurrentPings else {
                            continuation.resume(throwing: AsyncPingError.tooManyConcurrentPings)
                            return
                        }
                        
                        self.activePingCount += 1
                        
                        let sequenceNumber = self.simplePing.nextSequenceNumber
                        self.pendingPings[sequenceNumber] = continuation
                        self.simplePing.sendPing(with: data)
                    }
                }
            }
            
            // Start the timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.configuration.timeout * 1_000_000_000))
                throw AsyncPingError.timeout
            }
            
            // Return the first result (either success or timeout)
            guard let result = try await group.next() else {
                throw AsyncPingError.cancelled
            }
            
            group.cancelAll()
            return result
        }
    }
    
    /// Sends multiple pings and returns results as they arrive
    /// - Parameters:
    ///   - count: Number of pings to send
    ///   - interval: Time interval between pings (default: 1 second)
    ///   - data: Optional custom payload data
    /// - Returns: AsyncThrowingStream of PingResult
    public func pingSequence(
        count: Int,
        interval: TimeInterval = 1.0,
        data: Data? = nil
    ) -> AsyncThrowingStream<PingResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for i in 0..<count {
                        if i > 0 {
                            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        }
                        
                        let result = try await ping(with: data)
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    /// Pings continuously until cancelled
    /// - Parameters:
    ///   - interval: Time interval between pings (default: 1 second)
    ///   - data: Optional custom payload data
    /// - Returns: AsyncThrowingStream of PingResult
    public func continuousPing(
        interval: TimeInterval = 1.0,
        data: Data? = nil
    ) -> AsyncThrowingStream<PingResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let result = try await ping(with: data)
                        continuation.yield(result)
                        
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    /// Stops the ping service
    public func stop() {
        queue.async {
            self.startupTask?.cancel()
            self.simplePing.stop()
            self.isStarted = false
            self.pingDelegate = nil
            
            // Cancel all pending pings
            for (_, continuation) in self.pendingPings {
                continuation.resume(throwing: AsyncPingError.cancelled)
            }
            self.pendingPings.removeAll()
            self.activePingCount = 0
        }
    }
    
    // MARK: - Internal Methods
    
    internal func handlePingResponse(_ result: PingResult) {
        queue.async {
            guard let continuation = self.pendingPings.removeValue(forKey: result.sequenceNumber) else {
                return // Unexpected response or already handled
            }
            self.activePingCount -= 1
            continuation.resume(returning: result)
        }
    }
    
    internal func handlePingError(_ error: Error, sequenceNumber: UInt16) {
        queue.async {
            guard let continuation = self.pendingPings.removeValue(forKey: sequenceNumber) else {
                return // Unexpected error or already handled
            }
            self.activePingCount -= 1
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Error Types

public enum AsyncPingError: Error, LocalizedError {
    case timeout
    case cancelled
    case tooManyConcurrentPings
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Ping operation timed out"
        case .cancelled:
            return "Ping operation was cancelled"
        case .tooManyConcurrentPings:
            return "Too many concurrent ping operations"
        }
    }
}

// MARK: - Delegate Implementations

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
private final class StartupDelegate: SimplePingDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Error>
    private var hasCompleted = false
    
    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
    
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        guard !hasCompleted else { return }
        hasCompleted = true
        continuation.resume()
    }
    
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        continuation.resume(throwing: error)
    }
}

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
private final class PingDelegate: SimplePingDelegate, @unchecked Sendable {
    private weak var asyncPing: AsyncSimplePing?
    
    init(asyncPing: AsyncSimplePing) {
        self.asyncPing = asyncPing
    }
    
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, 
                   sequenceNumber: UInt16, timeInterval: TimeInterval) {
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: sequenceNumber,
            roundTripTime: timeInterval,
            responsePacket: packet
        )
        
        asyncPing?.handlePingResponse(result)
    }
    
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, 
                   sequenceNumber: UInt16) {
        let result = AsyncSimplePing.PingResult(
            sequenceNumber: sequenceNumber,
            roundTripTime: nil,
            responsePacket: packet
        )
        
        asyncPing?.handlePingResponse(result)
    }
    
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, 
                   sequenceNumber: UInt16, error: Error) {
        asyncPing?.handlePingError(error, sequenceNumber: sequenceNumber)
    }
    
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        // Handle general errors - could affect multiple pending pings
        asyncPing?.handleGeneralError(error)
    }
}

// MARK: - AsyncSimplePing Extensions

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
extension AsyncSimplePing {
    internal func handleGeneralError(_ error: Error) {
        queue.async {
            // Cancel all pending pings with this error
            for (_, continuation) in self.pendingPings {
                continuation.resume(throwing: error)
            }
            self.pendingPings.removeAll()
            self.activePingCount = 0
        }
    }
}

// MARK: - Convenience Extensions

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
extension AsyncSimplePing {
    /// Quick ping function - starts, pings once, and stops
    /// - Parameters:
    ///   - hostName: The hostname or IP address to ping
    ///   - timeout: Timeout for the operation (default: 5 seconds)
    /// - Returns: PingResult
    /// - Throws: SimplePingError or AsyncPingError
    public static func quickPing(
        _ hostName: String,
        timeout: TimeInterval = 5.0
    ) async throws -> PingResult {
        let config = Configuration(timeout: timeout)
        let pinger = AsyncSimplePing(hostName: hostName, configuration: config)
        
        try await pinger.start()
        
        let result = try await pinger.ping()
        pinger.stop()
        
        return result
    }
    
    /// Test connectivity to a host with multiple pings
    /// - Parameters:
    ///   - hostName: The hostname or IP address to ping
    ///   - count: Number of pings to send (default: 4)
    ///   - timeout: Timeout per ping (default: 3 seconds)
    /// - Returns: Array of successful PingResults
    public static func testConnectivity(
        to hostName: String,
        count: Int = 4,
        timeout: TimeInterval = 3.0
    ) async throws -> [PingResult] {
        let config = Configuration(timeout: timeout)
        let pinger = AsyncSimplePing(hostName: hostName, configuration: config)
        
        try await pinger.start()
        
        var results: [PingResult] = []
        
        do {
            for try await result in pinger.pingSequence(count: count) {
                results.append(result)
            }
        } catch {
            pinger.stop()
            throw error
        }
        
        pinger.stop()
        return results
    }
}