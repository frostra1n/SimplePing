import Foundation

/// A delegate protocol for the SimplePing class.
public protocol SimplePingDelegate: AnyObject, Sendable {
    
    /// Called once the SimplePing object has started up.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - address: The address that's being pinged
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data)
    
    /// Called if the SimplePing object fails to start up.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - error: Describes the failure
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error)
    
    /// Called when the SimplePing object has successfully sent a ping packet.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - packet: The packet that was sent
    ///   - sequenceNumber: The ICMP sequence number of that packet
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16)
    
    /// Called when the SimplePing object fails to send a ping packet.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - packet: The packet that was not sent
    ///   - sequenceNumber: The ICMP sequence number of that packet
    ///   - error: Describes the failure
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error)
    
    /// Called when the SimplePing object receives a ping response.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - packet: The packet received
    ///   - sequenceNumber: The ICMP sequence number of that packet
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16)
    
    /// Called when the SimplePing object receives a ping response with timing information.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - packet: The packet received
    ///   - sequenceNumber: The ICMP sequence number of that packet
    ///   - timeInterval: The round-trip time in seconds
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16, timeInterval: TimeInterval)
    
    /// Called when the SimplePing object receives an unmatched ICMP message.
    /// - Parameters:
    ///   - pinger: The SimplePing object issuing the callback
    ///   - packet: The packet received
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data)
}

// MARK: - Default implementations (all optional)

public extension SimplePingDelegate {
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {}
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {}
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {}
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error) {}
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {}
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16, timeInterval: TimeInterval) {}
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {}
}