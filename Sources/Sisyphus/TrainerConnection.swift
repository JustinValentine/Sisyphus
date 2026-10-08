import Foundation
import CoreBluetooth
import SisyphusCore

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let isHeartRate: Bool
    let signal: Int
}

@MainActor
final class TrainerConnection: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var devices: [NearbyDevice] = []
    @Published var scanning = false
    @Published var ready = false
    @Published var busy = false
    @Published var status = "Connect your trainer"
    @Published var trainerName: String?
    @Published var heartRateName: String?
    @Published var errorMessage: String?
    var onReading: ((BikeReading) -> Void)?
    var onHeartRate: ((Int?) -> Void)?
    var onCommand: ((TrainerCommand) -> Void)?
    var onLoss: (() -> Void)?
    private(set) var powerRange: PowerRange?

    private let fitness = CBUUID(string: "1826")
    private let heartService = CBUUID(string: "180D")
    private let bikeData = CBUUID(string: "2AD2")
    private let controlID = CBUUID(string: "2AD9")
    private let featureID = CBUUID(string: "2ACC")
    private let rangeID = CBUUID(string: "2AD8")
    private let statusID = CBUUID(string: "2ADA")
    private let heartID = CBUUID(string: "2A37")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var trainer: CBPeripheral?
    private var heartSensor: CBPeripheral?
    private var control: CBCharacteristic?
    private var queue = CommandQueue()
    private var timeout: Timer?
    private var connectionTimeout: Timer?
    private var scanTimeout: Timer?
    private var wantScan = false
    private let heartRateKey = "heartRateSensorID"
    /// Reconnecting to the remembered sensor rather than one the rider just picked.
    private var restoringHeartRate = false
    private var featuresOK = false
    private var dataOK = false
    private var controlOK = false

    func scan() {
        errorMessage = nil
        wantScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { beginScan() }
        else { updateBluetoothStatus() }
    }

    /// Reconnects the last heart rate sensor, such as an iPhone sharing AirPods Pro heart rate.
    /// Only runs once a sensor has connected before, so Bluetooth permission is already granted.
    func restoreHeartRateSensor() {
        guard UserDefaults.standard.string(forKey: heartRateKey) != nil else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { reconnectSavedHeartRate() }
    }

    private func reconnectSavedHeartRate() {
        guard heartSensor == nil, let central, central.state == .poweredOn,
              let saved = UserDefaults.standard.string(forKey: heartRateKey), let id = UUID(uuidString: saved),
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        restoringHeartRate = true
        heartSensor = peripheral
        peripheral.delegate = self
        // Connection requests don't time out: this completes whenever the sensor is next in range.
        central.connect(peripheral)
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        devices = []
        // Some KICKRs advertise Cycling Power rather than FTMS, so also inspect their name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        if !ready { status = "Looking for your trainer…" }
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopScan() }
        }
    }

    func stopScan() {
        wantScan = false
        scanning = false
        scanTimeout?.invalidate()
        central?.stopScan()
        if !ready && trainer == nil { status = "Connect your trainer" }
    }

    func connect(_ device: NearbyDevice) {
        guard let peripheral = peripherals[device.id], let central else { return }
        errorMessage = nil
        if device.isHeartRate {
            if let old = heartSensor { central.cancelPeripheralConnection(old) }
            restoringHeartRate = false
            heartSensor = peripheral
        } else {
            guard trainer == nil else { return }
            stopScan()
            resetTransport()
            trainer = peripheral
            trainerName = device.name
            status = "Connecting…"
            connectionTimeout?.invalidate()
            connectionTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.ready else { return }
                    self.fail("Connection timed out. Wake your trainer and try again.")
                }
            }
        }
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func disconnect() {
        stopScan()
        if let trainer { central?.cancelPeripheralConnection(trainer) }
        if let heartSensor { central?.cancelPeripheralConnection(heartSensor) }
        trainer = nil; heartSensor = nil; trainerName = nil; heartRateName = nil
        resetTransport()
        status = "Connect your trainer"
        onHeartRate?(nil)
        onLoss?()
    }

    func start(watts: Int) {
        guard ready else { return }
        queue.replacePending(with: [.requestControl, .power(watts), .start])
        pump()
    }

    func setPower(_ watts: Int) {
        guard ready else { return }
        queue.append(.power(powerRange?.clamped(watts) ?? watts))
        pump()
    }

    func pause() {
        guard ready else { return }
        queue.replacePending(with: [.pause])
        pump()
    }

    func stop() {
        guard ready else { return }
        queue.replacePending(with: [.stop, .reset])
        pump()
    }

    private func pump() {
        guard let trainer, let control, trainer.state == .connected else { return }
        guard let command = queue.next() else { busy = queue.inFlight != nil; return }
        busy = true
        trainer.writeValue(command.bytes, for: control, type: .withResponse)
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail("The trainer stopped responding. Reconnect before resuming.") }
        }
    }

    private func resetTransport() {
        ready = false; busy = false; featuresOK = false; dataOK = false; controlOK = false
        control = nil; powerRange = nil
        queue.clear()
        timeout?.invalidate(); connectionTimeout?.invalidate()
    }

    private func fail(_ message: String) {
        errorMessage = message
        if let trainer { central?.cancelPeripheralConnection(trainer) }
        trainer = nil; trainerName = nil
        resetTransport()
        status = "Reconnect trainer"
        onLoss?()
    }

    private func checkReady() {
        guard featuresOK, dataOK, controlOK, powerRange != nil else { return }
        ready = true
        status = "Ready to ride"
        connectionTimeout?.invalidate()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateBluetoothStatus()
        if central.state == .poweredOn {
            reconnectSavedHeartRate()
            if wantScan { beginScan() }
        } else {
            scanning = false
            if trainer != nil { fail("Bluetooth disconnected. Reconnect before resuming.") }
        }
    }

    private func updateBluetoothStatus() {
        switch central?.state {
        case .poweredOff: errorMessage = "Turn on Bluetooth to connect your trainer."
        case .unauthorized: errorMessage = "Allow Sisyphus in System Settings → Privacy & Security → Bluetooth."
        case .unsupported: errorMessage = "Bluetooth is unavailable on this Mac."
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Nearby trainer"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isTrainer = services.contains(fitness) || name.localizedCaseInsensitiveContains("kickr")
        let isHeart = services.contains(heartService) && !isTrainer
        guard isTrainer || isHeart else { return }
        peripherals[peripheral.identifier] = peripheral
        devices.removeAll { $0.id == peripheral.identifier }
        devices.append(NearbyDevice(id: peripheral.identifier, name: name, isHeartRate: isHeart, signal: RSSI.intValue))
        devices.sort { $0.signal > $1.signal }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == trainer || peripheral == heartSensor else { return }
        if peripheral == trainer { status = "Preparing ERG…" }
        peripheral.discoverServices([peripheral == trainer ? fitness : heartService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral == trainer { fail("Couldn’t connect. Wake the trainer and close other training apps.") }
        else if peripheral == heartSensor {
            heartSensor = nil
            if !restoringHeartRate { errorMessage = "Couldn’t connect the heart rate sensor." }
            restoringHeartRate = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == trainer { fail("Trainer disconnected. Reconnect to continue your ride.") }
        else if peripheral == heartSensor {
            // Straps lose contact and iPhone heart rate apps get suspended; wait for it to come back.
            heartRateName = nil; onHeartRate?(nil)
            central.connect(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == trainer || peripheral == heartSensor else { return }
        if peripheral == trainer {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == fitness }) else {
                fail("This trainer doesn’t expose Bluetooth FTMS. Check its firmware; older KICKRs may need another protocol.")
                return
            }
            peripheral.discoverCharacteristics([bikeData, controlID, featureID, rangeID, statusID], for: service)
        } else if let service = peripheral.services?.first(where: { $0.uuid == heartService }) {
            peripheral.discoverCharacteristics([heartID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == trainer || peripheral == heartSensor else { return }
        if peripheral == trainer {
            let chars = service.characteristics ?? []
            guard error == nil, [bikeData, controlID, featureID, rangeID].allSatisfy({ id in chars.contains { $0.uuid == id } }) else {
                fail("This trainer is missing the Bluetooth controls required for ERG mode.")
                return
            }
            for characteristic in chars {
                switch characteristic.uuid {
                case controlID:
                    guard characteristic.properties.contains(.write), characteristic.properties.contains(.indicate) else {
                        fail("The trainer’s ERG control is unavailable."); return
                    }
                    control = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case bikeData, statusID: peripheral.setNotifyValue(true, for: characteristic)
                case featureID, rangeID: peripheral.readValue(for: characteristic)
                default: break
                }
            }
        } else if let characteristic = service.characteristics?.first(where: { $0.uuid == heartID }) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == trainer || peripheral == heartSensor else { return }
        if peripheral == trainer {
            guard error == nil, characteristic.isNotifying else { fail("Couldn’t subscribe to trainer data."); return }
            if characteristic.uuid == controlID { controlOK = true }
            if characteristic.uuid == bikeData { dataOK = true }
            checkReady()
        } else if error == nil, characteristic.isNotifying {
            heartRateName = peripheral.name ?? "Heart rate sensor"
            restoringHeartRate = false
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: heartRateKey)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == trainer || peripheral == heartSensor else { return }
        guard error == nil, let data = characteristic.value else {
            if peripheral == trainer { fail("Couldn’t read trainer data. Reconnect to try again.") }
            return
        }
        switch characteristic.uuid {
        case bikeData:
            if let reading = FTMS.indoorBike(data) { onReading?(reading) }
        case heartID: onHeartRate?(FTMS.heartRate(data))
        case featureID:
            featuresOK = FTMS.supportsTargetPower(data)
            if !featuresOK { fail("This trainer does not report support for ERG target power.") }
            else { checkReady() }
        case rangeID:
            powerRange = PowerRange(data)
            if powerRange == nil { fail("The trainer returned an invalid power range.") }
            else { checkReady() }
        case controlID:
            guard let response = ControlResponse(data), let command = queue.complete(response) else { return }
            timeout?.invalidate()
            guard response.succeeded else { fail(response.message); return }
            onCommand?(command)
            pump()
        case statusID:
            if data.first == 0xff { fail("Another app took trainer control. Reconnect when you’re ready.") }
            else if data.first == 0x02 || data.first == 0x03 { onLoss?() }
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Keep waiting for the control-point indication after the BLE write is acknowledged.
        if peripheral == trainer, characteristic.uuid == controlID, error != nil {
            fail("Couldn’t send the ERG command. Reconnect to try again.")
        }
    }
}
