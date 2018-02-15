//
//  Transmitter.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CoreBluetooth
import os.log


public protocol TransmitterDelegate: class {
    func transmitter(_ transmitter: Transmitter, didError error: Error)

    func transmitter(_ transmitter: Transmitter, didRead glucose: Glucose)

    func transmitter(_ transmitter: Transmitter, didReadUnknownData data: Data)
}


public enum TransmitterError: Error {
    case authenticationError(String)
    case controlError(String)
}


public final class Transmitter: BluetoothManagerDelegate {

    /// The ID of the transmitter to connect to
    public var ID: String {
        get {
            return id.id
        }
        set(newID) {
            id = TransmitterID(id: newID)
        }
    }

    private var id: TransmitterID

    /// The initial activation date of the transmitter
    public private(set) var activationDate: Date?

    private var lastTimeMessage: TransmitterTimeRxMessage?

    public var passiveModeEnabled: Bool

    public weak var delegate: TransmitterDelegate?

    private let log = OSLog(category: "Transmitter")

    private let bluetoothManager = BluetoothManager()

    private var delegateQueue = DispatchQueue(label: "com.loudnate.xDripG5.delegateQueue", qos: .utility)

    public init(id: String, passiveModeEnabled: Bool = false) {
        self.id = TransmitterID(id: id)
        self.passiveModeEnabled = passiveModeEnabled

        bluetoothManager.delegate = self
    }

    public func resumeScanning() {
        if stayConnected {
            bluetoothManager.scanForPeripheral()
        }
    }

    public func stopScanning() {
        bluetoothManager.disconnect()
    }

    public var isScanning: Bool {
        return bluetoothManager.isScanning
    }

    public var stayConnected: Bool {
        get {
            return bluetoothManager.stayConnected
        }
        set {
            bluetoothManager.stayConnected = newValue

            if newValue {
                bluetoothManager.scanForPeripheral()
            }
        }
    }

    // MARK: - BluetoothManagerDelegate

    func bluetoothManager(_ manager: BluetoothManager, isReadyWithError error: Error?) {
        if let error = error {
            delegateQueue.async {
                self.delegate?.transmitter(self, didError: error)
            }
            return
        }

        manager.peripheralManager?.perform { (peripheral) in
            if self.passiveModeEnabled {
                do {
                    try peripheral.listenToControl()
                } catch let error {
                    self.delegateQueue.async {
                        self.delegate?.transmitter(self, didError: error)
                    }
                }
            } else {
                do {
                    try peripheral.authenticate(id: self.id)
                    let glucose = try peripheral.control()
                    self.delegateQueue.async {
                        self.delegate?.transmitter(self, didRead: glucose)
                    }
                } catch let error {
                    manager.disconnect()

                    self.delegateQueue.async {
                        self.delegate?.transmitter(self, didError: error)
                    }
                }
            }
        }
    }

    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> Bool {

        /// The Dexcom G5 advertises a peripheral name of "DexcomXX"
        /// where "XX" is the last-two characters of the transmitter ID.
        if let name = peripheral.name, name.suffix(2) == id.id.suffix(2) {
            return true
        } else {
            return false
        }
    }

    func bluetoothManager(_ manager: BluetoothManager, didReceiveControlResponse response: Data) {
        guard passiveModeEnabled else { return }

        guard response.count > 0 else { return }

        switch response[0] {
        case GlucoseRxMessage.opcode:
            if  let glucoseMessage = GlucoseRxMessage(data: response),
                let timeMessage = lastTimeMessage,
                let activationDate = activationDate
            {
                delegateQueue.async {
                    self.delegate?.transmitter(self, didRead: Glucose(glucoseMessage: glucoseMessage, timeMessage: timeMessage, activationDate: activationDate))
                }
                return
            }
        case CalibrationDataRxMessage.opcode, SessionStartRxMessage.opcode, SessionStopRxMessage.opcode:
            return // Ignore these messages
        case TransmitterTimeRxMessage.opcode:
            if let timeMessage = TransmitterTimeRxMessage(data: response) {
                self.activationDate = Date(timeIntervalSinceNow: -TimeInterval(timeMessage.currentTime))
                self.lastTimeMessage = timeMessage
                return
            }
        default:
            break
        }

        delegate?.transmitter(self, didReadUnknownData: response)
    }
}


struct TransmitterID {
    let id: String

    init(id: String) {
        self.id = id
    }

    private var cryptKey: Data? {
        return "00\(id)00\(id)".data(using: .utf8)
    }

