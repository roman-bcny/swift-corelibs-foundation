// WinProcess Debug App
// Extracted from swift-corelibs-foundation/Sources/Foundation/Process.swift
// Purpose: Debug isRunning state changes in Windows Process implementation

import Foundation

#if os(Windows)
import WinSDK
import let WinSDK.HANDLE_FLAG_INHERIT
import let WinSDK.STARTF_USESTDHANDLES
import struct WinSDK.HANDLE
#endif

// MARK: - Debug Logging

/// Set to true to enable verbose logging of state changes
var debugLogging = true

func debugLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    if debugLogging {
        let timestamp = Date()
        let threadId = Thread.current.description
        print("[\(timestamp)] [Thread: \(threadId)] \(message())")
    }
}

// MARK: - Simulation Mode

/// When true, simulates process execution instead of actually running processes
/// This allows testing the state machine on any platform
var simulationMode = true

/// How long to simulate process running (in seconds)
var simulatedProcessDuration: TimeInterval = 2.0

// MARK: - Windows Command Line Quoting (from original)

#if os(Windows)
private func quoteWindowsCommandLine(_ commandLine: [String]) -> String {
    func quoteWindowsCommandArg(arg: String) -> String {
        // Windows escaping, adapted from Daniel Colascione's "Everyone quotes
        // command line arguments the wrong way" - Microsoft Developer Blog
        if !arg.contains(where: {" \t\n\"".contains($0)}) {
            return arg
        }

        // To escape the command line, we surround the argument with quotes. However
        // the complication comes due to how the Windows command line parser treats
        // backslashes (\) and quotes (")
        //
        // - \ is normally treated as a literal backslash
        //     - e.g. foo\bar\baz => foo\bar\baz
        // - However, the sequence \" is treated as a literal "
        //     - e.g. foo\"bar => foo"bar
        //
        // But then what if we are given a path that ends with a \? Surrounding
        // foo\bar\ with " would be "foo\bar\" which would be an unterminated string

        // since it ends on a literal quote. To allow this case the parser treats:
        //
        // - \\" as \ followed by the " metachar
        // - \\\" as \ followed by a literal "
        // - In general:
        //     - 2n \ followed by " => n \ followed by the " metachar
        //     - 2n+1 \ followed by " => n \ followed by a literal "
        var quoted = "\""
        var unquoted = arg.unicodeScalars

        while !unquoted.isEmpty {
            guard let firstNonBackslash = unquoted.firstIndex(where: { $0 != "\\" }) else {
                // String ends with a backslash e.g. foo\bar\, escape all the backslashes
                // then add the metachar " below
                let backslashCount = unquoted.count
                quoted.append(String(repeating: "\\", count: backslashCount * 2))
                break
            }
            let backslashCount = unquoted.distance(from: unquoted.startIndex, to: firstNonBackslash)
            if (unquoted[firstNonBackslash] == "\"") {
                // This is  a string of \ followed by a " e.g. foo\"bar. Escape the
                // backslashes and the quote
                quoted.append(String(repeating: "\\", count: backslashCount * 2 + 1))
                quoted.append(String(unquoted[firstNonBackslash]))
            } else {
                // These are just literal backslashes
                quoted.append(String(repeating: "\\", count: backslashCount))
                quoted.append(String(unquoted[firstNonBackslash]))
            }
            // Drop the backslashes and the following character
            unquoted.removeFirst(backslashCount + 1)
        }
        quoted.append("\"")
        return quoted
    }
    return commandLine.map(quoteWindowsCommandArg).joined(separator: " ")
}
#endif

// MARK: - WinProcess Termination Reason

public enum WinProcessTerminationReason: Int, Sendable {
    case exit
    case uncaughtSignal
}

// MARK: - WinProcess Class

/// A reimplementation of the Windows-specific Process code for debugging purposes
public class WinProcess: @unchecked Sendable {
    
    // MARK: - Static Setup (Manager Thread)
    
    private static let setupLock = NSLock()
    private static var isSetupDone = false
    private static var managerThreadRunLoop: RunLoop? = nil
    private static let managerThreadRunLoopIsRunningCondition = NSCondition()
    private static var managerThreadRunLoopIsRunning = false
    
