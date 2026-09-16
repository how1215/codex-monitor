import Foundation

protocol AppServerTransport: AnyObject {
    var isRunning: Bool { get }
    func start(onData: @escaping (Data) -> Void, onTermination: @escaping () -> Void) throws
    func send(_ data: Data) throws
    func stop()
}

final class ProcessAppServerTransport: AppServerTransport {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?

    var isRunning: Bool { process?.isRunning == true }

    func start(onData: @escaping (Data) -> Void, onTermination: @escaping () -> Void) throws {
        let executable = try CodexAppServerClient.locateCodex()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onData(data) }
        }
        process.terminationHandler = { _ in onTermination() }
        do {
            try process.run()
            self.process = process
            self.input = input
            self.output = output
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexMonitorError.processLaunch(error.localizedDescription)
        }
    }

    func send(_ data: Data) throws {
        guard isRunning, let input else { throw CodexMonitorError.disconnected }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
    }
}
