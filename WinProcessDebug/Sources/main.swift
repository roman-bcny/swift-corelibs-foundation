import Foundation

// Simple benchmark: spawn short-lived subprocesses concurrently in batches

let totalIterations = 10000
let batchSize = 8
let progressInterval = 100

print("Process Spawn Benchmark (Concurrent)")
print("=====================================")
print("Total iterations: \(totalIterations)")
print("Batch size: \(batchSize)")
print()

func runProcess(iteration: Int) async throws -> String {
    let process = Process()
    let pipe = Pipe()
    
    #if os(Windows)
    process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
    process.arguments = ["/c", "echo", "Hello from iteration \(iteration)"]
    #else
    process.executableURL = URL(fileURLWithPath: "/bin/echo")
    process.arguments = ["Hello from iteration \(iteration)"]
    #endif
    
    process.standardOutput = pipe
    
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

func runBatch(startIndex: Int, count: Int) async throws -> Int {
    try await withThrowingTaskGroup(of: String.self) { group in
        for i in startIndex..<(startIndex + count) {
            group.addTask {
                try await runProcess(iteration: i)
            }
        }
        
        var completed = 0
        for try await _ in group {
            completed += 1
        }
        return completed
    }
}

let startTime = Date()
var totalCompleted = 0
var lastProgressReport = 0

// Run in batches
var currentIndex = 1
while currentIndex <= totalIterations {
    let remaining = totalIterations - currentIndex + 1
    let currentBatchSize = min(batchSize, remaining)
    
    do {
        let completed = try await runBatch(startIndex: currentIndex, count: currentBatchSize)
        totalCompleted += completed
        
        // Print progress every 100 completions
        if totalCompleted / progressInterval > lastProgressReport {
            lastProgressReport = totalCompleted / progressInterval
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = Double(totalCompleted) / elapsed
            print("Progress: \(totalCompleted)/\(totalIterations) (\(String(format: "%.1f", rate)) proc/sec)")
        }
    } catch {
        print("Error in batch starting at \(currentIndex): \(error)")
    }
    
    currentIndex += currentBatchSize
}

let elapsed = Date().timeIntervalSince(startTime)

print()
print("=====================================")
print("Total completed: \(totalCompleted)")
print("Total time: \(String(format: "%.3f", elapsed)) seconds")
print("Average per process: \(String(format: "%.3f", elapsed / Double(totalCompleted) * 1000)) ms")
print("Processes per second: \(String(format: "%.1f", Double(totalCompleted) / elapsed))")
