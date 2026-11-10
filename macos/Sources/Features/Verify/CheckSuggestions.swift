#if os(macOS)
import Foundation

/// Commands a project probably checks itself with, offered in the Checks window as one-click
/// fills. They're only suggestions: nothing runs until the user saves one.
///
/// Every suggestion is one of a fixed set of lines chosen by which files and script names the
/// project has. No text from the project goes into a command.
enum CheckSuggestions {
    /// Files larger than this aren't read.
    private static let readLimit = 1_048_576

    static func detect(in folder: String) -> [String] {
        var found: [String] = []
        func add(_ command: String) { if !found.contains(command) { found.append(command) } }
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }

        packageScripts(in: folder).forEach(add)
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            guard let text = read(name, in: folder) else { continue }
            makeTargets(text).forEach { add("make \($0)") }
            break
        }
        if has("Cargo.toml") { add("cargo test") }
        if has("Package.swift") {
            add("swift build")
            add("swift test")
        }
        if has("go.mod") { add("go test ./...") }
        let pyproject = read("pyproject.toml", in: folder) ?? ""
        if has("pytest.ini") || has("conftest.py") || pyproject.contains("pytest") { add("pytest") }
        if has("ruff.toml") || pyproject.contains("[tool.ruff") { add("ruff check .") }
        return found
    }

    /// `test`, `lint` and `typecheck` scripts in package.json, run with the package manager
    /// whose lockfile is there.
    static func packageScripts(in folder: String) -> [String] {
        guard let text = read("package.json", in: folder),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }
        let manager = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
        var found: [String] = []
        for name in ["test", "lint", "typecheck"] {
            guard let script = scripts[name] as? String, !script.isEmpty else { continue }
            // The placeholder `npm init` writes, which always fails.
            if name == "test", script.contains("no test specified") { continue }
            found.append(name == "test" && manager != "bun" ? "\(manager) test" : "\(manager) run \(name)")
        }
        return found
    }

    /// Which of `test`, `check` and `lint` a Makefile has as targets.
    static func makeTargets(_ makefile: String) -> [String] {
        let lines = makefile.split(whereSeparator: \.isNewline)
        return ["test", "check", "lint"].filter { target in
            lines.contains { line in
                guard line.hasPrefix(target) else { return false }
                let rest = line.dropFirst(target.count).drop { $0 == " " || $0 == "\t" }
                // `test:` is a target; `test := value` and `test ::= value` set a variable.
                return rest.hasPrefix(":") && !rest.hasPrefix(":=") && !rest.hasPrefix("::=")
            }
        }
    }

    private static func read(_ name: String, in folder: String) -> String? {
        let path = (folder as NSString).appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= readLimit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