    private static func setup() {
        setupLock.lock()
        defer { setupLock.unlock() }
        
        guard !isSetupDone else { return }
        
        debugLog("Setting up manager thread...")
        
        let thread = Thread {
            debugLog("Manager thread started")
            managerThreadRunLoop = RunLoop.current
            
            // IMPORTANT: To keep a RunLoop alive, we need a persistent source.
            // The original uses CFRunLoopSource, but CoreFoundation isn't available
            // for standalone apps on Windows.
            //
            // Instead, we use a Port which is a Foundation-native way to keep
            // a RunLoop alive. A Port added to a RunLoop prevents it from exiting.
            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            
            managerThreadRunLoopIsRunningCondition.lock()
            managerThreadRunLoopIsRunning = true
            managerThreadRunLoopIsRunningCondition.broadcast()
            managerThreadRunLoopIsRunningCondition.unlock()
            
            debugLog("Manager thread run loop starting (with Port)")
            
            // Run the run loop indefinitely
            // Using run(mode:before:) in a loop is more reliable across platforms
            while true {
                _ = RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }
        }
        thread.name = "WinProcess.ManagerThread"
        thread.start()
        
        // Wait for manager thread to be ready
        managerThreadRunLoopIsRunningCondition.lock()
        while !managerThreadRunLoopIsRunning {
            managerThreadRunLoopIsRunningCondition.wait()
        }
        managerThreadRunLoopIsRunningCondition.unlock()
        
        isSetupDone = true
        debugLog("Manager thread setup complete")
    }
    
    // MARK: - Instance Properties
    
    public init() {
        debugLog("WinProcess instance created")
    }
    
    // Executable and arguments
    private var _executableURL: URL?
    public var executableURL: URL? {
        get { _executableURL }
        set {
            guard let url = newValue, url.isFileURL else {
                fatalError("must provide a file URL for executableURL")
            }
            _executableURL = url
        }
    }
    
    private var _currentDirectoryPath = FileManager.default.currentDirectoryPath
    public var currentDirectoryURL: URL? {
        get { _currentDirectoryPath.isEmpty ? nil : URL(fileURLWithPath: _currentDirectoryPath, isDirectory: true) }
        set {
            if let url = newValue {
                guard url.isFileURL else { fatalError("non-file URL argument") }
                _currentDirectoryPath = url.path
            } else {
                _currentDirectoryPath = FileManager.default.currentDirectoryPath
            }
        }
    }
    
    public var arguments: [String]?
    public var environment: [String: String]?
    
    // Standard I/O - simplified for debugging
    public var standardInput: Any? = nil
    public var standardOutput: Any? = nil
    public var standardError: Any? = nil
    
    // Process launched condition - key for isRunning bug
    private let processLaunchedCondition = NSCondition()
    
    // Run loop references
    private weak var runLoop: RunLoop? = nil
    
    // MARK: - Status Properties (KEY FOR BUG INVESTIGATION)
    
    #if os(Windows)
    public private(set) var processHandle: HANDLE = INVALID_HANDLE_VALUE
    #else
    // Simulation: use a dummy value
    public private(set) var simulatedProcessHandle: Int = -1
    #endif
    
    public private(set) var processIdentifier: Int32 = 0
    
    /// THE KEY PROPERTY FOR BUG INVESTIGATION
    /// Tracks whether the process is currently running
    private var _isRunning: Bool = false
    public private(set) var isRunning: Bool {
        get {
            debugLog("isRunning GET -> \(_isRunning)")
            return _isRunning
        }
        set {
            debugLog("isRunning SET: \(_isRunning) -> \(newValue)")
            _isRunning = newValue
        }
    }
    
    private var hasStarted: Bool { processIdentifier > 0 }
    private var hasFinished: Bool { !isRunning && processIdentifier > 0 }
    
    private var _terminationStatus: Int32 = 0
    public var terminationStatus: Int32 {
        precondition(hasStarted, "task not launched")
        precondition(hasFinished, "task still running")
        return _terminationStatus
    }
    
    private var _terminationReason: WinProcessTerminationReason = .exit
    public var terminationReason: WinProcessTerminationReason {
        precondition(hasStarted, "task not launched")
        precondition(hasFinished, "task still running")
        return _terminationReason
    }
    
    public var terminationHandler: (@Sendable (WinProcess) -> Void)?
    
    // MARK: - Run Method
    
