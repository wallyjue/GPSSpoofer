// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import Foundation

struct HelperError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DeviceInfo: Identifiable, Hashable, Decodable {
    let udid: String
    let connection: String
    let name: String?
    let version: String?
    let error: String?

    var id: String { udid }
    var displayName: String {
        let title = name ?? udid
        guard let version, !version.isEmpty else { return title }
        return "\(title)（iOS \(version)，\(connection)）"
    }
}

/// 管理 Python helper 子程序，透過 stdin/stdout 逐行 JSON 溝通。
final class HelperBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]

    var onLog: (@Sendable (String) -> Void)?
    var onTerminate: (@Sendable () -> Void)?

    // MARK: - 啟動

    func start() throws {
        let (executable, arguments) = try Self.locateHelper()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onLog?(text.trimmingCharacters(in: .newlines))
        }
        process.terminationHandler = { [weak self] _ in self?.handleTermination() }

        try process.run()
        lock.withLock {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
        }
    }

    func stop() {
        lock.withLock { process }?.terminate()
    }

    /// 尋找 helper，優先順序：
    /// 1. App 內附的 PyInstaller 獨立執行檔（scripts/package.sh，可發布）
    /// 2. Info.plist 指定的 Python（scripts/build_app.sh，僅限本機）
    /// 3. 環境變數，或專案目錄下的 .venv（swift run）
    private static func locateHelper() throws -> (executable: URL, arguments: [String]) {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("helper/location_helper/location_helper"),
           fm.isExecutableFile(atPath: bundled.path) {
            return (bundled, [])
        }

        var candidates: [(String, String)] = []

        if let python = Bundle.main.object(forInfoDictionaryKey: "GPSHelperPython") as? String,
           let script = Bundle.main.url(forResource: "location_helper", withExtension: "py")?.path {
            candidates.append((python, script))
        }
        let env = ProcessInfo.processInfo.environment
        if let python = env["GPS_HELPER_PYTHON"], let script = env["GPS_HELPER_SCRIPT"] {
            candidates.append((python, script))
        }
        let cwd = fm.currentDirectoryPath
        candidates.append(("\(cwd)/.venv/bin/python", "\(cwd)/helper/location_helper.py"))

        for (python, script) in candidates where fm.isExecutableFile(atPath: python) && fm.fileExists(atPath: script) {
            return (URL(fileURLWithPath: python), ["-u", script])
        }
        throw HelperError(message: "找不到 Python helper，請先執行 scripts/setup.sh")
    }

    // MARK: - 請求 / 回應

    func request(_ cmd: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            let payload: Data
            let handle: FileHandle?
            do {
                (payload, handle) = try lock.withLock {
                    let id = nextID
                    nextID += 1
                    var body = params
                    body["id"] = id
                    body["cmd"] = cmd
                    var data = try JSONSerialization.data(withJSONObject: body)
                    data.append(0x0A)
                    pending[id] = continuation
                    return (data, stdinHandle)
                }
            } catch {
                continuation.resume(throwing: error)
                return
            }
            guard let handle else {
                failAll(HelperError(message: "helper 尚未啟動"))
                return
            }
            do {
                try handle.write(contentsOf: payload)
            } catch {
                failAll(HelperError(message: "無法寫入 helper：\(error.localizedDescription)"))
            }
        }
    }

    func listDevices() async throws -> [DeviceInfo] {
        let result = try await request("list")
        let data = try JSONSerialization.data(withJSONObject: result ?? [])
        return try JSONDecoder().decode([DeviceInfo].self, from: data)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines { dispatch(line) }
    }

    private func dispatch(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else { return }  // 例如 {"event": "ready"}
        guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }

        if object["ok"] as? Bool == true {
            let result = object["result"]
            continuation.resume(returning: result is NSNull ? nil : result)
        } else {
            continuation.resume(throwing: HelperError(message: object["error"] as? String ?? "未知錯誤"))
        }
    }

    private func handleTermination() {
        lock.withLock {
            process = nil
            stdinHandle = nil
        }
        failAll(HelperError(message: "helper 程序已結束"))
        onTerminate?()
    }

    private func failAll(_ error: Error) {
        let waiting = lock.withLock {
            let all = pending
            pending.removeAll()
            return all
        }
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}
