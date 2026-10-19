import Foundation
import AppKit
import Security
import IOKit
import IOKit.pwr_mgt
import MacToolsCore
import os

private let logger = Logger(subsystem: FanHelperIdentity.service, category: "hardware")

// Hardware failures remain inspectable over authenticated XPC. Only a complete
// initialization and initial automatic-mode restoration can enable control.
final class HardwareState {
    var controller: LeasedFanController?
    var failure: String?
    var powerAvailable = false
    var ready: Bool { controller != nil && failure == nil && powerAvailable }
    func initialize() {
        do {
            if controller == nil { controller = LeasedFanController(io: try AppleSMC()) }
            try restore()
            logger.info("Initial automatic-mode restoration succeeded")
        } catch { record("Initialization/automatic-mode restoration", error) }
    }
    func record(_ operation: String, _ error: Error) {
        failure = "\(operation): \(error.localizedDescription)"
        logger.error("\(self.failure!, privacy: .public)")
    }
    func restore() throws {
        guard let controller else { throw SMCError.unavailable }
        do { try controller.restore(); failure = nil }
        catch { record("Automatic-mode restoration", error); throw error }
    }
    var status: String { ready ? "ready-v2" : "unavailable-v2: \(failure ?? (powerAvailable ? "Hardware not initialized" : "System power observation unavailable"))" }
}

// No raw-key API. XPC bounds all requests to one finite percentage and one enumerated fan.
final class Service: NSObject, FanHelperProtocol {
    var enabled = true // queue confined
    private let admission = NSLock()
    private var lastRequest: [Int: TimeInterval] = [:]
    let hardware: HardwareState
    let queue: DispatchQueue
    init(hardware: HardwareState, queue: DispatchQueue) { self.hardware = hardware; self.queue = queue }
    func status(reply: @escaping (String) -> Void) { queue.async { reply(self.hardware.status) } }
    func applyDemands(_ demands: [String: Double], reply: @escaping (String) -> Void) {
        guard demands.count <= 8 else { reply("error: invalid batch"); return }
        var parsed: [Int: Double] = [:]
        for (key, value) in demands {
            guard let id = Int(key), String(id) == key, (0..<8).contains(id), value.isFinite, (0...100).contains(value) else { reply("error: invalid batch"); return }
            parsed[id] = value
        }
        let batch = parsed
        queue.async {
            guard self.enabled, self.hardware.ready, let controller = self.hardware.controller else { reply("error: unavailable"); return }
            do { try controller.apply(demands: batch, now: ProcessInfo.processInfo.systemUptime); reply("ok") }
            catch { self.hardware.record("Fan batch", error); try? self.hardware.restore(); reply("error: \(error.localizedDescription)") }
        }
    }
    func setDemand(fan: Int, percent: Double, reply: @escaping (String) -> Void) {
        guard fan >= 0, fan < 8, percent.isFinite, (0...100).contains(percent) else { reply("error: invalid request"); return }
        admission.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let allowed = now - (lastRequest[fan] ?? -100) >= 0.25
        if allowed { lastRequest[fan] = now }
        admission.unlock()
        guard allowed else { reply("error: rate limit"); return }
        queue.async {
            guard self.enabled else { reply("error: disconnected"); return }
            guard self.hardware.ready, let controller = self.hardware.controller else { reply("error: \(self.hardware.status)"); return }
            do {
                try controller.set(fan: fan, percent: percent, now: ProcessInfo.processInfo.systemUptime)
                reply("ok")
            } catch { self.hardware.record("Fan demand", error); try? self.hardware.restore(); reply("error: \(error.localizedDescription)") }
        }
    }
    func restore(reply: @escaping (String) -> Void) {
        queue.async { do { try self.hardware.restore(); reply("ok") } catch { reply("error: \(error.localizedDescription)") } }
    }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "fan-helper.hardware")
    let hardware: HardwareState
    var active: NSXPCConnection?
    init(hardware: HardwareState) { self.hardware = hardware }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // A single authenticated session owns all leases. Reconnect never inherits manual state.
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(FanHelperIdentity.clientRequirement)
        let accepted = queue.sync { () -> Bool in
            guard active == nil else { return false }
            if hardware.ready { do { try hardware.restore() } catch { /* Status remains available. */ } }
            active = connection; return true
        }
        guard accepted else { return false }
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        let service = Service(hardware: hardware, queue: queue)
        connection.exportedObject = service
        let disconnected = { [weak self, weak connection] in
            guard let self else { return }
            self.queue.async {
                guard self.active === connection else { return }
                service.enabled = false
                try? self.hardware.restore(); self.active = nil
            }
        }
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume(); return true
    }
}

final class PowerObserver {
    let hardware: HardwareState
    let controller: LeasedFanController
    let queue: DispatchQueue
    var root: io_connect_t = 0
    var port: IONotificationPortRef?
    var notifier: io_object_t = 0
    init(hardware: HardwareState, controller: LeasedFanController, queue: DispatchQueue) { self.hardware = hardware; self.controller = controller; self.queue = queue }
    func start() throws {
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let owner = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            // Constants from IOKit/IOMessage.h: iokit_common_msg(0x280/0x300).
            if message == UInt32(0xe0000280) {
                owner.queue.sync {
                    do { try owner.controller.prepareForSleep() }
                    catch { owner.hardware.record("Sleep restoration", error) }
                }
            } else if message == UInt32(0xe0000300) {
                owner.queue.sync {
                    do { try owner.controller.resumeAfterSleep(); owner.hardware.failure = nil }
                    catch { owner.hardware.record("Wake restoration", error) }
                }
            }
            if message == UInt32(0xe0000270) || message == UInt32(0xe0000280) {
                IOAllowPowerChange(owner.root, Int(bitPattern: argument))
            }
        }, &notifier)
        guard root != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else { throw SMCError.unavailable }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if root != 0 { IOServiceClose(root) }
        if let port { IONotificationPortDestroy(port) }
    }
}