    public func run() throws {
        debugLog("run() called")
        
        processLaunchedCondition.lock()
        defer {
            debugLog("run() broadcasting processLaunchedCondition")
            processLaunchedCondition.broadcast()
            processLaunchedCondition.unlock()
        }
        
        // Setup manager thread
        WinProcess.setup()
        
        // Check process state
        guard !hasStarted && !hasFinished else {
            debugLog("ERROR: Process already started or finished")
            throw NSError(domain: NSCocoaErrorDomain, code: NSExecutableLoadError)
        }
        
        guard let launchPath = executableURL?.path else {
            debugLog("ERROR: No executable URL set")
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        
        debugLog("Launching: \(launchPath)")
        
        if simulationMode {
            try runSimulated(launchPath: launchPath)
        } else {
            #if os(Windows)
            try runWindows(launchPath: launchPath)
            #else
            debugLog("ERROR: Real process execution only supported on Windows")
            debugLog("Enable simulationMode for testing on other platforms")
            throw NSError(domain: NSCocoaErrorDomain, code: NSExecutableNotLoadableError)
            #endif
        }
    }
    
    // MARK: - Simulated Run (for debugging on any platform)
    
    private func runSimulated(launchPath: String) throws {
        debugLog("SIMULATION: Starting simulated process for \(launchPath)")
        
        // Assign a fake process ID
        processIdentifier = Int32.random(in: 1000...99999)
        debugLog("SIMULATION: Assigned processIdentifier = \(processIdentifier)")
        
        #if !os(Windows)
        simulatedProcessHandle = Int(processIdentifier)
        #endif
        
        // Start a monitoring thread (simulates the CFSocket callback in original)
        let monitorThread = Thread { [weak self] in
            guard let self = self else { return }
            
            debugLog("SIMULATION: Monitor thread started, waiting for isRunning to become true")
            
            // This mirrors the original code's wait pattern (lines 616-620)
            self.processLaunchedCondition.lock()
            while self.isRunning == false {
                debugLog("SIMULATION: Monitor waiting... isRunning is still false")
                self.processLaunchedCondition.wait()
            }
            self.processLaunchedCondition.unlock()
            
            debugLog("SIMULATION: Monitor detected isRunning = true, now 'waiting' for process")
            
            // Simulate WaitForSingleObject / waitpid
            Thread.sleep(forTimeInterval: simulatedProcessDuration)
            
            debugLog("SIMULATION: Process 'completed'")
            
            // Simulate exit status determination
            self._terminationStatus = 0
            self._terminationReason = .exit
            
            // Signal completion
            self.terminateRunLoop()
        }
        monitorThread.name = "WinProcess.SimulatedMonitor.\(processIdentifier)"
        monitorThread.start()
        
        // Add to manager run loop (simplified - just schedule completion)
        if let managerRL = WinProcess.managerThreadRunLoop {
            debugLog("SIMULATION: Adding to manager run loop")
            managerRL.perform { [weak self] in
                debugLog("SIMULATION: Manager run loop acknowledged process")
                _ = self // Keep reference
            }
        }
        
        debugLog("SIMULATION: Setting isRunning = true")
        isRunning = true
        
        debugLog("SIMULATION: run() completing, process 'launched'")
    }
    
    #if os(Windows)
    // MARK: - Real Windows Run
    
    private func _socketpair() -> (first: SOCKET, second: SOCKET) {
        let listener: SOCKET = socket(AF_INET, SOCK_STREAM, 0)
        if listener == INVALID_SOCKET {
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        defer { closesocket(listener) }
        
        var result: Int32 = SOCKET_ERROR
        
        var address: sockaddr_in =
            sockaddr_in(sin_family: ADDRESS_FAMILY(AF_INET), sin_port: USHORT(0),
                        sin_addr: IN_ADDR(S_un: in_addr.__Unnamed_union_S_un(S_un_b: in_addr.__Unnamed_union_S_un.__Unnamed_struct_S_un_b(s_b1: 127, s_b2: 0, s_b3: 0, s_b4: 1))),
                        sin_zero: (CHAR(0), CHAR(0), CHAR(0), CHAR(0), CHAR(0), CHAR(0), CHAR(0), CHAR(0)))
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                result = bind(listener, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if result == SOCKET_ERROR {
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        if listen(listener, 1) == SOCKET_ERROR {
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                var value: Int32 = Int32(MemoryLayout<sockaddr_in>.size)
                result = getsockname(listener, $0, &value)
            }
        }
        if result == SOCKET_ERROR {
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        let first: SOCKET = socket(AF_INET, SOCK_STREAM, 0)
        if first == INVALID_SOCKET {
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                result = connect(first, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if result == SOCKET_ERROR {
            closesocket(first)
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        var value: u_long = 1
        if ioctlsocket(first, CLong(FIONBIO), &value) == SOCKET_ERROR {
            closesocket(first)
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        var option: CInt = 1
        if setsockopt(first, IPPROTO_TCP.rawValue, TCP_NODELAY, &option,
                      CInt(MemoryLayout.size(ofValue: option))) == SOCKET_ERROR {
            closesocket(first)
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        let second: SOCKET = accept(listener, nil, nil)
        if second == INVALID_SOCKET {
            closesocket(first)
            return (first: INVALID_SOCKET, second: INVALID_SOCKET)
        }
        
        return (first: first, second: second)
    }
    
    private func runWindows(launchPath: String) throws {
        debugLog("WINDOWS: Starting real process for \(launchPath)")
        
        var command: [String] = [launchPath]
        if let arguments = self.arguments {
            command.append(contentsOf: arguments)
        }
        
        var siStartupInfo: STARTUPINFOW = STARTUPINFOW()
        siStartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        siStartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        
        // For simplicity, redirect to NUL if not specified
        // In real usage you'd handle Pipe/FileHandle like the original
        
        var piProcessInfo: PROCESS_INFORMATION = PROCESS_INFORMATION()
        
        var environment: [String: String] = self.environment ?? ProcessInfo.processInfo.environment
        
        // Ensure PATH is passed
        if environment["Path"] == nil, let path = ProcessInfo.processInfo.environment["Path"] {
            environment["Path"] = path
        }
        
        let szEnvironment: String = environment.map { $0.key + "=" + $0.value }.joined(separator: "\0") + "\0\0"
        
        let sockets = _socketpair()
        debugLog("WINDOWS: Created socket pair")
        
        // Start monitor thread (simplified version of CFSocket callback)
        let monitorThread = Thread { [weak self] in
            guard let self = self else { return }
            
            debugLog("WINDOWS: Monitor thread waiting for isRunning")
            
            self.processLaunchedCondition.lock()
            while self.isRunning == false {
                debugLog("WINDOWS: Monitor waiting... isRunning is still false")
                self.processLaunchedCondition.wait()
            }
            self.processLaunchedCondition.unlock()
            
            debugLog("WINDOWS: Monitor calling WaitForSingleObject")
            WaitForSingleObject(self.processHandle, WinSDK.INFINITE)
            
            debugLog("WINDOWS: WaitForSingleObject returned, process completed")
            
            var dwExitCode: DWORD = 0
            GetExitCodeProcess(self.processHandle, &dwExitCode)
            
            debugLog("WINDOWS: Exit code = \(dwExitCode)")
            
            if (dwExitCode & 0xF0000000) == 0x80000000
            || (dwExitCode & 0xF0000000) == 0xC0000000
            || (dwExitCode & 0xF0000000) == 0xE0000000
            || dwExitCode == 3 {
                self._terminationStatus = Int32(dwExitCode & 0x3FFFFFFF)
                self._terminationReason = .uncaughtSignal
            } else {
                self._terminationStatus = Int32(bitPattern: UInt32(dwExitCode))
                self._terminationReason = .exit
            }
            
            self.terminateRunLoop()
        }
        monitorThread.name = "WinProcess.WindowsMonitor"
        monitorThread.start()
        
        let workingDirectory = currentDirectoryURL?.path ?? FileManager.default.currentDirectoryPath
        
        try quoteWindowsCommandLine(command).withCString(encodedAs: UTF16.self) { wszCommandLine in
            try workingDirectory.withCString(encodedAs: UTF16.self) { wszCurrentDirectory in
                try szEnvironment.withCString(encodedAs: UTF16.self) { wszEnvironment in
                    debugLog("WINDOWS: Calling CreateProcessW")
                    if !CreateProcessW(nil, UnsafeMutablePointer<WCHAR>(mutating: wszCommandLine),
                                       nil, nil, true,
                                       DWORD(CREATE_UNICODE_ENVIRONMENT), UnsafeMutableRawPointer(mutating: wszEnvironment),
                                       wszCurrentDirectory,
                                       &siStartupInfo, &piProcessInfo) {
                        let error = GetLastError()
                        debugLog("WINDOWS: CreateProcessW failed with error \(error)")
                        throw NSError(domain: "WinProcess", code: Int(error), userInfo: [
                            NSLocalizedDescriptionKey: "CreateProcessW failed with error \(error)"
                        ])
                    }
                }
            }
        }
        
        self.processHandle = piProcessInfo.hProcess
        debugLog("WINDOWS: Process handle = \(processHandle)")
        
        CloseHandle(piProcessInfo.hThread)
        self.processIdentifier = Int32(GetProcessId(self.processHandle))
        debugLog("WINDOWS: Process ID = \(processIdentifier)")
        
        self.runLoop = RunLoop.current
        
        debugLog("WINDOWS: Setting isRunning = true")
        isRunning = true
        
        closesocket(sockets.second)
        
        debugLog("WINDOWS: run() completing")
    }
    #endif
    
    // MARK: - Terminate Run Loop (called when process completes)
    
    private func terminateRunLoop() {
        debugLog("terminateRunLoop() called")
        
        let runLoopToWakeup = self.runLoop
        
        debugLog("Setting isRunning = false")
        isRunning = false
        
        // Wake up waiting run loop without using CoreFoundation internals.
        if let runLoopToWakeup = runLoopToWakeup {
            debugLog("Waking up run loop")
            runLoopToWakeup.perform { }
        }
        
        if let handler = self.terminationHandler {
            debugLog("Invoking termination handler on new thread")
            let thread = Thread { handler(self) }
            thread.start()
        }
        
        // Close handle on Windows
        #if os(Windows)
        debugLog("WINDOWS: Closing process handle")
        CloseHandle(self.processHandle)
        #endif
        
        debugLog("terminateRunLoop() complete")
    }
    
    // MARK: - Wait Until Exit
    
    public func waitUntilExit() {
        debugLog("waitUntilExit() called")
        
        let runInterval = 0.05
        let currentRunLoop = RunLoop.current
        self.runLoop = currentRunLoop
        
        while self.isRunning {
            debugLog("waitUntilExit() polling, isRunning = \(self.isRunning)")
            _ = currentRunLoop.run(mode: .default, before: Date(timeIntervalSinceNow: runInterval))
        }
        
        debugLog("waitUntilExit() complete, isRunning = \(self.isRunning)")
        
        self.runLoop = nil
    }
    
    // MARK: - Interrupt / Terminate
    
    public func interrupt() {
        precondition(hasStarted, "task not launched")
        debugLog("interrupt() called")
        #if os(Windows)
        TerminateProcess(processHandle, UINT(2)) // SIGINT = 2
        #else
        debugLog("SIMULATION: Process interrupted")
        _terminationStatus = 2
        _terminationReason = .uncaughtSignal
        terminateRunLoop()
        #endif
    }
    
    public func terminate() {
        precondition(hasStarted, "task not launched")
        debugLog("terminate() called")
        #if os(Windows)
        TerminateProcess(processHandle, UINT(0xC0000000 | DWORD(15))) // SIGTERM = 15
        #else
        debugLog("SIMULATION: Process terminated")
        _terminationStatus = 15
        _terminationReason = .uncaughtSignal
        terminateRunLoop()
        #endif
    }
}

// MARK: - Test Harness

func runTest() {
    print("=" * 60)
    print("WinProcess Debug Test")
    print("=" * 60)
    print()
    print("Configuration:")
    print("  simulationMode = \(simulationMode)")
    print("  simulatedProcessDuration = \(simulatedProcessDuration)s")
    print("  debugLogging = \(debugLogging)")
    print()
    print("-" * 60)
    print()
    
    let process = WinProcess()
    
    #if os(Windows)
    if !simulationMode {
        // On Windows, try running a real command
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "echo", "Hello from WinProcess", "&&", "timeout", "/t", "1"]
    } else {
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
    }
    #else
    // On non-Windows, we can only simulate
    process.executableURL = URL(fileURLWithPath: "/bin/echo")
    process.arguments = ["Hello", "World"]
    #endif
    
    print("Launching process...")
    print()
    
    do {
        try process.run()
        
        print()
        print("Process launched, processIdentifier = \(process.processIdentifier)")
        print("isRunning = \(process.isRunning)")
        print()
        print("Waiting for process to complete...")
        print()
        
        process.waitUntilExit()
        
        print()
        print("-" * 60)
        print("Process completed!")
        print("  terminationStatus = \(process.terminationStatus)")
        print("  terminationReason = \(process.terminationReason)")
        print("  isRunning = \(process.isRunning)")
        
    } catch {
        print("ERROR: \(error)")
    }
    
    print()
    print("=" * 60)
    print("Test complete")
    print("=" * 60)
}

// String repeat operator for formatting
extension String {
    static func * (string: String, count: Int) -> String {
        return String(repeating: string, count: count)
    }
}

// MARK: - Main Entry Point

print()
print("WinProcess Debug Application")
print("Extracted from swift-corelibs-foundation for bug investigation")
print()

// Parse command line args
let args = CommandLine.arguments
if args.contains("--real") {
    simulationMode = false
    print("Mode: REAL process execution (Windows only)")
} else {
    print("Mode: SIMULATION (use --real for actual process execution on Windows)")
}

if args.contains("--quiet") {
    debugLogging = false
}

if let durationIdx = args.firstIndex(of: "--duration"), durationIdx + 1 < args.count,
   let duration = TimeInterval(args[durationIdx + 1]) {
    simulatedProcessDuration = duration
}

print()

runTest()