    func computeHash(of data: Data) -> Data? {
        guard data.count == 8, let key = cryptKey else {
            return nil
        }

        var doubleData = Data(capacity: data.count * 2)
        doubleData.append(data)
        doubleData.append(data)

        guard let outData = try? AESCrypt.encryptData(doubleData, usingKey: key) else {
            return nil
        }

        return outData.subdata(in: 0..<8)
    }
}


// MARK: - Helpers
fileprivate extension PeripheralManager {
    func authenticate(id: TransmitterID) throws {
        let authMessage = AuthRequestTxMessage()
        let authRequestRx: Data

        do {
            _ = try writeValue(authMessage.data, for: .authentication)
            authRequestRx = try readValue(for: .authentication, expectingFirstByte: AuthChallengeRxMessage.opcode)
        } catch let error {
            throw TransmitterError.authenticationError("Error writing transmitter challenge: \(error)")
        }

        guard let challengeRx = AuthChallengeRxMessage(data: authRequestRx) else {
            throw TransmitterError.authenticationError("Unable to parse auth challenge: \(authRequestRx)")
        }

        guard challengeRx.tokenHash == id.computeHash(of: authMessage.singleUseToken) else {
            throw TransmitterError.authenticationError("Transmitter failed auth challenge")
        }

        guard let challengeHash = id.computeHash(of: challengeRx.challenge) else {
            throw TransmitterError.authenticationError("Failed to compute challenge hash for transmitter ID")
        }

        let statusData: Data
        do {
            _ = try writeValue(AuthChallengeTxMessage(challengeHash: challengeHash).data, for: .authentication)
            statusData = try readValue(for: .authentication, expectingFirstByte: AuthStatusRxMessage.opcode)
        } catch let error {
            throw TransmitterError.authenticationError("Error writing challenge response: \(error)")
        }

        guard let status = AuthStatusRxMessage(data: statusData) else {
            throw TransmitterError.authenticationError("Unable to parse auth status: \(statusData)")
        }

        guard status.authenticated == 1 else {
            throw TransmitterError.authenticationError("Transmitter rejected auth challenge")
        }

        if status.bonded != 0x1 {
            try bond()
        }
    }

    private func bond() throws {
        do {
            _ = try writeValue(KeepAliveTxMessage(time: 25).data, for: .authentication)
        } catch let error {
            throw TransmitterError.authenticationError("Error writing keep-alive for bond: \(error)")
        }

        let data: Data
        do {
            // Wait for the OS dialog to pop-up before continuing.
            _ = try writeValue(BondRequestTxMessage().data, for: .authentication)
            data = try readValue(for: .authentication, timeout: 15, expectingFirstByte: AuthStatusRxMessage.opcode)
        } catch let error {
            throw TransmitterError.authenticationError("Error writing bond request: \(error)")
        }

        guard let response = AuthStatusRxMessage(data: data) else {
            throw TransmitterError.authenticationError("Unable to parse auth status: \(data)")
        }

        guard response.bonded == 0x1 else {
            throw TransmitterError.authenticationError("Transmitter failed to bond")
        }
    }

    func control() throws -> Glucose {
        do {
            try setNotifyValue(true, for: .control)
        } catch let error {
            throw TransmitterError.controlError("Error enabling notification: \(error)")
        }

        let timeData: Data
        do {
            timeData = try writeValue(TransmitterTimeTxMessage().data, for: .control, expectingFirstByte: TransmitterTimeRxMessage.opcode)
        } catch let error {
            throw TransmitterError.controlError("Error writing time request: \(error)")
        }

        guard let timeMessage = TransmitterTimeRxMessage(data: timeData) else {
            throw TransmitterError.controlError("Unable to parse time response: \(timeData)")
        }

        let activationDate = Date(timeIntervalSinceNow: -TimeInterval(timeMessage.currentTime))

        let glucoseData: Data
        do {
            glucoseData = try writeValue(GlucoseTxMessage().data, for: .control, expectingFirstByte: GlucoseRxMessage.opcode)
        } catch let error {
            throw TransmitterError.controlError("Error writing glucose request: \(error)")
        }

        guard let glucoseMessage = GlucoseRxMessage(data: glucoseData) else {
            throw TransmitterError.controlError("Unable to parse glucose response: \(glucoseData)")
        }

        defer {
            do {
                try setNotifyValue(false, for: .control)
                _ = try writeValue(DisconnectTxMessage().data, for: .control)
            } catch {
            }
        }

        // Update and notify
        return Glucose(glucoseMessage: glucoseMessage, timeMessage: timeMessage, activationDate: activationDate)
    }

    func listenToControl() throws {
        do {
            try setNotifyValue(true, for: .control)
        } catch let error {
            throw TransmitterError.controlError("Error enabling notification: \(error)")
        }
    }
}
