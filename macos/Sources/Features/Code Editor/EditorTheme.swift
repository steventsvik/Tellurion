#if os(macOS)
import Foundation

/// The terminal's resolved colors and font, for styling the code editor to match.
///
/// Theme colors (cursor, selection) and the font family aren't exposed through the
/// config C API, so this asks the app's own binary for its resolved configuration
/// (`ghostty +show-config`): once for defaults, once for the user's values on top.
/// It runs in the background and only when the editor opens or the config changes.
enum EditorTheme {
    static func load(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var values = parse(showConfig(defaults: true))
            for (key, value) in parse(showConfig(defaults: false)) { values[key] = value }

            var palette = [String](repeating: "", count: 16)
            for entry in values["palette"] ?? [] {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0]), index < 16 { palette[index] = String(parts[1]) }
            }
            func color(_ key: String) -> String? {
                guard let value = values[key]?.last, value.hasPrefix("#"), value.count == 7 else { return nil }
                return value
            }
            let theme: [String: Any] = [
                "background": color("background") ?? "#000000",
                "foreground": color("foreground") ?? "#ffffff",
                "cursor": color("cursor-color") ?? "",
                "selectionBackground": color("selection-background") ?? "",
                "palette": palette,
                "fontFamily": values["font-family"]?.first(where: { !$0.isEmpty }) ?? "",
                "fontSize": Double(values["font-size"]?.last ?? "") ?? 13,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: theme),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { completion(json) }
        }
    }

    private static func showConfig(defaults: Bool) -> String {
        guard let executable = Bundle.main.executableURL else { return "" }
        let process = Process()
        process.executableURL = executable
        process.arguments = defaults ? ["+show-config", "--default"] : ["+show-config"]
        process.environment = EventToken.scrubbed(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// "key = value" lines; repeated keys (palette, font-family) collect all values.
    private static func parse(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound])
            let value = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            result[key, default: []].append(value)
        }
        return result
    }
}
#endif
