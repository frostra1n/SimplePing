# SimplePing

A modern Swift implementation of ICMP ping functionality for iOS, macOS, watchOS, and tvOS applications. This package provides a clean, async-friendly API for sending and receiving ping packets.

## Features

- ✅ **Modern Swift API**: Built with Swift 5.7+ and modern concurrency patterns
- ✅ **Cross-platform**: Supports iOS 13.0+, macOS 10.15+, watchOS 6.0+, tvOS 13.0+
- ✅ **IPv4 and IPv6 support**: Automatically handles both IP versions
- ✅ **Network framework**: Uses Apple's modern Network framework instead of legacy BSD sockets
- ✅ **Comprehensive testing**: Includes unit tests with high code coverage
- ✅ **Thread-safe**: All operations are properly dispatched to appropriate queues
- ✅ **Memory efficient**: Proper memory management and no retain cycles

## Requirements

- iOS 13.0+ / macOS 10.15+ / watchOS 6.0+ / tvOS 13.0+
- Xcode 14.0+
- Swift 5.7+

## Usage

### Basic Usage

Refer to the available methods for async/await functionality [here](Sources/SimplePing/AsyncSimplePing.swift).

```swift
import SimplePing

@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
class PingExample: SimplePingDelegate {
    private var pinger: SimplePing?
    
    func startPinging() {
        pinger = SimplePing(hostName: "google.com")
        pinger?.delegate = self
        pinger?.start()
    }
    
    func sendPing() {
        pinger?.sendPing()
    }
    
    func stopPinging() {
        pinger?.stop()
        pinger = nil
    }
    
    // MARK: - SimplePingDelegate
    
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        print("Started pinging \\(pinger.hostName)")
        // Now you can start sending pings
        sendPing()
    }
    
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        print("Ping failed: \\(error.localizedDescription)")
    }
    
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {
        print("Sent ping #\\(sequenceNumber)")
    }
    
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {
        print("Received pong #\\(sequenceNumber)")
    }
    
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        print("Received unexpected packet")
    }
}
```

### Advanced Usage

#### Custom Payload

```swift
let customData = "Hello, World!".data(using: .utf8)!
pinger?.sendPing(with: customData)
```

#### IP Version Control

```swift
// Force IPv4
pinger?.addressStyle = .icmpv4

// Force IPv6
pinger?.addressStyle = .icmpv6

// Use any available (default)
pinger?.addressStyle = .any
```

#### Measuring Round-trip Time

```swift
class PingWithTiming: SimplePingDelegate {
    private var pinger: SimplePing?
    private var sendTimes: [UInt16: Date] = [:]
    
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {
        sendTimes[sequenceNumber] = Date()
    }
    
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {
        if let sendTime = sendTimes.removeValue(forKey: sequenceNumber) {
            let roundTripTime = Date().timeIntervalSince(sendTime) * 1000 // Convert to milliseconds
            print("Ping #\\(sequenceNumber): \\(String(format: "%.2f", roundTripTime))ms")
        }
    }
}
```

#### Continuous Ping with Timer

```swift
class ContinuousPing: SimplePingDelegate {
    private var pinger: SimplePing?
    private var timer: Timer?
    
    func startContinuousPing(to hostName: String, interval: TimeInterval = 1.0) {
        pinger = SimplePing(hostName: hostName)
        pinger?.delegate = self
        pinger?.start()
        
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pinger?.sendPing()
        }
    }
    
    func stopContinuousPing() {
        timer?.invalidate()
        timer = nil
        pinger?.stop()
        pinger = nil
    }
    
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        print("Started continuous ping to \\(pinger.hostName)")
    }
    
    // Implement other delegate methods as needed...
}
```

## API Reference

### SimplePing

The main class for ping operations.

#### Properties

- `hostName: String` - The host name or IP address being pinged
- `delegate: SimplePingDelegate?` - The delegate for receiving ping events
- `addressStyle: SimplePingAddressStyle` - Controls IPv4/IPv6 preference
- `hostAddress: Data?` - The resolved host address (available after start)
- `hostAddressFamily: sa_family_t` - The address family of the resolved address
- `identifier: UInt16` - Unique identifier for this ping session
- `nextSequenceNumber: UInt16` - The next sequence number to be used

#### Methods

- `init(hostName: String)` - Initialize with a host name or IP address
- `start()` - Start the ping session (resolves host and prepares for pinging)
- `sendPing(with data: Data? = nil)` - Send a ping packet with optional custom data
- `stop()` - Stop the ping session and clean up resources

### SimplePingDelegate

Protocol for receiving ping events. All methods have default empty implementations.

#### Methods

- `simplePing(_:didStartWithAddress:)` - Called when ping session starts successfully
- `simplePing(_:didFailWithError:)` - Called when ping session fails to start or encounters an error
- `simplePing(_:didSendPacket:sequenceNumber:)` - Called when a ping packet is sent successfully
- `simplePing(_:didFailToSendPacket:sequenceNumber:error:)` - Called when sending a ping packet fails
- `simplePing(_:didReceivePingResponsePacket:sequenceNumber:)` - Called when a ping response is received
- `simplePing(_:didReceiveUnexpectedPacket:)` - Called when an unexpected ICMP packet is received

### SimplePingAddressStyle

Enum controlling IP version preference:

- `.any` - Use the first available address (IPv4 or IPv6)
- `.icmpv4` - Use only IPv4 addresses
- `.icmpv6` - Use only IPv6 addresses

### SimplePingError

Error types that can occur during ping operations:

- `.invalidHostName` - The provided host name is invalid
- `.noAddressFound` - No suitable address found for the host
- `.socketCreationFailed` - Failed to create network socket
- `.bindFailed` - Failed to bind socket
- `.sendFailed` - Failed to send ping packet
- `.receiveFailed` - Failed to receive ping response
- `.invalidPacket` - Received packet is invalid or corrupted
- `.timeout` - Operation timed out

## Testing

The package includes comprehensive unit tests. Run them using:

```bash
swift test
```

Or in Xcode:
1. Open the package in Xcode
2. Press `Cmd+U` to run tests

## License

This project is available under the same license as the original Apple SimplePing sample code. See the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Based on the [original SimplePing](https://developer.apple.com/library/archive/samplecode/SimplePing/Introduction/Intro.html) sample code by Apple Inc., completely rewritten in modern Swift with the Network framework.
