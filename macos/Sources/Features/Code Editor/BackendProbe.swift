#if os(macOS)
import AppKit
import Foundation

/// What the code editor's Backend tab knows about a project's backend: Supabase, Cloudflare,
/// Vercel and the rest.
///
/// Everything here is read-only, and the page can only ask for the fixed actions below; it
/// never gets to run its own commands. Live data comes from the providers' own CLIs
/// (`supabase`, `vercel`, `wrangler`) using their existing logins, so the app never reads or
/// stores a token. Secrets in `.env` files never leave this file: the page only gets the
/// names of the variables and which services they point at.
enum BackendProbe {
    // MARK: Entry point

    /// Runs `action` for the project at `root`. Called off the main thread.
    static func run(_ action: String, root: String, body: [String: Any]) -> Any {
        switch action {
        case "detect":
            return detect(root: root)
        case "supabaseProjects":
            return cached("sbp", ttl: 120) { cli(["supabase", "projects", "list", "-o", "json"], in: root) }
        case "supabaseSchema", "supabaseMigrations", "supabaseStats":
            guard let ref = body["ref"] as? String, isRef(ref) else { return ["error": "Unknown Supabase project"] }
            let sql = action == "supabaseSchema" ? schemaSQL : action == "supabaseMigrations" ? migrationsSQL : statsSQL
            return cached("\(action):\(ref)", ttl: 25) { supabaseQuery(ref: ref, sql: sql) }
        case "supabaseFunctions":
            guard let ref = body["ref"] as? String, isRef(ref) else { return ["error": "Unknown Supabase project"] }
            return cached("sbf:\(ref)", ttl: 60) {
                cli(["supabase", "functions", "list", "--project-ref", ref, "-o", "json"], in: root)
            }
        case "vercelDeploys":
            guard let dir = inside(root, body["dir"]) else { return ["error": "Outside the project"] }
            // Always name the linked project: without it, `vercel list` returns the whole
            // team's recent deployments, i.e. other projects'.
            guard let project = vercelProject(dir) else { return ["error": "This folder isn't linked to a Vercel project"] }
            return cached("vd:\(dir)", ttl: 25) {
                let result = cli(["vercel", "list", project, "--format", "json", "--yes"], in: dir)
                if let error = (result as? [String: Any])?["error"] as? String, error.contains("not a valid project name") {
                    return ["error": "The Vercel project “\(project)” this folder is linked to no longer exists", "stale": true]
                }
                return result
            }
        case "wrangler":
            guard let dir = inside(root, body["dir"]), let what = body["what"] as? String,
                  let args = wranglerArgs[what] else { return ["error": "Unknown request"] }
            // A specific config (wrangler.consumer.jsonc…) in that folder, by plain file name.
            var extra: [String] = []
            if let config = body["config"] as? String {
                guard config.range(of: #"^wrangler(\.[\w-]+)?\.(toml|jsonc?)$"#, options: .regularExpression) != nil,
                      FileManager.default.fileExists(atPath: "\(dir)/\(config)") else { return ["error": "Unknown config"] }
                if ["deployments", "d1Schema", "d1Migrations"].contains(what) { extra += ["--config", config] }
            }
            // A named environment (env.production…) in that config.
            if let env = body["env"] as? String, !env.isEmpty {
                guard isName(env) else { return ["error": "Unknown environment"] }
                extra += ["--env", env]
            }
            // D1 requests name the database; the SQL is fixed here, read-only.
            var command = args
            if what == "d1Schema" || what == "d1Migrations" {
                guard let database = body["database"] as? String, isName(database) else { return ["error": "Unknown database"] }
                command = what == "d1Schema"
                    ? ["d1", "execute", database, "--remote", "--json", "--command",
                       "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%'"]
                    : ["d1", "migrations", "list", database, "--remote"]
            }
            guard let wrangler = wranglerCommand() else { return ["error": "wrangler isn't installed", "missing": "wrangler"] }
            return cached("w:\(what):\(dir):\(extra.joined(separator: ",")):\(command.joined(separator: " "))", ttl: 30) {
                cli(wrangler + command + extra, in: dir)
            }
        case "refs":
            let strings = (body["strings"] as? [String] ?? []).filter { !$0.isEmpty && $0.count < 200 }.prefix(150)
            return refs(Array(strings), root: root)
        case "gitState":
            return gitState(root: root)
        case "openURL":
            guard let raw = body["url"] as? String, let url = URL(string: raw), url.scheme == "https", url.host != nil else {
                return ["error": "Not a web address"]
            }
            DispatchQueue.main.async {
                // A provider's own pages open straight away. Anything else (a custom domain
                // from the project's config files) is shown in full first, since the files
                // may come from anyone.
                guard isDashboard(url) || confirmOpening(url) else { return }
                NSWorkspace.shared.open(url)
            }
            return true
        default:
            return ["error": "Unknown request"]
        }
    }

    // MARK: Detecting what a project uses (local files only)

    /// The project's env variable names (never their values), the services those point at,
    /// and which CLIs are installed. The page reads the rest (config files) itself.
    private static func detect(root: String) -> [String: Any] {
        var envFiles: [[String: Any]] = []
        var services: [String: [String: Any]] = [:]
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        // Env files at the top level and one level down (monorepo apps).
        var candidates = names.filter(isEnvFile).map { $0 }
        for dir in names where !dir.hasPrefix(".") && !["node_modules", "dist", "build"].contains(dir) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: "\(root)/\(dir)", isDirectory: &isDir), isDir.boolValue else { continue }
            let inner = (try? fm.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? []
            candidates += inner.filter(isEnvFile).map { "\(dir)/\($0)" }
        }
        for file in candidates.prefix(20) {
            guard let text = try? String(contentsOfFile: "\(root)/\(file)", encoding: .utf8) else { continue }
            var keys: [String] = []
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                var key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("export ") { key.removeFirst(7) }
                guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
                keys.append(key)
                var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let service = service(key: key, value: value) {
                    services[service["id"] as? String ?? key, default: [:]].merge(service) { old, _ in old }
                }
            }
            envFiles.append(["file": file, "keys": keys])
        }
        let tools: [String: Bool] = [
            "supabase": which("supabase") != nil,
            "vercel": which("vercel") != nil,
            "wrangler": which("wrangler") != nil,
            "git": true,
        ]
        return ["envFiles": envFiles, "services": Array(services.values), "tools": tools]
    }

    private static func isEnvFile(_ name: String) -> Bool {
        (name.hasPrefix(".env") || name == ".dev.vars") && !name.hasSuffix(".example") && !name.hasSuffix(".sample")
            && !name.hasSuffix(".template")
    }

    /// What a variable points at, without its secret: a Supabase project ref, a database
    /// host's provider, or just which service a key belongs to.
    private static func service(key: String, value: String) -> [String: Any]? {
        let upper = key.uppercased()
        if upper.contains("SUPABASE_URL"), let host = URL(string: value)?.host, host.hasSuffix(".supabase.co") {
            let ref = String(host.dropLast(".supabase.co".count))
            return isRef(ref) ? ["id": "supabase", "ref": ref, "via": key] : ["id": "supabase", "via": key]
        }
        if upper.contains("SUPABASE") { return ["id": "supabase", "via": key] }
        if upper.contains("DATABASE_URL") || upper.hasSuffix("POSTGRES_URL") || upper.hasSuffix("DB_URL") {
            // Only the host's provider; credentials and the host itself stay here.
            guard let host = URL(string: value)?.host?.lowercased() else { return ["id": "postgres", "via": key] }
            let provider = [("supabase.co", "supabase"), ("supabase.com", "supabase"), ("neon.tech", "neon"),
                            ("psdb.cloud", "planetscale"), ("rlwy.net", "railway"), ("railway", "railway"),
                            ("render.com", "render"), ("amazonaws.com", "aws-rds"), ("localhost", "local"),
                            ("127.0.0.1", "local")].first { host.contains($0.0) }?.1 ?? "postgres"
            var result: [String: Any] = ["id": provider == "supabase" ? "supabase" : "database", "provider": provider, "via": key]
            if provider == "supabase", let match = host.range(of: #"[a-z]{20}"#, options: .regularExpression) {
                result["ref"] = String(host[match])
            }
            if provider == "supabase", let user = URL(string: value)?.user,
               let match = user.range(of: #"[a-z]{20}$"#, options: .regularExpression) {
                result["ref"] = String(user[match])
            }
            return result
        }
        let known: [(String, String)] = [
            ("STRIPE", "stripe"), ("OPENAI", "openai"), ("ANTHROPIC", "anthropic"), ("RESEND", "resend"),
            ("SENDGRID", "sendgrid"), ("UPSTASH", "upstash"), ("REDIS", "redis"), ("CLERK", "clerk"),
            ("FIREBASE", "firebase"), ("SENTRY", "sentry"), ("POSTHOG", "posthog"), ("TWILIO", "twilio"),
            ("CLOUDFLARE", "cloudflare"), ("CF_", "cloudflare"), ("R2_", "cloudflare"), ("VERCEL", "vercel"),
            ("GOOGLE", "google"), ("GITHUB", "github"), ("SLACK", "slack"), ("DISCORD", "discord"),
            ("AWS_", "aws"), ("S3_", "aws"), ("MONGODB", "mongodb"), ("MONGO_", "mongodb"), ("PUSHER", "pusher"),
            ("LEMON", "lemonsqueezy"), ("PAYPAL", "paypal"), ("SHOPIFY", "shopify"), ("DEPOP", "depop"),
            ("EBAY", "ebay"), ("NEXTAUTH", "nextauth"), ("AUTH_SECRET", "auth"), ("GEMINI", "gemini"),
            ("REPLICATE", "replicate"), ("ELEVENLABS", "elevenlabs"), ("MAPBOX", "mapbox"), ("ALGOLIA", "algolia"),
        ]
        if let match = known.first(where: { upper.contains($0.0) }) { return ["id": match.1, "via": key] }
        return nil
    }

    // MARK: Live data from the providers' CLIs

    private static let schemaSQL = """
    select json_build_object(
      'tables', (select coalesce(json_agg(t order by t.name), '[]'::json) from (
        select c.relname as name, c.relrowsecurity as rls, greatest(c.reltuples, 0)::bigint as rows,
          pg_total_relation_size(c.oid) as bytes,
          (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as policies,
          (select coalesce(json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
              'nullable', not a.attnotnull) order by a.attnum), '[]'::json)
             from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped) as columns,
          (select coalesce(json_agg(a.attname), '[]'::json) from pg_index i
             join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
             where i.indrelid = c.oid and i.indisprimary) as pk
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'p')) t),
      'fks', (select coalesce(json_agg(json_build_object(
          'from', cl.relname, 'to', cf.relname,
          'fromCol', (select attname from pg_attribute where attrelid = k.conrelid and attnum = k.conkey[1]),
          'toCol', (select attname from pg_attribute where attrelid = k.confrelid and attnum = k.confkey[1]))), '[]'::json)
        from pg_constraint k join pg_class cl on cl.oid = k.conrelid join pg_class cf on cf.oid = k.confrelid
        where k.contype = 'f' and k.connamespace = 'public'::regnamespace),
      'views', (select coalesce(json_agg(viewname), '[]'::json) from pg_views where schemaname = 'public'),
      'rpc', (select coalesce(json_agg(proname order by proname), '[]'::json) from pg_proc
        where pronamespace = 'public'::regnamespace and prokind = 'f'),
      'buckets', (select coalesce(json_agg(json_build_object('name', name, 'public', public)), '[]'::json) from storage.buckets),
      'users', (select count(*) from auth.users),
      'size', pg_database_size(current_database()),
      'version', current_setting('server_version')
    ) as data
    """

    private static let migrationsSQL = """
    select coalesce(json_agg(json_build_object('version', version, 'name', name) order by version), '[]'::json) as data
    from supabase_migrations.schema_migrations
    """

    private static let statsSQL = """
    select json_build_object(
      'connections', (select count(*) from pg_stat_activity where datname = current_database()),
      'active', (select count(*) from pg_stat_activity where datname = current_database() and state = 'active'),
      'cacheHit', (select round(100 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 1)
                   from pg_stat_database where datname = current_database()),
      'writes', (select coalesce(json_object_agg(relname, n_tup_ins + n_tup_upd + n_tup_del), '{}'::json)
                 from pg_stat_user_tables where schemaname = 'public'),
      'reads', (select coalesce(json_object_agg(relname, coalesce(seq_scan, 0) + coalesce(idx_scan, 0)), '{}'::json)
                from pg_stat_user_tables where schemaname = 'public')
    ) as data
    """

    /// Runs one of the queries above against a Supabase project through the Management API,
    /// via the CLI's own login. The CLI needs a "linked" folder; a private one per project
    /// (holding nothing but the project's ref) keeps the user's repository untouched.
    private static func supabaseQuery(ref: String, sql: String) -> Any {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhosttyEXTREME/supabase/\(ref)")
        let temp = support.appendingPathComponent("supabase/.temp")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try? ref.write(to: temp.appendingPathComponent("project-ref"), atomically: true, encoding: .utf8)
        return cli(["supabase", "db", "query", "--linked", "--agent=no", "-o", "json", "--workdir", support.path, sql],
                   in: support.path)
    }

    private static let wranglerArgs: [String: [String]] = [
        "whoami": ["whoami"],
        "deployments": ["deployments", "list", "--json"],
        "d1": ["d1", "list", "--json"],
        "kv": ["kv", "namespace", "list"],
        "r2": ["r2", "bucket", "list"],
        "d1Schema": [],
        "d1Migrations": [],
    ]

    /// The wrangler installed on this Mac, if any.
    ///
    /// Never the project's own `node_modules/.bin/wrangler`, and never `npx wrangler`, which
    /// would fetch one from the registry the project's `.npmrc` names: opening a folder in
    /// the editor must not run a program that came with it.
    static func wranglerCommand() -> [String]? {
        which("wrangler").map { [$0] }
    }

    /// Searches the project for any of `strings` (fixed text, not patterns).
    private static func refs(_ strings: [String], root: String) -> Any {
        guard !strings.isEmpty else { return [] as [Any] }
        var args = ["grep", "-n", "-I", "-F", "--no-color"]
        for string in strings { args += ["-e", string] }
        args += ["--", ".", ":!node_modules", ":!*.lock", ":!package-lock.json", ":!*.min.js", ":!dist", ":!build",
                 ":!.next", ":!.open-next"]
        // Tracked files and new ones not committed yet (still skipping what .gitignore excludes).
        let result = AgentTools.git(Array(args.prefix(5)) + ["--untracked"] + Array(args.dropFirst(5)), in: root)
        var seen = Set<String>()
        var hits: [[String: Any]] = []
        for line in result.output.split(separator: "\n") {
            guard hits.count < 600, seen.insert(String(line)).inserted else { continue }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { continue }
            let text = String(parts[2].prefix(240))
            hits.append(["path": String(parts[0]), "line": number, "text": text,
                         "match": strings.first { text.contains($0) } ?? ""])
        }
        return hits
    }

    private static func gitState(root: String) -> [String: Any] {
        let head = AgentTools.git(["rev-parse", "HEAD"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = AgentTools.git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = AgentTools.git(["status", "--porcelain"], in: root).output.split(separator: "\n").map(String.init)
        let ahead = AgentTools.git(["rev-list", "--count", "@{upstream}..HEAD"], in: root)
        let committed = Double(AgentTools.git(["log", "-1", "--format=%ct"], in: root).output
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return ["head": head, "branch": branch, "dirty": Array(dirty.prefix(200)), "committed": committed * 1000,
                "ahead": ahead.ok ? Int(ahead.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : -1]
    }

    // MARK: Helpers

    /// The project name in `dir/.vercel/project.json`, if it's a plain name.
    static func vercelProject(_ dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(dir)/.vercel/project.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["projectName"] as? String,
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    /// A plain identifier: an environment or database name. Never starts with "-", so a name
    /// from the project's config can't be read as one of the CLI's options.
    static func isName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    private static func isRef(_ ref: String) -> Bool {
        ref.range(of: #"^[a-z]{20}$"#, options: .regularExpression) != nil
    }

    /// A provider's own page: a dashboard, or a deployment on the provider's own domain.
    static func isDashboard(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let allowed = ["supabase.com", "vercel.com", "dash.cloudflare.com", "console.firebase.google.com",
                       "dashboard.stripe.com", "github.com", "console.neon.tech", "railway.app", "railway.com",
                       "console.upstash.com", "app.planetscale.com", "resend.com", "sentry.io",
                       "vercel.app", "workers.dev", "pages.dev"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Asks before opening an address taken from the project's files.
    @MainActor
    private static func confirmOpening(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open \(url.host ?? "this site") in your browser?"
        alert.informativeText = "This address comes from the project's config files, not from Tellurion:\n\n\(url.absoluteString)"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `path` (relative to `root`, or empty for the root) if it's inside the project.
    private static func inside(_ root: String, _ value: Any?) -> String? {
        let relative = value as? String ?? ""
        let path = ((relative.isEmpty ? root : "\(root)/\(relative)") as NSString).standardizingPath
        return path == root || path.hasPrefix(root + "/") ? path : nil
    }

    private static let searchPath: String = {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Only absolute folders: a relative PATH entry would look inside whatever folder the
    /// app happens to be in.
    private static func which(_ tool: String) -> String? {
        searchPath.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a provider CLI with a time limit. Returns its parsed JSON output, or its text as
    /// `{ text }`, or `{ error }` with what it printed.
    private static func cli(_ argv: [String], in dir: String, timeout: TimeInterval = 45) -> Any {
        guard let first = argv.first else { return ["error": "Nothing to run"] }
        guard let executable = first.hasPrefix("/") ? first : which(first) else {
            return ["error": "\(first) isn't installed", "missing": first]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        env["CI"] = "1"
        env["SUPABASE_TELEMETRY_DISABLED"] = "1"
        // Run as a plain process, not as an agent inside the terminal.
        for key in env.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("CODEX") { env.removeValue(forKey: key) }
        process.environment = EventToken.scrubbed(env)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ["error": "Couldn't run \(first): \(error.localizedDescription)"] }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer.cancel()
        let text = String(decoding: outData, as: UTF8.self)
        let errors = String(decoding: errData, as: UTF8.self)
            .split(separator: "\n").filter { !$0.contains("new version") && !$0.contains("recommend updating") }
            .joined(separator: "\n")
        if process.terminationReason == .uncaughtSignal { return ["error": "\(first) took too long"] }
        if process.terminationStatus != 0 {
            let message = (errors.isEmpty ? text : errors).trimmingCharacters(in: .whitespacesAndNewlines)
            return ["error": String(message.suffix(600)), "status": Int(process.terminationStatus)]
        }
        if let json = parseJSON(text) { return ["json": json] }
        return ["text": String(text.suffix(20000))]
    }

    /// JSON from CLI output that may have a line of chatter before it.
    private static func parseJSON(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return json
        }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return String(trimmed[start...]).data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private static var cache: [String: (Date, Any)] = [:]
    private static let cacheLock = NSLock()

    /// Recent answers are reused, so several views asking at once only run the CLI once.
    private static func cached(_ key: String, ttl: TimeInterval, _ work: () -> Any) -> Any {
        cacheLock.lock()
        if let (time, value) = cache[key], Date().timeIntervalSince(time) < ttl {
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        let value = work()
        cacheLock.lock()
        cache[key] = (Date(), value)
        cacheLock.unlock()
        return value
    }
}
#endif