// Management runs only from the verified, root-private staged executable. Destinations and
// launch arguments are fixed; no caller-provided commands or paths are accepted.
struct HelperManagement {
    static let directory = "/Library/PrivilegedHelperTools/TSMacToolsFanHelper"
    static let executable = directory + "/TSMacToolsFanHelper"
    static let plist = "/Library/LaunchDaemons/local.clearain.MacTools.FanHelper.plist"
    static func fail(_ text: String) throws { throw NSError(domain: "FanHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func safe(_ path: String, directory: Bool? = nil, optional: Bool = false) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if optional && errno == ENOENT { return }
            try fail("Cannot inspect \(path)")
        }
        guard info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT != S_IFLNK else { try fail("Unsafe ownership, permissions or symlink: \(path)"); return }
        if let directory {
            guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { try fail("Unexpected file type: \(path)"); return }
        }
    }
    static func verify(_ path: String) throws {
        try safe(path, directory: false)
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(FanHelperIdentity.helperRequirement as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            try fail("Helper signature does not match the pinned certificate and identifier."); return
        }
    }
    @discardableResult static func launch(_ args: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { try fail("launchctl \(args.first ?? "") failed (\(process.terminationStatus)). Check the service status and retry.") }
        return process.terminationStatus
    }
    static func run(_ operation: String) throws {
        guard ["install", "reinstall", "uninstall"].contains(operation) else { try fail("Unknown operation"); return }
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try safe(source.deletingLastPathComponent().path, directory: true)
        try verify(source.path)
        for path in ["/Library", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] { try safe(path, directory: true) }
        try safe(directory, directory: true, optional: true)
        try safe(executable, directory: false, optional: true)
        try safe(plist, directory: false, optional: true)
        let exists = FileManager.default.fileExists(atPath: executable)
        let loaded = try launch(["print", "system/" + FanHelperIdentity.service], allowFailure: true) == 0
        if operation == "install" && (exists || loaded) { try fail("Helper already exists. Use Reinstall.") }
        if exists || loaded {
            // Confirm restoration before removing anything. Repeat after the old process
            // exits, so an in-flight demand cannot survive replacement.
            let io = try AppleSMC()
            _ = try SMCMonitor.snapshot(io: io, temperatureKeys: [])
            let controller = LeasedFanController(io: io)
            try controller.restore()
            if loaded { try launch(["bootout", "system/" + FanHelperIdentity.service]) }
            _ = try SMCMonitor.snapshot(io: io, temperatureKeys: [])
            try controller.restore()
        }
        if operation == "uninstall" {
            if FileManager.default.fileExists(atPath: plist) { try FileManager.default.removeItem(atPath: plist) }
            if exists { try FileManager.default.removeItem(atPath: executable) }
            if FileManager.default.fileExists(atPath: directory) {
                // Never recursively remove unknown files.
                guard try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty else { try fail("Helper removed; unexpected files remain in its directory."); return }
                try FileManager.default.removeItem(atPath: directory)
            }
            return
        }
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        }
        let staged = directory + "/.replacement"
        try safe(staged, directory: false, optional: true)
        if FileManager.default.fileExists(atPath: staged) { try FileManager.default.removeItem(atPath: staged) }
        try FileManager.default.copyItem(atPath: source.path, toPath: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: staged)
        try verify(staged)
        guard rename(staged, executable) == 0 else { try fail("Cannot publish verified helper"); return }
        let daemon: [String: Any] = ["Label": FanHelperIdentity.service, "ProgramArguments": [executable], "MachServices": [FanHelperIdentity.service: true], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5, "ExitTimeOut": 20, "ProcessType": "Interactive"]
        let data = try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plist), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: plist)
        try safe(plist, directory: false); try verify(executable)
        try launch(["bootstrap", "system", plist])
    }
}

guard geteuid() == 0 else { fatalError("Fan helper must be launched by its root LaunchDaemon.") }
do {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--manage" {
        try HelperManagement.run(CommandLine.arguments[2]); exit(0)
    }
    guard CommandLine.arguments.count == 1 else { throw NSError(domain: "FanHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid arguments"]) }
    let hardware = HardwareState()
    hardware.initialize()
    let delegate = Delegate(hardware: hardware)
    let listener = NSXPCListener(machServiceName: FanHelperIdentity.service)
    listener.delegate = delegate
    let timer = DispatchSource.makeTimerSource(queue: delegate.queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler {
        guard let controller = hardware.controller else { return }
        do { try controller.expire(now: ProcessInfo.processInfo.systemUptime) }
        catch { hardware.record("Lease expiry", error); try? hardware.restore() }
    }
    timer.resume()
    var power: PowerObserver?
    if let controller = hardware.controller {
        let observer = PowerObserver(hardware: hardware, controller: controller, queue: delegate.queue)
        do { try observer.start(); power = observer; hardware.powerAvailable = true }
        catch { hardware.record("System power observation", error) }
    }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: delegate.queue)
    termination.setEventHandler { try? hardware.restore(); exit(0) }; termination.resume()
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: delegate.queue)
    interrupt.setEventHandler { try? hardware.restore(); exit(0) }; interrupt.resume()
    listener.resume()
    withExtendedLifetime((timer, power, termination, interrupt, delegate)) { RunLoop.main.run() }
} catch { logger.fault("Fan helper fatal error: \(error.localizedDescription, privacy: .public)"); fputs("Fan helper unavailable: \(error)\n", stderr); exit(1) }
