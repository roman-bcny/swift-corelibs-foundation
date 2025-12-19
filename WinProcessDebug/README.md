# WinProcess Debug App

A standalone Swift app extracted from `swift-corelibs-foundation/Sources/Foundation/Process.swift` for debugging the Windows `Process` implementation, specifically focusing on `isRunning` state changes.

## Purpose

This app replicates the core Windows process management logic from Foundation's `Process` class, with added debug logging to trace:
- When `isRunning` is read/written
- Thread synchronization via `NSCondition`
- Process lifecycle events

## Building

### On macOS (Simulation Mode Only)
```bash
cd WinProcessDebug
swift build
swift run WinProcessDebug
```

### On Windows (Full Support)
```powershell
cd WinProcessDebug
swift build
swift run WinProcessDebug --real  # For actual process execution
swift run WinProcessDebug         # For simulation mode
```

## Command Line Options

| Option | Description |
|--------|-------------|
| `--real` | Run actual Windows processes instead of simulating |
| `--quiet` | Disable debug logging |
| `--duration <seconds>` | Set simulated process duration (default: 2.0) |

## Key Components

### `WinProcess` class
The renamed `Process` class that avoids collision with `Foundation.Process`.

### Debug Logging
The `debugLog()` function outputs timestamped, thread-identified messages for every state change.

### `isRunning` Property
The key property under investigation. It's wrapped with getters/setters that log every access:

```swift
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
```

### State Machine

1. **Initial**: `isRunning = false`, `processIdentifier = 0`
2. **After `run()`**: `isRunning = true`, `processIdentifier > 0`
3. **After completion**: `isRunning = false`, `processIdentifier > 0`

The bug likely involves race conditions between:
- Lines 616-620 (original): Monitor thread waiting for `isRunning` to become true
- Line 721 (original): Setting `isRunning = true` after `CreateProcessW`
- Line 1179 (original): Setting `isRunning = false` in `terminateRunLoop()`

## Simulation Mode

When `simulationMode = true` (default), the app simulates process execution:
- Assigns a random process ID
- Spawns a monitor thread that waits for `isRunning`
- Sleeps for `simulatedProcessDuration` seconds
- Signals completion

This allows testing the state machine logic on any platform (macOS, Linux).

## Expected Output

```
WinProcess Debug Application
Extracted from swift-corelibs-foundation for bug investigation

Mode: SIMULATION (use --real for actual process execution on Windows)

============================================================
WinProcess Debug Test
============================================================

Configuration:
  simulationMode = true
  simulatedProcessDuration = 2.0s
  debugLogging = true

------------------------------------------------------------

[2025-...] [Thread: ...] WinProcess instance created
[2025-...] [Thread: ...] run() called
[2025-...] [Thread: ...] Setting up manager thread...
[2025-...] [Thread: ...] Manager thread started
[2025-...] [Thread: ...] Manager thread run loop starting
[2025-...] [Thread: ...] Manager thread setup complete
[2025-...] [Thread: ...] isRunning GET -> false
[2025-...] [Thread: ...] isRunning GET -> false
[2025-...] [Thread: ...] Launching: /bin/echo
[2025-...] [Thread: ...] SIMULATION: Starting simulated process...
...
```

## Modifying for Your Bug

Edit `main.swift` to:
1. Add more logging in specific areas
2. Introduce artificial delays to expose race conditions
3. Test specific scenarios (rapid start/stop, multiple processes, etc.)

