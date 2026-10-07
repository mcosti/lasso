import CoreBluetooth
import Foundation

/// The bike's BLE surface, as reverse engineered by Bronco Unleashed
/// (runerune/BroncoUnleashed) and Cowboy Untamed (Imaginous/Cowboy_Untamed).
///
/// Two GATT services matter:
/// - A Cowboy-specific service whose first characteristic is the lock: write a
///   single byte, 1 = unlock, 0 = lock, and it notifies the current state.
/// - The Nordic UART Service, which carries Modbus RTU frames to the main PCB
///   (slave 0x0A: lights, auto-lock, auto-unlock) and to the ASI motor
///   controller (slave 0x01: speed limit, field weakening, ...).
///
/// All characteristics are encrypted: the bike requires an authenticated bond
/// (6-digit passkey). iOS stores that bond system-wide, so once the official
/// Cowboy app has paired the phone, this app reuses the same bond.
enum CowboyBLE {
    static let cowboyService = CBUUID(string: "C0B0A000-18EB-499D-B266-2F2910744274")
    /// 1 byte: 1 unlocked, 0 locked. Read, write, notify.
    static let lockCharacteristic = CBUUID(string: "C0B0A001-18EB-499D-B266-2F2910744274")
    /// Protobuf `Dashboard` messages while unlocked. Notify.
    static let dashboardCharacteristic = CBUUID(string: "C0B0A00A-18EB-499D-B266-2F2910744274")

    static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Phone → bike (Modbus frames). Write.
    static let uartRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Bike → phone (Modbus replies). Notify.
    static let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// The bike advertises with this local name.
    static let deviceName = "COWBOY"

    static let unlock = Data([1])
    static let lock = Data([0])
}

/// Modbus RTU frames for the Nordic UART characteristic.
enum ModbusCommand {
    enum Slave: UInt8 {
        case motorController = 0x01
        case mainPCB = 0x0A
    }

    /// Function 0x10, write one 16-bit holding register.
    static func write(slave: Slave, register: UInt16, value: UInt16) -> Data {
        var frame = Data([slave.rawValue, 0x10,
                          UInt8(register >> 8), UInt8(register & 0xFF),
                          0x00, 0x01, 0x02,
                          UInt8(value >> 8), UInt8(value & 0xFF)])
        frame.append(crc16(frame))
        return frame
    }

    /// Function 0x03, read one holding register.
    static func read(slave: Slave, register: UInt16) -> Data {
        var frame = Data([slave.rawValue, 0x03,
                          UInt8(register >> 8), UInt8(register & 0xFF),
                          0x00, 0x01])
        frame.append(crc16(frame))
        return frame
    }

    static func lights(on: Bool) -> Data { write(slave: .mainPCB, register: 0x0001, value: on ? 1 : 0) }
    static let readAutoLock = read(slave: .mainPCB, register: 0x0000)
    static let readAutoUnlock = read(slave: .mainPCB, register: 0x0014)
    /// Reboots the communication PCB. Settings are kept.
    static let resetPCB = write(slave: .mainPCB, register: 0x00F2, value: 1)

    /// Modbus CRC-16 (polynomial 0xA001), little-endian, as the bike expects.
    static func crc16(_ data: Data) -> Data {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                let lsb = crc & 1
                crc >>= 1
                if lsb != 0 { crc ^= 0xA001 }
            }
        }
        return Data([UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }
}

/// The dashboard notification, a protobuf message (`dashboard.proto` in Bronco).
/// Fields are only present when they changed, so callers merge into the last
/// known values. Decoded by hand: it is 17 scalar fields, no need for a library.
struct DashboardPacket {
    var tripId: Int32?
    var duration: Int32?        // s since unlock
    var speed: Int32?           // km/h
    var power: Int32?           // W
    var distance: Int32?        // m this trip
    var battery: Int32?         // %
    var assistance: Int32?
    var lights: Int32?
    var batteryVoltage: Int32?  // mV
    var batteryTemp: Float?     // 0.1 K
    var activeDuration: Int32?
    var movingDuration: Int32?
    var pedalTorque: Int32?
    /// Not yet understood; recorded in telemetry so they can be figured out.
    var unknown10: Int32?
    var unknown12: Int32?
    var unknown13: Int32?
    var unknown14: Int32?

    init?(_ data: Data) {
        var reader = ProtobufReader(data)
        var sawField = false
        while let (field, wireType) = reader.tag() {
            sawField = true
            switch wireType {
            case 0:
                guard let value = reader.varint() else { return nil }
                let v = Int32(truncatingIfNeeded: value)
                switch field {
                case 1: tripId = v
                case 2: duration = v
                case 3: speed = v
                case 4: power = v
                case 5: distance = v
                case 6: battery = v
                case 7: assistance = v
                case 8: lights = v
                case 9: batteryVoltage = v
                case 10: unknown10 = v
                case 12: unknown12 = v
                case 13: unknown13 = v
                case 14: unknown14 = v
                case 15: activeDuration = v
                case 16: movingDuration = v
                case 17: pedalTorque = v
                default: break
                }
            case 5:
                guard let bits = reader.fixed32() else { return nil }
                if field == 11 { batteryTemp = Float(bitPattern: bits) }
            case 1:
                guard reader.skip(8) else { return nil }
            case 2:
                guard let length = reader.varint(), reader.skip(Int(length)) else { return nil }
            default:
                return nil
            }
        }
        guard sawField else { return nil }
    }
}

private struct ProtobufReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func tag() -> (field: Int, wireType: Int)? {
        guard index < bytes.count, let key = varint() else { return nil }
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func fixed32() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
        index += 4
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard index + count <= bytes.count else { return false }
        index += count
        return true
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
