import Foundation
import AppKit

@MainActor
final class SelfUpdater: ObservableObject {
    @Published var updateAvailable = false
    @Published var isChecking = false
    @Published var isUpdating = false

    /// The cask by its full name. Homebrew 7 refuses short-name commands for
    /// casks from taps the user hasn't trusted, but accepts (and trusts) a
    /// fully named one, so every brew call here uses this.
    private static let caskFullName = "rossnicholson/tap/clawdbar"

    // Called on launch — quick check against local cache
    func checkSilent() async {
        let result = await brew(["outdated", "--cask", Self.caskFullName])
        updateAvailable = Self.listsSelf(result.output)
    }

    // Called when the user explicitly taps "Check for Updates"
    func check() async {
        isChecking = true
        defer { isChecking = false }
        _ = await brew(["update"], timeout: 60)
        let result = await brew(["outdated", "--cask", Self.caskFullName])
        updateAvailable = Self.listsSelf(result.output)
    }

    /// An app can't upgrade itself from a `brew` child process: the cask's
    /// `uninstall quit:` closes ClawdBar mid-upgrade, which kills the child brew
    /// and leaves the app closed and not updated. Hand the work to a detached
    /// script that waits for us to quit, upgrades, then reopens ClawdBar.
    func update() async {
        isUpdating = true
        guard launchDetachedUpdater() else {
            isUpdating = false
            return
        }
        NSApp.terminate(nil)
    }

    private static func listsSelf(_ output: String) -> Bool {
        output.lines.contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == "clawdbar" || line == caskFullName
        }
    }

    private func launchDetachedUpdater() -> Bool {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let dir = support.appendingPathComponent("ClawdBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("self-update.sh")
        let logURL = dir.appendingPathComponent("self-update.log")

        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "com.rossnicholson.ClawdBar"

        // `$(...)`, `$LOG` and `$status` are shell; only `\(...)` is Swift.
        let script = """
        #!/bin/sh
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOMEBREW_NO_AUTO_UPDATE=1
        LOG="\(logURL.path)"
        : > "$LOG"
        echo "[$(date)] waiting for ClawdBar (pid \(pid)) to quit" >> "$LOG"
        for i in $(seq 1 60); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.5
        done
        echo "[$(date)] running brew upgrade --cask \(Self.caskFullName)" >> "$LOG"
        "\(brewPath)" upgrade --cask \(Self.caskFullName) >> "$LOG" 2>&1
        status=$?
        echo "[$(date)] brew exited with status $status" >> "$LOG"
        if [ "$status" -eq 0 ]; then
            open -b "\(bundleID)" || open "\(appPath)"
        else
            osascript -e 'display notification "Update failed — see \(logURL.path)" with title "ClawdBar"' >/dev/null 2>&1 || true
            open -b "\(bundleID)" || open "\(appPath)"
        fi
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        // Detached stdio: a broken pipe to this (quitting) process must not stop it
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

private let brewPath: String = {
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/brew"
}()

/// A Finder-launched app gets a minimal environment; give brew a usable PATH
/// and turn off its implicit auto-update so checks stay quick.
private let brewEnvironment: [String: String] = {
    var env = ProcessInfo.processInfo.environment
    let prefix = (brewPath as NSString).deletingLastPathComponent
    env["PATH"] = "\(prefix):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":\($0)" } ?? "")
    if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    env["HOMEBREW_NO_ENV_HINTS"] = "1"
    return env
}()

private struct BrewResult { let output: String; let exitCode: Int32 }

private func brew(_ args: [String], timeout: TimeInterval = 30) async -> BrewResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = args
        process.environment = brewEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            continuation.resume(returning: BrewResult(output: "", exitCode: 1))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        // Read while brew runs, so large output can't fill the pipe and stall it
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: BrewResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            ))
        }
    }
}

private extension String {
    var lines: [String] { split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}
