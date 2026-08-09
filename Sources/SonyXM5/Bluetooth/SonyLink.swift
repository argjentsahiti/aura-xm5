import Foundation
import IOBluetooth

/// Sony's proprietary "Serial HPC" control service.
///
/// The WH-1000XM5 advertises the V2 UUID below on RFCOMM channel 9. Older
/// models (XM3/XM4) use the V1 UUID 96CC203E-5068-46AD-B32D-E316F5E069BA
/// instead, so both are tried in order.
private let serviceUUIDs: [[UInt8]] = [
    // V2 — WH-1000XM5 and newer
    [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
     0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2],
    // V1 — WH-1000XM3 / XM4
    [0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
     0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA],
]

@MainActor
final class SonyLink: NSObject {
    enum State: Equatable {
        case idle
        case waitingForHeadphones
        case connecting
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            Log.write("link", "\(state)")
            onState?(state)
        }
    }

    var onState: ((State) -> Void)?
    var onFrame: ((SonyFrame) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = SonyFrameParser()
    private var seq: UInt8 = 0
    private var retryTimer: Timer?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?

    // MARK: Lifecycle

    /// Starts watching for the headphones and connects whenever they appear.
    func start() {
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        connect()
    }

    func connect() {
        cancelRetry()
        if case .connected = state { return }
        if case .connecting = state { return }

        guard let device = pairedHeadphones() else {
            state = .waitingForHeadphones
            scheduleRetry()
            return
        }
        guard device.isConnected() else {
            state = .waitingForHeadphones
            scheduleRetry()
            return
        }

        registerDisconnect(for: device)
        state = .connecting

        if openChannel(on: device) { return }

        // SDP records aren't cached yet — query, then retry from the callback.
        if device.performSDPQuery(self) != kIOReturnSuccess {
            fail("Could not query headphone services")
        }
    }

    func disconnect() {
        cancelRetry()
        channel?.close()
        channel = nil
        parser.reset()
        state = .idle
    }

    // MARK: Sending

    func send(_ payload: [UInt8]) {
        guard let channel else { return }
        Log.hex("tx", payload)
        let data = SonyFraming.encode(type: Wire.dataMDR, seq: seq, payload: payload)
        seq = 1 &- seq
        write(data, on: channel)
    }

    private func sendAck(for receivedSeq: UInt8) {
        guard let channel else { return }
        write(SonyFraming.encode(type: Wire.dataAck, seq: 1 &- receivedSeq, payload: []), on: channel)
    }

    private func write(_ data: Data, on channel: IOBluetoothRFCOMMChannel) {
        var bytes = [UInt8](data)
        _ = bytes.withUnsafeMutableBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnNoMemory }
            return channel.writeSync(base, length: UInt16(buf.count))
        }
    }

    // MARK: Discovery

    private func pairedHeadphones() -> IOBluetoothDevice? {
        guard let raw = IOBluetoothDevice.pairedDevices() else { return nil }
        let devices = raw.compactMap { $0 as? IOBluetoothDevice }
        return devices.first { SupportedDevices.matches($0.name) }
    }

    @discardableResult
    private func openChannel(on device: IOBluetoothDevice) -> Bool {
        for uuidBytes in serviceUUIDs {
            let uuid = IOBluetoothSDPUUID(bytes: uuidBytes, length: uuidBytes.count)
            guard let record = device.getServiceRecord(for: uuid) else { continue }

            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }

            var opened: IOBluetoothRFCOMMChannel?
            let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            guard result == kIOReturnSuccess else { continue }
            Log.write("link", "opening RFCOMM channel \(channelID)")

            parser.reset()
            channel = opened
            return true
        }
        return false
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        disconnectNote?.unregister()
        disconnectNote = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    // MARK: Retry

    private func scheduleRetry(after delay: TimeInterval = 4) {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retryTimer = nil
                self?.connect()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func fail(_ reason: String) {
        channel = nil
        state = .failed(reason)
        scheduleRetry()
    }

    // MARK: Bluetooth notifications

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard SupportedDevices.matches(device.name) else { return }
        registerDisconnect(for: device)
        // The control service isn't immediately ready when the ACL link comes up.
        scheduleRetry(after: 1.5)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard SupportedDevices.matches(device.name) else { return }
        channel = nil
        parser.reset()
        state = .waitingForHeadphones
        scheduleRetry()
    }
}

// MARK: - SDP

extension SonyLink {
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        Task { @MainActor in
            guard status == kIOReturnSuccess, let device else {
                self.fail("Service lookup failed")
                return
            }
            if !self.openChannel(on: device) {
                self.fail("Control service not available")
            }
        }
    }
}

// MARK: - RFCOMM delegate

extension SonyLink: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let name = ch?.getDevice()?.name ?? "Headphones"
        Task { @MainActor in
            guard error == kIOReturnSuccess else {
                self.fail("Could not open control channel")
                return
            }
            self.state = .connected(name)
        }
    }

    nonisolated func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!,
                                       data pointer: UnsafeMutableRawPointer!,
                                       length: Int) {
        let data = Data(bytes: pointer, count: length)
        Task { @MainActor in
            for frame in self.parser.feed(data) {
                guard frame.type != Wire.dataAck else { continue }
                self.sendAck(for: frame.seq)
                self.onFrame?(frame)
            }
        }
    }

    nonisolated func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor in
            self.channel = nil
            self.parser.reset()
            if case .idle = self.state { return }
            self.state = .waitingForHeadphones
            self.scheduleRetry()
        }
    }
}
