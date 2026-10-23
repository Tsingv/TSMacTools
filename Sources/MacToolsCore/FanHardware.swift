import Foundation
import IOKit

public enum SMCError: Error, LocalizedError {
    case unavailable, invalid(String), operation(String), transport(Int32), firmware(UInt8)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "AppleSMC is unavailable or inaccessible."
        case let .invalid(value): return "Unsupported SMC value: \(value)"
        case let .operation(message): return message
        case let .transport(code): return "SMC transport failed: \(code)"
        case let .firmware(code): return "SMC firmware rejected request: \(code)"
        }
    }
}
public struct SMCValue: Equatable, Sendable {
    public var type: String
    public var bytes: [UInt8]
    public init(type: String, bytes: [UInt8]) { self.type = type; self.bytes = bytes }
    public var number: Double? {
        switch (type, bytes.count) {
        case ("ui8 ", 1): return Double(bytes[0])
        case ("ui16", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("fpe2", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits)); return value.isFinite ? value : nil
        default: return nil
        }
    }
    public static func encode(_ number: Double, type: String) throws -> SMCValue {
        guard number.isFinite else { throw SMCError.invalid("nonfinite number") }
        let bytes: [UInt8]
        switch type {
        case "ui8 ": guard (0...255).contains(number) else { throw SMCError.invalid(type) }; bytes = [UInt8(number.rounded())]
        case "ui16", "fpe2", "sp78":
            let scaled = number * (type == "fpe2" ? 4 : type == "sp78" ? 256 : 1)
            guard scaled >= (type == "sp78" ? -32768 : 0), scaled <= (type == "sp78" ? 32767 : 65535) else { throw SMCError.invalid(type) }
            let raw = type == "sp78" ? UInt16(bitPattern: Int16(scaled.rounded())) : UInt16(scaled.rounded())
            bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        case "flt ":
            let bits = Float(number).bitPattern
            guard Float(number).isFinite else { throw SMCError.invalid(type) }
            bytes = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        default: throw SMCError.invalid(type)
        }
        return SMCValue(type: type, bytes: bytes)
    }
}
public protocol SMCIO {
    func keys() throws -> [String]
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, value: SMCValue) throws
}

public struct SMCKeyMetadata: Equatable, Sendable {
    public let type: String
    public let size: Int
    public let attributes: UInt8
    public var isWritable: Bool { attributes & 0x40 != 0 }
    public init(type: String, size: Int, attributes: UInt8) {
        self.type = type; self.size = size; self.attributes = attributes
    }
}
/// Optional capability: legacy fake I/O can still discover mode keys by reading values.
public protocol SMCMetadataIO: SMCIO {
    func metadata(_ key: String) throws -> SMCKeyMetadata
}
public enum FanModeDiscovery {
    public static func key(io: SMCIO, fan: Int) throws -> String {
        let target = try? io.read("F\(fan)Tg")
        let suffixes = target?.type == "flt " ? ["md", "Md"] : ["Md", "md"]
        for suffix in suffixes {
            let key = "F\(fan)\(suffix)"
            if let provider = io as? SMCMetadataIO {
                guard let info = try? provider.metadata(key), info.type == "ui8 ", info.size == 1, info.isWritable else { continue }
            } else {
                guard let value = try? io.read(key), value.type == "ui8 ", value.bytes.count == 1 else { continue }
            }
            return key
        }
        throw SMCError.operation("Fan \(fan): 未发现可写的单字节模式键（md/Md）。")
    }
}

/// All calls are confined by the owner to a serial queue. Uses the 80-byte AppleSMC user-client ABI.
public final class AppleSMC: SMCMetadataIO {
    private var connection: io_connect_t = 0
    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.unavailable }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == KERN_SUCCESS else { throw SMCError.transport(status) }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(command: UInt8, key: String = "", size: UInt32 = 0, index: UInt32 = 0, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.isEmpty || key.utf8.count == 4, size <= 32, bytes.count <= 32 else { throw SMCError.invalid(key) }
        var input = [UInt8](repeating: 0, count: 80), output = input
        func put(_ value: UInt32, at offset: Int) { for i in 0..<4 { input[offset+i] = UInt8((value >> (i*8)) & 255) } }
        put(key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, at: 0)
        put(size, at: 28); input[42] = command; put(index, at: 44)
        for (i, byte) in bytes.enumerated() { input[48+i] = byte }
        var outputSize = 80
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS else { throw SMCError.transport(status) }
        guard outputSize == 80 else { throw SMCError.invalid("response size") }
        guard output[40] == 0 else { throw SMCError.firmware(output[40]) }
        return output
    }
    private func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset+$1]) << ($1*8) }
    }
    public func metadata(_ key: String) throws -> SMCKeyMetadata {
        let info = try call(command: 9, key: key)
        let type = uint32(info, 32)
        let name = String(bytes: (0..<4).map { UInt8((type >> ((3-$0)*8)) & 255) }, encoding: .ascii) ?? ""
        return SMCKeyMetadata(type: name, size: Int(uint32(info, 28)), attributes: info[36])
    }
    public func read(_ key: String) throws -> SMCValue {
        let info = try call(command: 9, key: key)
        let size = uint32(info, 28), type = uint32(info, 32)
        guard size > 0, size <= 32 else { throw SMCError.invalid(key) }
        let name = String(bytes: (0..<4).map { UInt8((type >> ((3-$0)*8)) & 255) }, encoding: .ascii) ?? ""
        let result = try call(command: 5, key: key, size: size)
        return SMCValue(type: name, bytes: Array(result[48..<48+Int(size)]))
    }
    public func write(_ key: String, value: SMCValue) throws {
        let existing = try read(key)
        guard existing.type == value.type, existing.bytes.count == value.bytes.count else { throw SMCError.invalid(key) }
        _ = try call(command: 6, key: key, size: UInt32(value.bytes.count), bytes: value.bytes)
    }
    public func keys() throws -> [String] {
        guard let raw = try read("#KEY").number, raw >= 0, raw <= 16384 else { throw SMCError.invalid("key count") }
        return try (0..<Int(raw)).map { index in
            let response = try call(command: 8, index: UInt32(index))
            let key = uint32(response, 0)
            return String(bytes: (0..<4).map { UInt8((key >> ((3-$0)*8)) & 255) }, encoding: .ascii) ?? ""
        }
    }
}
/// One transform shared by rendering and pointer input, in AppKit's bottom-up coordinates.
public struct FanPlotGeometry {
    public let rect: CGRect
    public init(bounds: CGRect) {
        rect = CGRect(x: bounds.minX + 48, y: bounds.minY + 30,
                      width: max(1, bounds.width - 144), height: max(1, bounds.height - 100))
    }
    public func location(temperature: Double, percent: Double) -> CGPoint {
        CGPoint(x: rect.minX + (temperature - 20) / 90 * rect.width,
                y: rect.minY + percent / 100 * rect.height)
    }
    public func reading(at point: CGPoint) -> (temperature: Double, percent: Double) {
        (20 + (point.x - rect.minX) / rect.width * 90, (point.y - rect.minY) / rect.height * 100)
    }
}

public struct FanSensorDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var rawKey: String
    public var displayName: String
    public var area: String
    public var curated: Bool
}

