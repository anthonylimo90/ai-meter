import Darwin
import Foundation

enum ClaudeUsageProbe {
    static func fetch(timeout: TimeInterval = 12) -> PlanUsageReadResult {
        guard let executableURL = executableURL() else {
            return PlanUsageReadResult(
                status: .unavailable("Claude Code executable was not found")
            )
        }
        let deadline = Date().addingTimeInterval(timeout)

        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(
            ws_row: 40,
            ws_col: 100,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            return PlanUsageReadResult(
                status: .failed("Could not open a terminal for Claude Code")
            )
        }

        let terminal = FileHandle(
            fileDescriptor: slave,
            closeOnDealloc: false
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--safe-mode"]
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        process.environment = environment

        do {
            try process.run()
        } catch {
            close(master)
            close(slave)
            return PlanUsageReadResult(
                status: .failed("Claude Code could not be started")
            )
        }
        close(slave)

        var output = Data()
        var lastReadableAt = Date()

        let startupDeadline = min(
            deadline,
            Date().addingTimeInterval(min(timeout / 2, 6))
        )
        while Date() < startupDeadline,
              process.isRunning,
              !Task.isCancelled {
            readAvailable(
                from: master,
                into: &output,
                lastReadableAt: &lastReadableAt
            )
            if let text = String(data: output, encoding: .utf8) {
                let normalized = normalizedTerminalText(text)
                if normalized.contains("automodeon")
                    || normalized.contains("❯") {
                    break
                }
            }
        }

        let command = Data("/usage\r".utf8)
        _ = command.withUnsafeBytes {
            write(master, $0.baseAddress, $0.count)
        }

        while Date() < deadline,
              process.isRunning,
              !Task.isCancelled {
            readAvailable(
                from: master,
                into: &output,
                lastReadableAt: &lastReadableAt
            )

            if let text = String(data: output, encoding: .utf8) {
                let normalized = normalizedTerminalText(text)
                let hasSession = normalized.contains("Currentsession")
                    || normalized.contains("Currensession")
                let hasWeek = normalized.contains("Currentweek(allmodels)")
                    || normalized.contains("Currentweek(allmodes)")
                if hasSession,
                   hasWeek,
                   Date().timeIntervalSince(lastReadableAt) > 0.5 {
                    break
                }
            }
        }

        let reachedDeadline = Date() >= deadline
        let exitedBeforeTermination = !process.isRunning
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < terminationDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        close(master)

        guard !Task.isCancelled else {
            return PlanUsageReadResult(
                status: .failed("Claude quota check was cancelled")
            )
        }
        guard let text = String(data: output, encoding: .utf8) else {
            return PlanUsageReadResult(
                status: .failed("Claude Code returned unreadable output")
            )
        }
        if let snapshot = parse(terminalOutput: text) {
            return .measured(snapshot)
        }
        if reachedDeadline {
            return PlanUsageReadResult(
                status: .failed("Claude quota check timed out")
            )
        }
        if output.isEmpty {
            return PlanUsageReadResult(
                status: .failed("Claude Code returned no usage output")
            )
        }
        if exitedBeforeTermination, process.terminationStatus != 0 {
            return PlanUsageReadResult(
                status: .failed("Claude Code exited before reporting usage")
            )
        }
        return PlanUsageReadResult(
            status: .unavailable("Claude usage output was not recognized")
        )
    }

    static func parse(
        terminalOutput: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> PlanUsageSnapshot? {
        let text = stripTerminalControlSequences(from: terminalOutput)
        let sessionMatches = captures(
            pattern: #"Curren(?:t)?\s*session[\s\S]{0,500}?(\d+(?:\.\d+)?)%\s*used[\s\S]{0,240}?R(?:e)?sets\s*([^\r\n]+)"#,
            in: text
        )
        let weeklyMatches = captures(
            pattern: #"Current\s*week\s*\(all\s*mode(?:l)?\s*s\)[\s\S]{0,500}?(\d+(?:\.\d+)?)%\s*used[\s\S]{0,240}?Resets\s*([^\r\n]+)"#,
            in: text
        )

        var windows: [PlanUsageWindow] = []
        if let match = sessionMatches.last,
           let usedPercent = Double(match[0]),
           let resetsAt = parseSessionReset(
               match[1],
               now: now,
               calendar: calendar
           ) {
            windows.append(
                PlanUsageWindow(
                    label: "5-hour",
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: resetsAt
                )
            )
        }

        if let match = weeklyMatches.last,
           let usedPercent = Double(match[0]),
           let resetsAt = parseWeeklyReset(
               match[1],
               now: now,
               calendar: calendar
           ) {
            windows.append(
                PlanUsageWindow(
                    label: "Weekly",
                    usedPercent: usedPercent,
                    windowMinutes: 10_080,
                    resetsAt: resetsAt
                )
            )
        }

        guard !windows.isEmpty else { return nil }
        let normalizedText = normalizedTerminalText(text)
        let planName: String? = if normalizedText.localizedCaseInsensitiveContains(
            "ClaudeMax"
        ) {
            "Max"
        } else if normalizedText.localizedCaseInsensitiveContains("ClaudePro") {
            "Pro"
        } else {
            nil
        }

        return PlanUsageSnapshot(
            source: .providerReported,
            planName: planName,
            windows: windows,
            observedAt: now
        )
    }

    private static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func stripTerminalControlSequences(
        from value: String
    ) -> String {
        let pattern = #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\)|[()][A-Z0-9]|[78])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        )
    }

    private static func normalizedTerminalText(_ value: String) -> String {
        stripTerminalControlSequences(from: value)
            .filter { !$0.isWhitespace }
    }

    private static func readAvailable(
        from descriptor: Int32,
        into output: inout Data,
        lastReadableAt: inout Date
    ) {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = poll(&pollDescriptor, 1, 250)
        guard result > 0,
              pollDescriptor.revents & Int16(POLLIN) != 0
        else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return }
        let chunk = Data(buffer.prefix(count))
        output.append(chunk)
        if chunk.range(of: Data([0x1B, 0x5B, 0x63])) != nil {
            let response = Data("\u{1B}[?1;2c".utf8)
            _ = response.withUnsafeBytes {
                write(descriptor, $0.baseAddress, $0.count)
            }
        }
        lastReadableAt = .now
    }

    private static func captures(
        pattern: String,
        in value: String
    ) -> [[String]] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: value) else {
                    return nil
                }
                return String(value[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func parseSessionReset(
        _ value: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let time = timeComponents(in: value) else { return nil }
        var components = calendar.dateComponents(
            [.year, .month, .day],
            from: now
        )
        components.hour = time.hour
        components.minute = time.minute
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private static func parseWeeklyReset(
        _ value: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pattern = #"([A-Za-z]{3,9})\s*(\d{1,2})\s*at\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm))"#
        guard let match = captures(pattern: pattern, in: value).last,
              match.count == 3,
              let day = Int(match[1]),
              let month = monthNumber(for: match[0]),
              let time = timeComponents(in: match[2])
        else {
            return nil
        }

        var components = DateComponents()
        components.year = calendar.component(.year, from: now)
        components.month = month
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now {
            components.year = (components.year ?? 0) + 1
            date = calendar.date(from: components) ?? date
        }
        return date
    }

    private static func timeComponents(
        in value: String
    ) -> (hour: Int, minute: Int)? {
        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#
        guard let match = captures(pattern: pattern, in: value).last,
              match.count >= 2,
              var hour = Int(match[0])
        else {
            return nil
        }
        let minute = match.count > 2 ? Int(match[1]) ?? 0 : 0
        let meridiem = match.last?.lowercased()
        if meridiem == "pm", hour < 12 {
            hour += 12
        } else if meridiem == "am", hour == 12 {
            hour = 0
        }
        return (hour, minute)
    }

    private static func monthNumber(for value: String) -> Int? {
        let normalized = String(value.prefix(3)).lowercased()
        return [
            "jan", "feb", "mar", "apr", "may", "jun",
            "jul", "aug", "sep", "oct", "nov", "dec"
        ]
            .firstIndex(of: normalized)
            .map { $0 + 1 }
    }
}
