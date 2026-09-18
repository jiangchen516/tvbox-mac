import Foundation

public struct AndroidRuntimeToolchain: Sendable, Equatable {
    public let sdkRoot: URL
    public let adb: URL
    public let emulator: URL
    public let avdManager: URL?

    public init(sdkRoot: URL) {
        self.sdkRoot = sdkRoot
        self.adb = sdkRoot.appendingPathComponent("platform-tools/adb")
        self.emulator = sdkRoot.appendingPathComponent("emulator/emulator")
        let latest = sdkRoot.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
        self.avdManager = FileManager.default.isExecutableFile(atPath: latest.path) ? latest : nil
    }

    public var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: adb.path)
            && FileManager.default.isExecutableFile(atPath: emulator.path)
    }
}

public enum AndroidRuntimeControllerError: LocalizedError, Sendable {
    case unavailableToolchain
    case bridgeAPKMissing
    case commandFailed(String)
    case bootTimeout
    case bridgeHealthTimeout

    public var errorDescription: String? {
        switch self {
        case .unavailableToolchain: return "Android SDK 缺少 adb 或 emulator"
        case .bridgeAPKMissing: return "应用包内缺少已签名 Android Dex Bridge APK"
        case .commandFailed(let message): return "Android Runtime 命令失败: \(message)"
        case .bootTimeout: return "Android Emulator 启动超时"
        case .bridgeHealthTimeout: return "Android Dex Bridge health 检查超时"
        }
    }
}

public actor ManagedAndroidRuntimeController {
    public let toolchain: AndroidRuntimeToolchain
    public let avdName: String
    public let consolePort: Int
    public let hostBridgePort: Int
    public let guestBridgePort: Int
    private let avdHome: URL
    private let userHome: URL
    private var emulatorProcess: Process?

    public init(
        sdkRoot: URL,
        avdName: String,
        consolePort: Int = 5556,
        hostBridgePort: Int = 19_978,
        guestBridgePort: Int = 9_978,
        avdHome: URL,
        userHome: URL
    ) {
        self.toolchain = AndroidRuntimeToolchain(sdkRoot: sdkRoot)
        self.avdName = avdName
        self.consolePort = consolePort
        self.hostBridgePort = hostBridgePort
        self.guestBridgePort = guestBridgePort
        self.avdHome = avdHome
        self.userHome = userHome
    }

    public func start(bridgeAPK: URL) async throws {
        guard toolchain.isUsable else { throw AndroidRuntimeControllerError.unavailableToolchain }
        guard FileManager.default.isReadableFile(atPath: bridgeAPK.path) else {
            throw AndroidRuntimeControllerError.bridgeAPKMissing
        }
        if emulatorProcess == nil || emulatorProcess?.isRunning != true {
            try launchEmulator()
        }
        try await waitForBoot()
        try runADB(["install", "-r", bridgeAPK.path], timeout: 120)
        _ = try? runADB([
            "shell", "setprop",
            "debug.wm.disable_deprecated_target_sdk_dialog", "true"
        ], timeout: 8)
        try runADB(["shell", "am", "start", "-n", "com.okvideomac.dexbridge/.BridgeActivity"])
        try runADB(["forward", "tcp:\(hostBridgePort)", "tcp:\(guestBridgePort)"])
        try await waitForBridgeHealth()
    }

    public func stop() {
        if let process = emulatorProcess, process.isRunning {
            process.terminate()
        }
        emulatorProcess = nil
    }

    private func launchEmulator() throws {
        try FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = toolchain.emulator
        process.arguments = [
            "-avd", avdName,
            "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
            "-gpu", "swiftshader_indirect", "-port", String(consolePort)
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_AVD_HOME"] = avdHome.path
        environment["ANDROID_USER_HOME"] = userHome.path
        environment["ANDROID_EMULATOR_HOME"] = userHome.path
        environment["ANDROID_HOME"] = toolchain.sdkRoot.path
        environment["ANDROID_SDK_ROOT"] = toolchain.sdkRoot.path
        environment["PATH"] = [
            toolchain.sdkRoot.appendingPathComponent("platform-tools").path,
            toolchain.sdkRoot.appendingPathComponent("emulator").path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ].joined(separator: ":")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AndroidRuntimeControllerError.commandFailed(error.localizedDescription)
        }
        emulatorProcess = process
    }

    private func waitForBoot() async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            if (try? runADB(["get-state"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)) == "device",
               (try? runADB(["shell", "getprop", "sys.boot_completed"], timeout: 5)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == "1",
               (try? runADB(["shell", "cmd", "package", "list", "packages"], timeout: 15)) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw AndroidRuntimeControllerError.bootTimeout
    }

    private func waitForBridgeHealth() async throws {
        let url = URL(string: "http://127.0.0.1:\(hostBridgePort)/health")!
        for _ in 0..<30 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               String(data: data, encoding: .utf8)?.contains("\"ok\":true") == true {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AndroidRuntimeControllerError.bridgeHealthTimeout
    }

    private func runADB(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = toolchain.adb
        process.arguments = ["-s", "emulator-\(consolePort)"] + arguments
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = toolchain.sdkRoot.path
        environment["ANDROID_SDK_ROOT"] = toolchain.sdkRoot.path
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw AndroidRuntimeControllerError.commandFailed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw AndroidRuntimeControllerError.commandFailed("adb 命令超时")
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AndroidRuntimeControllerError.commandFailed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }
}