public enum FanSensorMetadata {
    private static func integer(_ key: String) -> Int {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname(key, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }
    private static func text(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    public static let model = text("hw.model")
    public static let topology: [String: Int] = {
        var result: [String: Int] = [:]
        for i in 0..<8 { let name = text("hw.perflevel\(i).name"); if !name.isEmpty { result[name] = integer("hw.perflevel\(i).physicalcpu") } }
        return result
    }()
    public static var hasSuperCluster: Bool { topology["Super", default: 0] > 0 }
    public static func valid(_ value: Double) -> Bool { value.isFinite && value > 0 && value <= 130 }
    public static func eligible(_ key: String) -> Bool {
        (key.hasPrefix("T") || key.hasPrefix("ft") || key.hasPrefix("sd")) && !key.hasPrefix("Tz") && !["TTPD", "TVMD", "TVmS", "TfCB"].contains(key)
    }
    public static func temperature(_ value: SMCValue) -> Double? {
        guard (value.type == "flt " && value.bytes.count == 4) || (value.type == "sp78" && value.bytes.count == 2), let number = value.number, valid(number) else { return nil }
        return number
    }
    // Factual model/key/name/area observations transcribed from FanPilot cb42bac0; see docs/parity/fan-sensors.md.
    private static let modelTables: [String: Int] = [
        "Mac13,1": 0,
        "Mac13,2": 0,
        "Mac14,10": 1,
        "Mac14,12": 2,
        "Mac14,13": 3,
        "Mac14,14": 4,
        "Mac14,15": 5,
        "Mac14,2": 5,
        "Mac14,3": 2,
        "Mac14,5": 6,
        "Mac14,6": 1,
        "Mac14,7": 7,
        "Mac14,8": 8,
        "Mac14,9": 6,
        "Mac15,10": 9,
        "Mac15,11": 9,
        "Mac15,12": 10,
        "Mac15,13": 10,
        "Mac15,14": 11,
        "Mac15,2": 10,
        "Mac15,3": 10,
        "Mac15,4": 12,
        "Mac15,5": 12,
        "Mac15,6": 13,
        "Mac15,7": 13,
        "Mac15,8": 9,
        "Mac15,9": 9,
        "Mac16,1": 14,
        "Mac16,10": 15,
        "Mac16,11": 16,
        "Mac16,12": 17,
        "Mac16,13": 17,
        "Mac16,2": 18,
        "Mac16,3": 18,
        "Mac16,5": 19,
        "Mac16,6": 19,
        "Mac16,7": 20,
        "Mac16,8": 20,
        "Mac16,9": 21,
        "Mac17,14": 22,
        "Mac17,15": 23,
        "Mac17,16": 24,
        "Mac17,2": 25,
        "Mac17,3": 26,
        "Mac17,4": 26,
        "Mac17,5": 27,
        "Mac17,6": 28,
        "Mac17,7": 28,
        "Mac17,8": 28,
        "Mac17,9": 28,
        "Mac18,5": 29,
        "MacBookAir10,1": 30,
        "MacBookPro17,1": 31,
        "MacBookPro18,1": 32,
        "MacBookPro18,2": 32,
        "MacBookPro18,3": 32,
        "MacBookPro18,4": 32,
        "Macmini9,1": 33,
        "iMac21,1": 34,
        "iMac21,2": 35
    ]
    private static let tables: [String] = [
        "smc|Tp09|Efficiency Core 1|CPU;smc|Tp0T|Efficiency Core 2|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp05|Performance Core 2|CPU;smc|Tp0D|Performance Core 3|CPU;smc|Tp0H|Performance Core 4|CPU;smc|Tp0L|Performance Core 5|CPU;smc|Tp0P|Performance Core 6|CPU;smc|Tp0X|Performance Core 7|CPU;smc|Tp0b|Performance Core 8|CPU;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TT0D|Rear Thunderbolt Port 1|Ports;smc|TT1D|Rear Thunderbolt Port 2|Ports;smc|TT2D|Rear Thunderbolt Port 3|Ports;smc|TT3D|Rear Thunderbolt Port 4|Ports;smc|TT4D|Front Thunderbolt Port 1|Ports;smc|TT5D|Front Thunderbolt Port 2|Ports;smc|TW0P|Wireless Proximity|Wireless;smc|Tg05|GPU Cluster 1|GPU;smc|Tg0D|GPU Cluster 2|GPU;smc|Tg0L|GPU Cluster 3|GPU;smc|Tg0T|GPU Cluster 4|GPU;smc|Tm01|Memory Bank 1|Memory;smc|Tm05|Memory Bank 2|Memory;smc|Tm09|Memory Bank 3|Memory;smc|Tm0D|Memory Bank 4|Memory",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0b|Efficiency Core 2|CPU;smc|Tp1F|Efficiency Core 3|CPU;smc|Tp1l|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0X|Performance Core 3|CPU;smc|Tp0f|Performance Core 4|CPU;smc|Tp1B|Performance Core 5|CPU;smc|Tp1J|Performance Core 6|CPU;smc|Tp1h|Performance Core 7|CPU;smc|Tp1p|Performance Core 8|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg1h|GPU Cluster 2|GPU;smc|Tg2X|GPU Cluster 3|GPU;smc|Tg3Z|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0D|Efficiency Core 2|CPU;smc|Tp0j|Efficiency Core 3|CPU;smc|Tp0r|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0f|Performance Core 3|CPU;smc|Tp0n|Performance Core 4|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg0j|GPU Cluster 2|GPU;smc|Tg0h|GPU Cluster 3|GPU;smc|Tg0l|GPU Cluster 4|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;smc|TIED|Ethernet|Airflow;smc|TIOP|Highspeed I/O Proximity|Airflow;smc|Tm0P|Memory Proximity 1|Memory;smc|Tm2P|Memory Proximity 2|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0b|Efficiency Core 2|CPU;smc|Tp1F|Efficiency Core 3|CPU;smc|Tp1l|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0X|Performance Core 3|CPU;smc|Tp0f|Performance Core 4|CPU;smc|Tp1B|Performance Core 5|CPU;smc|Tp1J|Performance Core 6|CPU;smc|Tp1h|Performance Core 7|CPU;smc|Tp1p|Performance Core 8|CPU",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0b|Efficiency Core 2|CPU;smc|Tp1F|Efficiency Core 3|CPU;smc|Tp1l|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0X|Performance Core 3|CPU;smc|Tp0f|Performance Core 4|CPU;smc|Tp1B|Performance Core 5|CPU;smc|Tp1J|Performance Core 6|CPU;smc|Tp1h|Performance Core 7|CPU;smc|Tp1p|Performance Core 8|CPU;smc|Tp55|Efficiency Core 5|CPU;smc|Tp5b|Efficiency Core 6|CPU;smc|Tp6F|Efficiency Core 7|CPU;smc|Tp6l|Efficiency Core 8|CPU;smc|Tp51|Performance Core 9|CPU;smc|Tp59|Performance Core 10|CPU;smc|Tp5X|Performance Core 11|CPU;smc|Tp5f|Performance Core 12|CPU;smc|Tp6B|Performance Core 13|CPU;smc|Tp6J|Performance Core 14|CPU;smc|Tp6h|Performance Core 15|CPU;smc|Tp6p|Performance Core 16|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg1h|GPU Cluster 2|GPU;smc|Tg2X|GPU Cluster 3|GPU;smc|Tg3Z|GPU Cluster 4|GPU;smc|Tg5f|GPU Cluster 5|GPU;smc|Tg6h|GPU Cluster 6|GPU;smc|Tg7X|GPU Cluster 7|GPU;smc|Tg8Z|GPU Cluster 8|GPU;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0D|Efficiency Core 2|CPU;smc|Tp0j|Efficiency Core 3|CPU;smc|Tp0r|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0f|Performance Core 3|CPU;smc|Tp0n|Performance Core 4|CPU;smc|Tp0b|Processor Package Proximity|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg0n|GPU Cluster 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0x|SSD|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0b|Efficiency Core 2|CPU;smc|Tp1F|Efficiency Core 3|CPU;smc|Tp1l|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0X|Performance Core 3|CPU;smc|Tp1B|Performance Core 4|CPU;smc|Tp1J|Performance Core 5|CPU;smc|Tp1h|Performance Core 6|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg1h|GPU Cluster 2|GPU;smc|Tg2X|GPU Cluster 3|GPU;smc|Tg3Z|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0D|Efficiency Core 2|CPU;smc|Tp0j|Efficiency Core 3|CPU;smc|Tp0r|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0f|Performance Core 3|CPU;smc|Tp0n|Performance Core 4|CPU;smc|Tp0b|Processor Package Proximity|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg0n|GPU Cluster 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp05|Efficiency Core 1|CPU;smc|Tp0b|Efficiency Core 2|CPU;smc|Tp1F|Efficiency Core 3|CPU;smc|Tp1l|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0X|Performance Core 3|CPU;smc|Tp0f|Performance Core 4|CPU;smc|Tp1B|Performance Core 5|CPU;smc|Tp1J|Performance Core 6|CPU;smc|Tp1h|Performance Core 7|CPU;smc|Tp1p|Performance Core 8|CPU;smc|Tp55|Efficiency Core 5|CPU;smc|Tp5b|Efficiency Core 6|CPU;smc|Tp6F|Efficiency Core 7|CPU;smc|Tp6l|Efficiency Core 8|CPU;smc|Tp51|Performance Core 9|CPU;smc|Tp59|Performance Core 10|CPU;smc|Tp5X|Performance Core 11|CPU;smc|Tp5f|Performance Core 12|CPU;smc|Tp6B|Performance Core 13|CPU;smc|Tp6J|Performance Core 14|CPU;smc|Tp6h|Performance Core 15|CPU;smc|Tp6p|Performance Core 16|CPU;smc|Tg0f|GPU Cluster 1|GPU;smc|Tg0j|GPU Cluster 2|GPU;smc|Tg1h|GPU Cluster 3|GPU;smc|Tg1l|GPU Cluster 4|GPU;smc|Tg2f|GPU Cluster 5|GPU;smc|Tg5f|GPU Cluster 6|GPU;smc|Tg5j|GPU Cluster 7|GPU;smc|Tg6h|GPU Cluster 8|GPU;smc|Tg6l|GPU Cluster 9|GPU;smc|Tg7f|GPU Cluster 10|GPU;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD 1|Storage;smc|TH0b|SSD 2|Storage;smc|TH0p|SSD Proximity|Storage;smc|Tm0p|Memory Proximity 1|Memory;smc|Tm1p|Memory Proximity 2|Memory;smc|Tm3p|Memory Proximity 3|Memory;smc|Tm4p|Memory Proximity 4|Memory;smc|Tm5p|Memory Proximity 5|Memory;smc|TI0p|Thunderbolt Proximity 1|Ports;smc|TI1p|Thunderbolt Proximity 2|Ports",
        "smc|ftE0|Efficiency Core 1|CPU;smc|Te05|Efficiency Core 2|CPU;smc|ftE1|Efficiency Core 3|CPU;smc|Te0L|Efficiency Core 4|CPU;smc|ftP1|Performance Core 1|CPU;smc|ftP3|Performance Core 2|CPU;smc|ftP5|Performance Core 3|CPU;smc|ftP7|Performance Core 4|CPU;smc|ftP9|Performance Core 5|CPU;smc|ftPb|Performance Core 6|CPU;smc|ftPf|Performance Core 7|CPU;smc|ftPh|Performance Core 8|CPU;smc|ftPj|Performance Core 9|CPU;smc|ftPl|Performance Core 10|CPU;smc|ftPn|Performance Core 11|CPU;smc|ftPp|Performance Core 12|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|ftG7|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaLW|Airflow Left Side|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TaRW|Airflow Right Side|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te06|Efficiency Core 2|CPU;smc|Te0M|Efficiency Core 3|CPU;smc|Te0P|Efficiency Core 4|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP4|Performance Core 2|CPU;smc|ftP8|Performance Core 3|CPU;smc|ftPc|Performance Core 4|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|ftE0|Efficiency Core 1|CPU;smc|Te05|Efficiency Core 2|CPU;smc|ftE1|Efficiency Core 3|CPU;smc|Te0L|Efficiency Core 4|CPU;smc|ftE2|Efficiency Core 5|CPU;smc|Te55|Efficiency Core 6|CPU;smc|ftE3|Efficiency Core 7|CPU;smc|Te5L|Efficiency Core 8|CPU;smc|ftP1|Performance Core 1|CPU;smc|ftP3|Performance Core 2|CPU;smc|ftP5|Performance Core 3|CPU;smc|ftP7|Performance Core 4|CPU;smc|ftP9|Performance Core 5|CPU;smc|ftPb|Performance Core 6|CPU;smc|ftPf|Performance Core 7|CPU;smc|ftPh|Performance Core 8|CPU;smc|ftPj|Performance Core 9|CPU;smc|ftPl|Performance Core 10|CPU;smc|ftPn|Performance Core 11|CPU;smc|ftPp|Performance Core 12|CPU;smc|ftPs|Performance Core 13|CPU;smc|ftPv|Performance Core 14|CPU;smc|ftPx|Performance Core 15|CPU;smc|ftPz|Performance Core 16|CPU;smc|ftPB|Performance Core 17|CPU;smc|ftPD|Performance Core 18|CPU;smc|ftPH|Performance Core 19|CPU;smc|ftPJ|Performance Core 20|CPU;smc|ftPL|Performance Core 21|CPU;smc|ftPN|Performance Core 22|CPU;smc|ftPP|Performance Core 23|CPU;smc|ftPR|Performance Core 24|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|ftG7|GPU Cluster 4|GPU;smc|ftG9|GPU Cluster 5|GPU;smc|ftGb|GPU Cluster 6|GPU;smc|ftGd|GPU Cluster 7|GPU;smc|ftGf|GPU Cluster 8|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te06|Efficiency Core 2|CPU;smc|Te0M|Efficiency Core 3|CPU;smc|Te0P|Efficiency Core 4|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP4|Performance Core 2|CPU;smc|ftP8|Performance Core 3|CPU;smc|ftPc|Performance Core 4|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|Tb0P|Backlight Controller Proximity|Display;smc|TL0P|LCD Panel 1|Display;smc|TL1P|LCD Panel 2|Display;smc|TL2P|LCD Panel 3|Display;smc|TL3P|LCD Panel 4|Display;smc|TL4P|LCD Panel 5|Display;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|ftE0|Efficiency Core 2|CPU;smc|Te0H|Efficiency Core 3|CPU;smc|ftE1|Efficiency Core 4|CPU;smc|Te0S|Efficiency Core 5|CPU;smc|ftE2|Efficiency Core 6|CPU;smc|ftP1|Performance Core 1|CPU;smc|ftP3|Performance Core 2|CPU;smc|ftP5|Performance Core 3|CPU;smc|ftP7|Performance Core 4|CPU;smc|ftP9|Performance Core 5|CPU;smc|ftPb|Performance Core 6|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|ftG7|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaLW|Airflow Left Side|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TaRW|Airflow Right Side|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te09|Efficiency Core 2|CPU;smc|Te0H|Efficiency Core 3|CPU;smc|Te0S|Efficiency Core 4|CPU;smc|Te0U|Efficiency Core 5|CPU;smc|Te0X|Efficiency Core 6|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP2|Performance Core 2|CPU;smc|ftP4|Performance Core 3|CPU;smc|ftP6|Performance Core 4|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG5|GPU Cluster 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te09|Efficiency Core 2|CPU;smc|Te0H|Efficiency Core 3|CPU;smc|Te0S|Efficiency Core 4|CPU;smc|Te0U|Efficiency Core 5|CPU;smc|Te0X|Efficiency Core 6|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP2|Performance Core 2|CPU;smc|ftP4|Performance Core 3|CPU;smc|ftP6|Performance Core 4|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG2|GPU Cluster 2|GPU;smc|ftG5|GPU Cluster 3|GPU;smc|ftG6|GPU Cluster 4|GPU;smc|ftG7|GPU Cluster 5|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|Ta0p|Internal Ambient|Airflow;smc|TIED|Ethernet|Airflow;smc|Tm0p|Memory Proximity 1|Memory;smc|Tm1p|Memory Proximity 2|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|ftE0|Efficiency Core 2|CPU;smc|Te0S|Efficiency Core 3|CPU;smc|ftE1|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0H|Performance Core 3|CPU;smc|Tp0P|Performance Core 4|CPU;smc|Tp0X|Performance Core 5|CPU;smc|Tp1j|Performance Core 6|CPU;smc|Tp1t|Performance Core 7|CPU;smc|Tp1z|Performance Core 8|CPU;smc|Tp25|Performance Core 9|CPU;smc|Tp2B|Performance Core 10|CPU;smc|ftG0|GPU Cluster 1|GPU;smc|ftG2|GPU Cluster 2|GPU;smc|ftG4|GPU Cluster 3|GPU;smc|ftG6|GPU Cluster 4|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|Ta0p|Internal Ambient|Airflow;smc|TIED|Ethernet|Airflow;smc|Tm0p|Memory Proximity 1|Memory;smc|Tm1p|Memory Proximity 2|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te09|Efficiency Core 2|CPU;smc|Te0H|Efficiency Core 3|CPU;smc|Te0S|Efficiency Core 4|CPU;smc|Te0U|Efficiency Core 5|CPU;smc|Te0W|Efficiency Core 6|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP2|Performance Core 2|CPU;smc|ftP4|Performance Core 3|CPU;smc|ftP6|Performance Core 4|CPU;smc|ftG1|GPU Cluster 1|GPU;smc|ftG5|GPU Cluster 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|Te09|Efficiency Core 2|CPU;smc|Te0H|Efficiency Core 3|CPU;smc|Te0S|Efficiency Core 4|CPU;smc|Te0U|Efficiency Core 5|CPU;smc|Te0X|Efficiency Core 6|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP2|Performance Core 2|CPU;smc|ftP4|Performance Core 3|CPU;smc|ftP6|Performance Core 4|CPU;smc|ftG1|GPU Cluster G1|GPU;smc|ftG2|GPU Cluster G2|GPU;smc|ftG5|GPU Cluster G3|GPU;smc|ftG6|GPU Cluster G4|GPU;smc|ftG7|GPU Cluster G5|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|Tb0P|Backlight Controller Proximity|Display;smc|TL0P|LCD Panel 1|Display;smc|TL1P|LCD Panel 2|Display;smc|TL2P|LCD Panel 3|Display;smc|TL3P|LCD Panel 4|Display;smc|TL4P|LCD Panel 5|Display;smc|Tm0p|Memory Proximity 1|Memory;smc|Tm1p|Memory Proximity 2|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|ftE0|Efficiency Core 2|CPU;smc|Te0S|Efficiency Core 3|CPU;smc|ftE1|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0H|Performance Core 3|CPU;smc|Tp0P|Performance Core 4|CPU;smc|Tp0X|Performance Core 5|CPU;smc|Tp0e|Performance Core 6|CPU;smc|Tp1j|Performance Core 7|CPU;smc|Tp1t|Performance Core 8|CPU;smc|Tp1z|Performance Core 9|CPU;smc|Tp25|Performance Core 10|CPU;smc|Tp2B|Performance Core 11|CPU;smc|Tp2J|Performance Core 12|CPU;smc|ftG0|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG6|GPU Cluster 3|GPU;smc|ftG9|GPU Cluster 4|GPU;smc|ftGc|GPU Cluster 5|GPU;smc|ftGf|GPU Cluster 6|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|ftE0|Efficiency Core 2|CPU;smc|Te0S|Efficiency Core 3|CPU;smc|ftE1|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0H|Performance Core 3|CPU;smc|Tp0P|Performance Core 4|CPU;smc|Tp0X|Performance Core 5|CPU;smc|Tp1j|Performance Core 6|CPU;smc|Tp1t|Performance Core 7|CPU;smc|Tp1z|Performance Core 8|CPU;smc|Tp25|Performance Core 9|CPU;smc|Tp2B|Performance Core 10|CPU;smc|ftG0|GPU Cluster 1|GPU;smc|ftG2|GPU Cluster 2|GPU;smc|ftG4|GPU Cluster 3|GPU;smc|ftG6|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Te05|Efficiency Core 1|CPU;smc|ftE0|Efficiency Core 2|CPU;smc|Te0S|Efficiency Core 3|CPU;smc|ftE1|Efficiency Core 4|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp09|Performance Core 2|CPU;smc|Tp0H|Performance Core 3|CPU;smc|Tp0P|Performance Core 4|CPU;smc|Tp0X|Performance Core 5|CPU;smc|Tp0e|Performance Core 6|CPU;smc|Tp1j|Performance Core 7|CPU;smc|Tp1t|Performance Core 8|CPU;smc|Tp1z|Performance Core 9|CPU;smc|Tp25|Performance Core 10|CPU;smc|Tp2B|Performance Core 11|CPU;smc|Tp2J|Performance Core 12|CPU;smc|ftG0|GPU Cluster 1|GPU;smc|ftG3|GPU Cluster 2|GPU;smc|ftG6|GPU Cluster 3|GPU;smc|ftG9|GPU Cluster 4|GPU;smc|ftGc|GPU Cluster 5|GPU;smc|ftGf|GPU Cluster 6|GPU;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power",
        "smc|Tp04|Super Core 1|CPU;smc|Tp0G|Super Core 2|CPU;smc|Tp0R|Super Core 3|CPU;smc|Tp0a|Super Core 4|CPU;smc|Tp0j|Super Core 5|CPU;smc|Tp0u|Super Core 6|CPU;smc|Tm04|Performance Core 1|CPU;smc|Tm0G|Performance Core 2|CPU;smc|Tm0R|Performance Core 3|CPU;smc|Tm0a|Performance Core 4|CPU;smc|Tm0j|Performance Core 5|CPU;smc|Tm0u|Performance Core 6|CPU;smc|Tm1Q|Performance Core 7|CPU;smc|Tm1c|Performance Core 8|CPU;smc|Tm1o|Performance Core 9|CPU;smc|Tm21|Performance Core 10|CPU;smc|Tm2D|Performance Core 11|CPU;smc|Tm2P|Performance Core 12|CPU;smc|Tg08|GPU Region 1|GPU;smc|Tg12|GPU Region 2|GPU;smc|Tg29|GPU Region 3|GPU;smc|Tg3B|GPU Region 4|GPU;smc|Tg43|GPU Region 5|GPU;smc|Tg50|GPU Region 6|GPU;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;smc|TI0p|I/O Ports Proximity|Airflow;smc|TS0p|SoC Die Proximity|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|TMVR|Memory Voltage Regulator|Memory;smc|TPSD|Power Supply|Power;smc|TPSp|Power Supply Proximity|Power;smc|TB0p|Rear Thunderbolt Ports Proximity|Ports;smc|TB1p|Front USB-C Ports Proximity|Ports;smc|TBBp|Thunderbolt Board Proximity|Ports;smc|TW0p|Wireless Proximity|Wireless",
        "smc|Tp01|Super Core 1|CPU;smc|Tp04|Super Core 2|CPU;smc|Tp07|Super Core 3|CPU;smc|Tp0A|Super Core 4|CPU;smc|Tp0D|Super Core 5|CPU;smc|Tp0G|Super Core 6|CPU;smc|Tp0J|Super Core 7|CPU;smc|Tp0a|Super Core 8|CPU;smc|Tp0d|Super Core 9|CPU;smc|Tp0g|Super Core 10|CPU;smc|Tp0u|Super Core 11|CPU;smc|Tp0x|Super Core 12|CPU;smc|Tm01|Performance Core 1|CPU;smc|Tm04|Performance Core 2|CPU;smc|Tm07|Performance Core 3|CPU;smc|Tm0A|Performance Core 4|CPU;smc|Tm0D|Performance Core 5|CPU;smc|Tm0L|Performance Core 6|CPU;smc|Tm0O|Performance Core 7|CPU;smc|Tm0R|Performance Core 8|CPU;smc|Tm0U|Performance Core 9|CPU;smc|Tm0X|Performance Core 10|CPU;smc|Tm0a|Performance Core 11|CPU;smc|Tm0d|Performance Core 12|CPU;smc|Tm0g|Performance Core 13|CPU;smc|Tm0o|Performance Core 14|CPU;smc|Tm0r|Performance Core 15|CPU;smc|Tm0u|Performance Core 16|CPU;smc|Tm0x|Performance Core 17|CPU;smc|Tm10|Performance Core 18|CPU;smc|Tm18|Performance Core 19|CPU;smc|Tm1b|Performance Core 20|CPU;smc|Tm1e|Performance Core 21|CPU;smc|Tm1h|Performance Core 22|CPU;smc|Tm1k|Performance Core 23|CPU;smc|Tm1n|Performance Core 24|CPU;smc|Tg0G|GPU Region 1|GPU;smc|Tg0p|GPU Region 2|GPU;smc|Tg1N|GPU Region 3|GPU;smc|Tg1g|GPU Region 4|GPU;smc|Tg2O|GPU Region 5|GPU;smc|Tg2x|GPU Region 6|GPU;smc|Tg3V|GPU Region 7|GPU;smc|Tg3o|GPU Region 8|GPU;smc|TaFL|Airflow Front Left|Airflow;smc|TaFR|Airflow Front Right|Airflow;smc|TaRL|Airflow Rear Left|Airflow;smc|TaRR|Airflow Rear Right|Airflow;smc|TI0p|I/O Ports Proximity|Airflow;smc|TS0p|SoC Die 1 Proximity|Airflow;smc|TS1p|SoC Die 2 Proximity|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|TMVR|Memory Voltage Regulator|Memory;smc|TPSD|Power Supply|Power;smc|TPSp|Power Supply Proximity|Power;smc|TB0p|Rear Thunderbolt Ports Proximity|Ports;smc|TB2p|Front Thunderbolt Ports Proximity|Ports;smc|TBBp|Thunderbolt Board Proximity|Ports;smc|TW0p|Wireless Proximity|Wireless",
        "smc|Tp04|Super Core 1|CPU;smc|Tp0G|Super Core 2|CPU;smc|Tp0R|Super Core 3|CPU;smc|Tp0a|Super Core 4|CPU;smc|Tp0j|Super Core 5|CPU;smc|Tp0u|Super Core 6|CPU;smc|Tm04|Performance Core 1|CPU;smc|Tm0G|Performance Core 2|CPU;smc|Tm0R|Performance Core 3|CPU;smc|Tm0a|Performance Core 4|CPU;smc|Tm0j|Performance Core 5|CPU;smc|Tm0u|Performance Core 6|CPU;smc|Tm1Q|Performance Core 7|CPU;smc|Tm1c|Performance Core 8|CPU;smc|Tm1o|Performance Core 9|CPU;smc|Tm21|Performance Core 10|CPU;smc|Tm2D|Performance Core 11|CPU;smc|Tm2P|Performance Core 12|CPU;smc|Tg08|GPU Region 1|GPU;smc|Tg12|GPU Region 2|GPU;smc|Tg29|GPU Region 3|GPU;smc|Tg3B|GPU Region 4|GPU;smc|Tg43|GPU Region 5|GPU;smc|Tg50|GPU Region 6|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|Ta0p|Internal Ambient|Airflow;smc|TIED|Ethernet|Airflow;smc|TMVR|Memory Voltage Regulator|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TT0P|Thunderbolt Controller Proximity|Ports;smc|THSP|Thunderbolt Ports Proximity|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|sd43|Efficiency Core 1|CPU;smc|sd46|Efficiency Core 2|CPU;smc|sd4A|Efficiency Core 3|CPU;smc|sd4D|Efficiency Core 4|CPU;smc|sd4G|Efficiency Core 5|CPU;smc|sd4M|Efficiency Core 6|CPU;smc|Tp00|Super Core 1|CPU;smc|Tp0C|Super Core 2|CPU;smc|Tp0O|Super Core 3|CPU;smc|Tp0X|Super Core 4|CPU;smc|Tg0K|GPU Region 1|GPU;smc|Tg1M|GPU Region 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0A|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|sd43|Efficiency Core 1|CPU;smc|sd46|Efficiency Core 2|CPU;smc|sd4A|Efficiency Core 3|CPU;smc|sd4D|Efficiency Core 4|CPU;smc|sd4G|Efficiency Core 5|CPU;smc|sd4M|Efficiency Core 6|CPU;smc|Tp00|Super Core 1|CPU;smc|Tp0C|Super Core 2|CPU;smc|Tp0O|Super Core 3|CPU;smc|Tp0X|Super Core 4|CPU;smc|Tg0K|GPU Region 1|GPU;smc|Tg1M|GPU Region 2|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0T|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|ftE0|Efficiency Core 1|CPU;smc|Te05|Efficiency Core 2|CPU;smc|ftE1|Efficiency Core 3|CPU;smc|Te0S|Efficiency Core 4|CPU;smc|ftP0|Performance Core 1|CPU;smc|ftP2|Performance Core 2|CPU;smc|Tg04|GPU Region 1|GPU;smc|Tg0C|GPU Region 2|GPU;smc|TB0T|Battery|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TH0p|SSD Proximity|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|TS0P|Trackpad|Palm Rest;smc|TS1P|Trackpad Actuator|Palm Rest;smc|TW0p|Wireless Proximity|Wireless",
        "smc|Tp04|Super Core 1|CPU;smc|Tp0G|Super Core 2|CPU;smc|Tp0R|Super Core 3|CPU;smc|Tp0a|Super Core 4|CPU;smc|Tp0j|Super Core 5|CPU;smc|Tp0u|Super Core 6|CPU;smc|Tm04|Performance Core 1|CPU;smc|Tm0G|Performance Core 2|CPU;smc|Tm0R|Performance Core 3|CPU;smc|Tm0a|Performance Core 4|CPU;smc|Tm0j|Performance Core 5|CPU;smc|Tm0u|Performance Core 6|CPU;smc|Tm1Q|Performance Core 7|CPU;smc|Tm1c|Performance Core 8|CPU;smc|Tm1o|Performance Core 9|CPU;smc|Tm21|Performance Core 10|CPU;smc|Tm2D|Performance Core 11|CPU;smc|Tm2P|Performance Core 12|CPU;smc|Tg08|GPU Region 1|GPU;smc|Tg12|GPU Region 2|GPU;smc|Tg29|GPU Region 3|GPU;smc|Tg3B|GPU Region 4|GPU;smc|Tg43|GPU Region 5|GPU;smc|Tg50|GPU Region 6|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;smc|TaTP|Airflow Top|Airflow;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp0g|Super Core 1|CPU;smc|Tp0j|Super Core 2|CPU;smc|Tp05|Performance Core 1|CPU;smc|Tp07|Performance Core 2|CPU;smc|Tp09|Performance Core 3|CPU;smc|Tp0b|Performance Core 4|CPU;smc|Te07|Efficiency Core 1|CPU;smc|Te08|Efficiency Core 2|CPU;smc|Te09|Efficiency Core 3|CPU;smc|Te0e|Efficiency Core 4|CPU;smc|Te0h|Efficiency Core 5|CPU;smc|Te0i|Efficiency Core 6|CPU;smc|Tg01|GPU Region 1|GPU;smc|Tg0a|GPU Region 2|GPU;smc|Tg17|GPU Region 3|GPU;smc|Tg1d|GPU Region 4|GPU;smc|Tg1h|GPU Region 5|GPU;smc|TH0a|SSD|Storage;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|Ta0p|Internal Ambient|Airflow;smc|TIED|Ethernet|Airflow;smc|TMVR|Memory Voltage Regulator|Memory;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TT0P|Thunderbolt Controller Proximity|Ports;smc|THSP|Thunderbolt Ports Proximity|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TCHP|Charger Proximity|Power;hid|PMGR SOC Die Temp Sensor0|Power Manager SOC 1|SoC;hid|PMGR SOC Die Temp Sensor1|Power Manager SOC 2|SoC;hid|PMGR SOC Die Temp Sensor2|Power Manager SOC 3|SoC;hid|PMU tdie1|Power Manager Die 1|SoC;hid|PMU tdie2|Power Manager Die 2|SoC;hid|PMU TP3w|Power Manager Die 3|SoC;hid|PMU tdie4|Power Manager Die 4|SoC;hid|PMU tdie5|Power Manager Die 5|SoC;hid|PMU tdie6|Power Manager Die 6|SoC;hid|PMU tdie7|Power Manager Die 7|SoC;hid|PMU tdie8|Power Manager Die 8|SoC;hid|eACC MTR Temp Sensor0|Efficiency Cores Package 1|CPU;hid|eACC MTR Temp Sensor3|Efficiency Cores Package 2|CPU;hid|pACC MTR Temp Sensor2|Performance Cores Package 1|CPU;hid|pACC MTR Temp Sensor3|Performance Cores Package 2|CPU;hid|pACC MTR Temp Sensor4|Performance Cores Package 3|CPU;hid|pACC MTR Temp Sensor5|Performance Cores Package 4|CPU;hid|pACC MTR Temp Sensor7|Performance Cores Package 5|CPU;hid|pACC MTR Temp Sensor8|Performance Cores Package 6|CPU;hid|pACC MTR Temp Sensor9|Performance Cores Package 7|CPU;hid|GPU MTR Temp Sensor1|GPU 1|GPU;hid|GPU MTR Temp Sensor4|GPU 2|GPU;hid|ISP MTR Temp Sensor5|Image Signal Processor|SoC;hid|ANE MTR Temp Sensor1|Apple Neural Engine|SoC;hid|SOC MTR Temp Sensor0|Apple M1 SOC 1|SoC;hid|SOC MTR Temp Sensor1|Apple M1 SOC 2|SoC;hid|SOC MTR Temp Sensor2|Apple M1 SOC 3|SoC;hid|PMU tdev5|Precision Time Protocol Manager|SoC;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TIOP|Thunderbolt Proximity|Ports;smc|TT0D|Thunderbolt Port 1|Ports;smc|TT1D|Thunderbolt Port 2|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TCHP|Charger Proximity|Power;hid|PMGR SOC Die Temp Sensor0|Power Manager SOC 1|SoC;hid|PMGR SOC Die Temp Sensor1|Power Manager SOC 2|SoC;hid|PMGR SOC Die Temp Sensor2|Power Manager SOC 3|SoC;hid|PMU tdie1|Power Manager Die 1|SoC;hid|PMU tdie2|Power Manager Die 2|SoC;hid|PMU TP3w|Power Manager Die 3|SoC;hid|PMU tdie4|Power Manager Die 4|SoC;hid|PMU tdie5|Power Manager Die 5|SoC;hid|PMU tdie6|Power Manager Die 6|SoC;hid|PMU tdie7|Power Manager Die 7|SoC;hid|PMU tdie8|Power Manager Die 8|SoC;hid|eACC MTR Temp Sensor0|Efficiency Cores Package 1|CPU;hid|eACC MTR Temp Sensor3|Efficiency Cores Package 2|CPU;hid|pACC MTR Temp Sensor2|Performance Cores Package 1|CPU;hid|pACC MTR Temp Sensor3|Performance Cores Package 2|CPU;hid|pACC MTR Temp Sensor4|Performance Cores Package 3|CPU;hid|pACC MTR Temp Sensor5|Performance Cores Package 4|CPU;hid|pACC MTR Temp Sensor7|Performance Cores Package 5|CPU;hid|pACC MTR Temp Sensor8|Performance Cores Package 6|CPU;hid|pACC MTR Temp Sensor9|Performance Cores Package 7|CPU;hid|GPU MTR Temp Sensor1|GPU 1|GPU;hid|GPU MTR Temp Sensor4|GPU 2|GPU;hid|ISP MTR Temp Sensor5|Image Signal Processor|SoC;hid|ANE MTR Temp Sensor1|Apple Neural Engine|SoC;hid|SOC MTR Temp Sensor0|Apple M1 SOC 1|SoC;hid|SOC MTR Temp Sensor1|Apple M1 SOC 2|SoC;hid|SOC MTR Temp Sensor2|Apple M1 SOC 3|SoC;hid|PMU tdev7|Precision Time Protocol Manager|SoC;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TIOP|Thunderbolt Proximity|Ports;smc|TT0D|Thunderbolt Port 1|Ports;smc|TT1D|Thunderbolt Port 2|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "smc|Tp09|Efficiency Core 1|CPU;smc|Tp0T|Efficiency Core 2|CPU;smc|Tp01|Performance Core 1|CPU;smc|Tp05|Performance Core 2|CPU;smc|Tp0D|Performance Core 3|CPU;smc|Tp0H|Performance Core 4|CPU;smc|Tp0L|Performance Core 5|CPU;smc|Tp0P|Performance Core 6|CPU;smc|Tp0X|Performance Core 7|CPU;smc|Tp0b|Performance Core 8|CPU;smc|Tg05|GPU Cluster 1|GPU;smc|Tg0D|GPU Cluster 2|GPU;smc|Tg0L|GPU Cluster 3|GPU;smc|Tg0T|GPU Cluster 4|GPU;smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TaLP|Airflow Left|Airflow;smc|TaRF|Airflow Right|Airflow;hid|NAND CH0 temp|SSD (NAND I/O)|Storage;smc|TH0a|SSD|Storage;smc|Tm01|Memory Bank 1|Memory;smc|Tm05|Memory Bank 2|Memory;smc|Tm09|Memory Bank 3|Memory;smc|Tm0D|Memory Bank 4|Memory;smc|TCHP|Charger Proximity|Power;smc|TPSP|Power Supply Proximity|Power;smc|TaLT|Left Thunderbolt Ports Proximity|Ports;smc|TaRT|Right Thunderbolt Ports Proximity|Ports;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TW0P|Wireless Proximity|Wireless",
        "smc|TB0T|Battery|Battery;smc|TB1T|Battery Management Unit|Battery;smc|TB2T|Battery Proximity|Battery;hid|gas gauge battery 0|Battery Gas Gauge|Battery;smc|TCHP|Charger Proximity|Power;hid|PMGR SOC Die Temp Sensor0|Power Manager SOC 1|SoC;hid|PMGR SOC Die Temp Sensor1|Power Manager SOC 2|SoC;hid|PMGR SOC Die Temp Sensor2|Power Manager SOC 3|SoC;hid|PMU tdie1|Power Manager Die 1|SoC;hid|PMU tdie2|Power Manager Die 2|SoC;hid|PMU TP3w|Power Manager Die 3|SoC;hid|PMU tdie4|Power Manager Die 4|SoC;hid|PMU tdie5|Power Manager Die 5|SoC;hid|PMU tdie6|Power Manager Die 6|SoC;hid|PMU tdie7|Power Manager Die 7|SoC;hid|PMU tdie8|Power Manager Die 8|SoC;hid|eACC MTR Temp Sensor0|Efficiency Cores Package 1|CPU;hid|eACC MTR Temp Sensor3|Efficiency Cores Package 2|CPU;hid|pACC MTR Temp Sensor2|Performance Cores Package 1|CPU;hid|pACC MTR Temp Sensor3|Performance Cores Package 2|CPU;hid|pACC MTR Temp Sensor4|Performance Cores Package 3|CPU;hid|pACC MTR Temp Sensor5|Performance Cores Package 4|CPU;hid|pACC MTR Temp Sensor7|Performance Cores Package 5|CPU;hid|pACC MTR Temp Sensor8|Performance Cores Package 6|CPU;hid|pACC MTR Temp Sensor9|Performance Cores Package 7|CPU;hid|GPU MTR Temp Sensor1|GPU 1|GPU;hid|GPU MTR Temp Sensor4|GPU 2|GPU;hid|ISP MTR Temp Sensor5|Image Signal Processor|SoC;hid|ANE MTR Temp Sensor1|Apple Neural Engine|SoC;hid|SOC MTR Temp Sensor0|Apple M1 SOC 1|SoC;hid|SOC MTR Temp Sensor1|Apple M1 SOC 2|SoC;hid|SOC MTR Temp Sensor2|Apple M1 SOC 3|SoC;hid|PMU tdev8|Precision Time Protocol Manager|SoC;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|Ts0P|Trackpad|Palm Rest;smc|Ts1P|Trackpad Actuator|Palm Rest;smc|TIOP|Thunderbolt Proximity|Ports;smc|TT0D|Thunderbolt Port 1|Ports;smc|TT1D|Thunderbolt Port 2|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "hid|PMGR SOC Die Temp Sensor0|Power Manager SOC 1|SoC;hid|PMGR SOC Die Temp Sensor1|Power Manager SOC 2|SoC;hid|PMGR SOC Die Temp Sensor2|Power Manager SOC 3|SoC;hid|PMU tdie1|Power Manager Die 1|SoC;hid|PMU tdie2|Power Manager Die 2|SoC;hid|PMU TP3w|Power Manager Die 3|SoC;hid|PMU tdie4|Power Manager Die 4|SoC;hid|PMU tdie5|Power Manager Die 5|SoC;hid|PMU tdie6|Power Manager Die 6|SoC;hid|PMU tdie7|Power Manager Die 7|SoC;hid|PMU tdie8|Power Manager Die 8|SoC;hid|eACC MTR Temp Sensor0|Efficiency Cores Package 1|CPU;hid|eACC MTR Temp Sensor3|Efficiency Cores Package 2|CPU;hid|pACC MTR Temp Sensor2|Performance Cores Package 1|CPU;hid|pACC MTR Temp Sensor3|Performance Cores Package 2|CPU;hid|pACC MTR Temp Sensor4|Performance Cores Package 3|CPU;hid|pACC MTR Temp Sensor5|Performance Cores Package 4|CPU;hid|pACC MTR Temp Sensor7|Performance Cores Package 5|CPU;hid|pACC MTR Temp Sensor8|Performance Cores Package 6|CPU;hid|pACC MTR Temp Sensor9|Performance Cores Package 7|CPU;hid|GPU MTR Temp Sensor1|GPU 1|GPU;hid|GPU MTR Temp Sensor4|GPU 2|GPU;smc|Tb0P|Backlight Controller Proximity|Display;smc|TL0P|LCD Panel 1|Display;smc|TL1P|LCD Panel 2|Display;smc|TL2P|LCD Panel 3|Display;smc|TL3P|LCD Panel 4|Display;smc|TL4P|LCD Panel 5|Display;hid|ISP MTR Temp Sensor5|Image Signal Processor|SoC;hid|ANE MTR Temp Sensor1|Apple Neural Engine|SoC;hid|SOC MTR Temp Sensor0|Apple M1 SOC 1|SoC;hid|SOC MTR Temp Sensor1|Apple M1 SOC 2|SoC;hid|SOC MTR Temp Sensor2|Apple M1 SOC 3|SoC;hid|PMU tdev8|Precision Time Protocol Manager|SoC;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power;smc|TIOP|Thunderbolt Proximity|Ports;smc|TT0D|Thunderbolt Port 1|Ports;smc|TT1D|Thunderbolt Port 2|Ports;smc|TW0P|Wireless Proximity|Wireless",
        "hid|PMGR SOC Die Temp Sensor0|Power Manager SOC 1|SoC;hid|PMGR SOC Die Temp Sensor1|Power Manager SOC 2|SoC;hid|PMGR SOC Die Temp Sensor2|Power Manager SOC 3|SoC;hid|PMU tdie1|Power Manager Die 1|SoC;hid|PMU tdie2|Power Manager Die 2|SoC;hid|PMU TP3w|Power Manager Die 3|SoC;hid|PMU tdie4|Power Manager Die 4|SoC;hid|PMU tdie5|Power Manager Die 5|SoC;hid|PMU tdie6|Power Manager Die 6|SoC;hid|PMU tdie7|Power Manager Die 7|SoC;hid|PMU tdie8|Power Manager Die 8|SoC;hid|eACC MTR Temp Sensor0|Efficiency Cores Package 1|CPU;hid|eACC MTR Temp Sensor3|Efficiency Cores Package 2|CPU;hid|pACC MTR Temp Sensor2|Performance Cores Package 1|CPU;hid|pACC MTR Temp Sensor3|Performance Cores Package 2|CPU;hid|pACC MTR Temp Sensor4|Performance Cores Package 3|CPU;hid|pACC MTR Temp Sensor5|Performance Cores Package 4|CPU;hid|pACC MTR Temp Sensor7|Performance Cores Package 5|CPU;hid|pACC MTR Temp Sensor8|Performance Cores Package 6|CPU;hid|pACC MTR Temp Sensor9|Performance Cores Package 7|CPU;hid|GPU MTR Temp Sensor1|GPU 1|GPU;hid|GPU MTR Temp Sensor4|GPU 2|GPU;smc|Tb0P|Backlight Controller Proximity|Display;smc|TL0P|LCD Panel 1|Display;smc|TL1P|LCD Panel 2|Display;smc|TL2P|LCD Panel 3|Display;smc|TL3P|LCD Panel 4|Display;smc|TL4P|LCD Panel 5|Display;hid|ISP MTR Temp Sensor5|Image Signal Processor|SoC;hid|ANE MTR Temp Sensor1|Apple Neural Engine|SoC;hid|SOC MTR Temp Sensor0|Apple M1 SOC 1|SoC;hid|SOC MTR Temp Sensor1|Apple M1 SOC 2|SoC;hid|SOC MTR Temp Sensor2|Apple M1 SOC 3|SoC;hid|PMU tdev8|Precision Time Protocol Manager|SoC;hid|NAND CH0 temp|SSD (I/O Channel)|Storage;smc|TH0B|SSD|Storage;smc|TPSD|Power Supply|Power;smc|TPSP|Power Supply Proximity|Power",
    ]
    public static func descriptors(keys: [String], model: String = model, topology: [String: Int] = topology) -> [String: FanSensorDescriptor] {
        var catalog: [String: (String, String)] = [:]
        if let index = modelTables[model] {
            for row in tables[index].split(separator: ";") {
                let parts = row.split(separator: "|").map(String.init)
                if parts.count == 4 { catalog[(parts[0] == "hid" ? "HID:" : "") + parts[1]] = (parts[2], parts[3]) }
            }
        }
        var counts: [String: Int] = [:], result: [String: FanSensorDescriptor] = [:]
        for key in Set(keys).sorted() {
            let hid = key.hasPrefix("HID:")
            let raw = hid ? String(key.dropFirst(4)).components(separatedBy: ":")[0] : key
            var label = raw, area = "Other"
            if let exact = catalog[hid ? "HID:" + raw : raw] { (label, area) = exact }
            else if hid {
                if raw.hasPrefix("PMU tdie") { label = raw; area = "SoC" }
                if raw == "NAND CH0 temp" { label = "SSD (NAND I/O)"; area = "Storage" }
                if raw == "gas gauge battery" { label = "Battery Gas Gauge"; area = "Battery" }
            } else if catalog.isEmpty {
                let fixed: [String: (String, String)] = ["TB0T": ("Battery", "Battery"), "TB1T": ("Battery Management Unit", "Battery"), "TB2T": ("Battery Proximity", "Battery"), "TCHP": ("Charger Proximity", "Power"), "TPSP": ("Power Supply Proximity", "Power"), "TPSD": ("Power Supply", "Power"), "TW0P": ("Wireless Proximity", "Wireless"), "TaLT": ("Left Thunderbolt Ports", "Ports"), "TaRT": ("Right Thunderbolt Ports", "Ports"), "Ts0P": ("Trackpad", "Palm Rest"), "Tb0P": ("Backlight Controller", "Display"), "TMVR": ("Memory Voltage Regulator", "Memory")]
                if let known = fixed[raw] { (label, area) = known }
                else {
                    let superCount = topology["Super", default: 0]
                    var family = "", limit = 0, candidate = "Other"
                    if raw.hasPrefix("Te") || raw.hasPrefix("ftE") || raw.hasPrefix("sd") { family = "Efficiency CPU sensor"; limit = topology["Efficiency", default: 0]; candidate = "CPU" }
                    else if raw.hasPrefix("Tp") { family = "CPU sensor"; limit = superCount > 0 ? superCount : topology.values.reduce(0,+); candidate = "CPU" }
                    else if raw.hasPrefix("ftP") || (raw.hasPrefix("Tm") && superCount > 0) { family = "Performance CPU sensor"; limit = topology["Performance", default: 0]; candidate = "CPU" }
                    else if raw.hasPrefix("Tm") { family = "Memory sensor"; limit = 16; candidate = "Memory" }
                    else if raw.hasPrefix("Tg") || raw.hasPrefix("ftG") { family = "GPU sensor"; limit = 16; candidate = "GPU" }
                    else if raw.range(of: "^TG[0-9A-Fa-f][DPHTdpht]$", options: .regularExpression) != nil { family = "GPU sensor"; limit = 16; candidate = "GPU" }
                    else if raw == "TH0a" { family = "SSD"; limit = 1; candidate = "Storage" }
                    #if arch(x86_64)
                    if raw.range(of: "^TC[0-9A-Fa-f][CDPHFcdphf]$", options: .regularExpression) != nil || ["TCXC", "TCSA"].contains(raw) { family = "CPU sensor"; limit = 32; candidate = "CPU" }
                    #endif
                    counts[family, default: 0] += 1
                    if !family.isEmpty && counts[family, default: 0] <= limit { label = family + " · " + raw; area = candidate }
                }
            }
            result[key] = FanSensorDescriptor(id: key, source: hid ? "HID" : "SMC", rawKey: raw, displayName: label, area: area, curated: area != "Other")
        }
        return result
    }
    public static func mergeHID(_ samples: [(product: String, location: String?, value: Double)]) -> [String: Double] {
        var result: [String: Double] = [:]
        for sample in samples where valid(sample.value) && !sample.product.isEmpty {
            guard !sample.product.hasPrefix("PMU tdev"), sample.product != "PMU tcal" else { continue }
            // Preserve the old product/location rule identity while the registry merges logical display sensors.
            let key = "HID:\(sample.product):\(sample.location ?? "unknown")"
            result[key] = max(result[key] ?? sample.value, sample.value)
        }
        return result
    }
    public static func group(_ key: String) -> String { descriptors(keys: [key])[key]?.area ?? "Other" }
    public static func name(_ key: String) -> String {
        if ["CPU", "Highest CPU", "Average CPU", "GPU", "Highest GPU", "Average GPU", "Maximum", "Highest Computer", "Average Computer"].contains(key) { return key }
        let d = descriptors(keys: [key])[key]!
        return "\(d.area) · \(d.displayName) · \(key)"
    }
}

/// Descriptor lifetime is independent of the latest successful sample. Never retains values.
public struct FanSensorRegistry: Sendable {
    public private(set) var descriptors: [String: FanSensorDescriptor] = [:]
    public init() {}
    public mutating func discover(keys: [String]) {
        let incoming = FanSensorMetadata.descriptors(keys: Array(Set(descriptors.keys).union(keys)))
        for (key, descriptor) in incoming { descriptors[key] = descriptor }
    }
    public mutating func update(_ snapshot: inout FanSnapshot) {
        let incoming = FanSensorMetadata.descriptors(keys: Array(Set(descriptors.keys).union(snapshot.temperatures.keys)))
        for (key, descriptor) in incoming where descriptors[key] == nil { descriptors[key] = descriptor }
        snapshot.descriptors = descriptors
    }
}

/// Immutable demand passed from the main actor to the serial hardware owner.
/// Rejects samples dispatched before a control configuration change, including A → B → A.
public struct FanControlSampleVersion: Sendable {
    public private(set) var generation: UInt64 = 0
    private var settings = FanSettings()
    public init() {}
    @discardableResult public mutating func update(_ settings: FanSettings) -> Bool {
        guard self.settings != settings else { return false }
        self.settings = settings; generation &+= 1
        return true
    }
    public func accepts(_ generation: UInt64) -> Bool { self.generation == generation }
}

public struct FanReadPlan: Equatable, Sendable {
    public static let aggregates = ["CPU", "Highest CPU", "Average CPU", "GPU", "Highest GPU", "Average GPU", "Maximum", "Highest Computer", "Average Computer"]
    public var sensors: Set<String>
    public var areas: Set<String>
    public var monitoring: Bool
    public init(settings: FanSettings, monitoring: Bool, areas: Set<String> = []) {
        sensors = settings.enabled ? Set(settings.rules.filter(\.enabled).map(\.sensor)) : []
        self.monitoring = monitoring; self.areas = monitoring ? areas : []
    }
    public var needsSample: Bool { monitoring || !sensors.isEmpty }
    public func includes(_ descriptor: FanSensorDescriptor) -> Bool {
        if areas.contains(descriptor.area) || sensors.contains(descriptor.id) { return true }
        guard descriptor.curated else { return false }
        if areas.contains("Aggregates") { return true }
        if !sensors.isDisjoint(with: ["Maximum", "Highest Computer", "Average Computer"]) { return true }
        if descriptor.area == "CPU", !sensors.isDisjoint(with: ["CPU", "Highest CPU", "Average CPU"]) { return true }
        if descriptor.area == "GPU", !sensors.isDisjoint(with: ["GPU", "Highest GPU", "Average GPU"]) { return true }
        return false
    }
    public func keys(in descriptors: [String: FanSensorDescriptor]) -> [String] {
        descriptors.values.filter { includes($0) }.map(\.id).sorted()
    }
}

public struct FanReading: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String? = nil
    public var current: Double
    public var minimum: Double
    public var maximum: Double
    public var target: Double?
    public var manual: Bool?
    public func rpm(percent: Double) -> Double { minimum + percent / 100 * (maximum - minimum) }
}
public struct FanSnapshot: Codable, Sendable {
    public var fans: [FanReading]
    public var temperatures: [String: Double]
    public var descriptors: [String: FanSensorDescriptor] = [:]
    public var message: String
    public var controlEnabled: Bool = false
    public var acceptedDemands: [Int: Double] = [:]
    public var controlStatus: String = "Awaiting authenticated helper"
    public init(fans: [FanReading] = [], temperatures: [String: Double] = [:], message: String = "") {
        self.fans = fans; self.temperatures = temperatures; self.message = message
        self.descriptors = FanSensorMetadata.descriptors(keys: Array(temperatures.keys))
    }
    public var highestCPU: (key: String, value: Double)? {
        temperatures.filter { descriptors[$0.key]?.area == "CPU" && descriptors[$0.key]?.curated == true && FanSensorMetadata.valid($0.value) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first.map { ($0.key, $0.value) }
    }
    public var ruleReadings: [String: Double] {
        var result = temperatures.filter { FanSensorMetadata.valid($0.value) }
        func values(_ area: String?) -> [Double] {
            var logical: [String: Double] = [:]
            for (key, value) in result {
                guard let d = descriptors[key], d.curated, area == nil || d.area == area else { continue }
                let identity = d.source + ":" + d.rawKey
                logical[identity] = max(logical[identity] ?? value, value)
            }
            return Array(logical.values)
        }
        for (area, highest, average) in [("CPU", "Highest CPU", "Average CPU"), ("GPU", "Highest GPU", "Average GPU"), ("", "Highest Computer", "Average Computer")] {
            let readings = values(area.isEmpty ? nil : area)
            result[highest] = readings.max()
            result[average] = readings.isEmpty ? nil : readings.reduce(0,+) / Double(readings.count)
        }
        result["CPU"] = result["Highest CPU"]
        result["GPU"] = result["Highest GPU"]
        result["Maximum"] = result["Highest Computer"]
        return result
    }
}
public enum SMCMonitor {
    public static func snapshot(io: SMCIO, temperatureKeys: [String]) throws -> FanSnapshot {
        guard let count = try io.read("FNum").number, count >= 0, count <= 8 else { throw SMCError.invalid("fan count") }
        var fans: [FanReading] = []
        for id in 0..<Int(count) {
            guard let current = try io.read("F\(id)Ac").number,
                  let minimum = try io.read("F\(id)Mn").number,
                  let maximum = try io.read("F\(id)Mx").number,
                  current.isFinite, minimum >= 0, maximum > minimum, maximum <= 30000 else { throw SMCError.invalid("fan limits") }
            let name = (try? io.read("F\(id)ID")).flatMap { value -> String? in
                let bytes = Array(value.bytes.dropFirst(4).prefix { $0 != 0 })
                return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            fans.append(FanReading(id: id, name: name?.isEmpty == false ? name : nil, current: current, minimum: minimum, maximum: maximum,
                target: try? io.read("F\(id)Tg").number, manual: (try? FanModeDiscovery.key(io: io, fan: id)).flatMap { try? io.read($0).number }.flatMap { $0 == 0 ? false : $0 == 1 ? true : nil }))
        }
        var temperatures: [String: Double] = [:]
        for key in Set(temperatureKeys).sorted() where FanSensorMetadata.eligible(key) {
            if let value = try? io.read(key), let number = FanSensorMetadata.temperature(value) { temperatures[key] = number }
        }
        return FanSnapshot(fans: fans, temperatures: temperatures, message: "Live AppleSMC readings; unsupported keys omitted.")
    }
}

/// Helper-owned reducer. Requests cannot specify keys, raw bytes, RPM, or lease duration.
public final class LeasedFanController {
    private let io: SMCIO
    private let sleep: (TimeInterval) -> Void
    private var deadlines: [Int: TimeInterval] = [:]
    private var knownFans = Set<Int>()
    private var suspended = false
    private var ownsUnlock = false
    private var selectedModes: [Int: String] = [:]
    private let clock: () -> TimeInterval
    // At most two seconds of retry sleeps per control/recovery phase. A failed
    // control enters recovery once, keeping total retry blocking below the five-second lease.
    private var operationStarted: TimeInterval = 0
    private var retryBudget: TimeInterval = 2
    private func beginOperation() { operationStarted = clock(); retryBudget = 2 }
    private func pause(_ delay: TimeInterval) -> Bool {
        guard retryBudget >= delay, clock() - operationStarted < 2.2 else { return false }
        retryBudget -= delay; sleep(delay); return true
    }
    private func unlock() throws {
        guard let provider = io as? SMCMetadataIO,
              let info = try? provider.metadata("Ftst"), info.type == "ui8 ", info.size == 1, info.isWritable else { return }
        let current = try io.read("Ftst")
        guard current.type == "ui8 ", current.bytes.count == 1, [0, 1].contains(current.bytes[0]) else { throw SMCError.invalid("Ftst") }
        if current.bytes[0] == 0 { ownsUnlock = true }
        try io.write("Ftst", value: SMCValue(type: "ui8 ", bytes: [1]))
    }
    private func clearUnlock() throws {
        guard knownFans.isEmpty, ownsUnlock else { return }
        try io.write("Ftst", value: SMCValue(type: "ui8 ", bytes: [0]))
        guard try io.read("Ftst") == SMCValue(type: "ui8 ", bytes: [0]) else { throw SMCError.operation("Ftst automatic restoration failed; retry pending") }
        ownsUnlock = false
    }
    public func prepareForSleep() throws { suspended = true; try restore() }
    public func resumeAfterSleep() throws { try restore(); suspended = false }
    public init(io: SMCIO, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.io = io; self.sleep = sleep; self.clock = clock
    }
    private func fans() throws -> [FanReading] { try SMCMonitor.snapshot(io: io, temperatureKeys: []).fans }
    private func mode(_ id: Int, manual: Bool) throws {
        let key = try selectedModes[id] ?? FanModeDiscovery.key(io: io, fan: id)
        selectedModes[id] = key
        let attempts = manual ? 8 : 5
        var failure: Error = SMCError.operation("mode unreadable")
        for attempt in 0..<attempts {
            if attempt > 0, !pause(manual ? 0.25 : 0.2) { break }
            do {
                if manual { try unlock() }
                try io.write(key, value: SMCValue(type: "ui8 ", bytes: [manual ? 1 : 0]))
                let value = try io.read(key)
                guard value == SMCValue(type: "ui8 ", bytes: [manual ? 1 : 0]) else {
                    throw SMCError.operation("expected \(manual ? 1 : 0), readback=\(value.number.map { String($0) } ?? "unreadable"), encoding=\(value.type)")
                }
                return
            } catch { failure = error }
        }
        throw SMCError.operation("Fan \(id) \(key) mode=\(manual ? "manual" : "automatic") 验证失败（verification failed）: \(failure.localizedDescription)")
    }
    public func restore() throws {
        beginOperation()
        var failure: Error?
        do { knownFans.formUnion(try fans().map(\.id)) } catch { failure = error }
        for id in knownFans {
            do { try mode(id, manual: false); deadlines[id] = nil; knownFans.remove(id) }
            catch { failure = error }
        }
        if failure == nil { do { try clearUnlock() } catch { failure = error } }
        if let failure { throw failure }
    }
    public func expire(now: TimeInterval) throws {
        beginOperation()
        var failure: Error?
        for (id, deadline) in deadlines where now >= deadline {
            do { try mode(id, manual: false); deadlines[id] = nil; knownFans.remove(id) }
            catch { failure = error }
        }
        if failure == nil { do { try clearUnlock() } catch { failure = error } }
        if let failure { throw failure }
    }
    /// Replaces the entire session demand on the helper's serial hardware queue.
    public func apply(demands: [Int: Double], now: TimeInterval) throws {
        beginOperation()
        do {
            let detected = Set(try fans().map(\.id))
            guard !suspended, demands.allSatisfy({ detected.contains($0.key) && $0.value.isFinite && (0...100).contains($0.value) }) else { throw SMCError.invalid("fan batch") }
            for id in knownFans.subtracting(demands.keys) {
                try mode(id, manual: false); deadlines[id] = nil; knownFans.remove(id)
            }
            try clearUnlock()
            for (id, percent) in demands { try setValue(fan: id, percent: percent, now: now) }
        } catch { throw restoring(after: error) }
    }
    public func set(fan: Int, percent: Double, now: TimeInterval) throws {
        beginOperation()
        do { try setValue(fan: fan, percent: percent, now: now) }
        catch { throw restoring(after: error) }
    }
    private func setValue(fan: Int, percent: Double, now: TimeInterval) throws {
        guard !suspended, percent.isFinite, (0...100).contains(percent), let live = try fans().first(where: { $0.id == fan }) else { throw SMCError.invalid("fan request") }
        // Unknown mode layouts (including shared FS! masks) fail closed.
        selectedModes[fan] = try FanModeDiscovery.key(io: io, fan: fan)
        let key = "F\(fan)Tg", target = try io.read(key)
        guard ["fpe2", "flt "].contains(target.type) else { throw SMCError.invalid("target encoding") }
        let requested = live.rpm(percent: percent)
        let rpm = min(live.maximum, max(live.minimum, requested.rounded()))
        let encoded = try SMCValue.encode(rpm, type: target.type)
        guard let expected = encoded.number else { throw SMCError.invalid("target encoding") }
        knownFans.insert(fan)
        do {
            try mode(fan, manual: true)
            var lastFailure: Error = SMCError.operation("target not verified")
            for attempt in 0..<3 {
                if attempt > 0, !pause(0.1) { break }
                do {
                    try io.write(key, value: encoded)
                    let readback = try io.read(key)
                    guard readback.type == encoded.type, let actual = readback.number, abs(actual - expected) <= 2 else {
                        throw SMCError.operation("readback=\(readback.number.map { String($0) } ?? "unreadable"), encoding=\(readback.type)")
                    }
                    deadlines[fan] = now + max(0, clock() - operationStarted) + 5
                    return
                } catch { lastFailure = error }
            }
            throw SMCError.operation("Fan \(fan) \(key) requested=\(requested) RPM expected=\(expected) RPM encoding=\(encoded.type) mode=manual; target verification failed after 3 attempts: \(lastFailure.localizedDescription)")
        } catch { throw error }
    }
    private func restoring(after error: Error) -> Error {
        do { try restore(); return error }
        catch let restoration {
            return SMCError.operation("\(error.localizedDescription); 自动模式恢复失败，将重试（automatic restoration failed; retry pending）: \(restoration.localizedDescription)")
        }
    }
}

@objc public protocol FanHelperProtocol {
    func status(reply: @escaping (String) -> Void)
    func applyDemands(_ demands: [String: Double], reply: @escaping (String) -> Void)
    func setDemand(fan: Int, percent: Double, reply: @escaping (String) -> Void)
    func restore(reply: @escaping (String) -> Void)
}
public enum FanHelperIdentity {
    public static let libraryRequirement = "identifier \"local.clearain.MacTools.FanHelper.Core\" and certificate leaf = H\"85B37EA8D5B9719CB5F443613573AD1F4986B17B\""
    public static let service = "local.clearain.MacTools.FanHelper"
    public static let clientRequirement = "identifier \"local.clearain.MacTools\" and certificate leaf = H\"85B37EA8D5B9719CB5F443613573AD1F4986B17B\""
    public static let helperRequirement = "identifier \"local.clearain.MacTools.FanHelper\" and certificate leaf = H\"85B37EA8D5B9719CB5F443613573AD1F4986B17B\""
}

/// Pure update policy: disk identity and the authenticated running protocol must both match.
public enum FanHelperUpdatePolicy {
    public static let protocolStatus = "ready-v2"
    public static func needsUpdate(installedHash: String?, bundledHash: String?, runningStatus: String? = nil) -> Bool {
        guard let installedHash, let bundledHash else { return true }
        if installedHash != bundledHash { return true }
        guard let runningStatus else { return false }
        // Unavailable hardware is distinct from an incompatible wire protocol.
        return runningStatus != protocolStatus && !runningStatus.hasPrefix("unavailable-v2:")
    }
}
