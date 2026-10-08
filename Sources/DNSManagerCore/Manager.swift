import Foundation

private struct RestorePoint: Codable {
    var service: String
    var dns: [String]
    var config: String?
    var date: Date
}

public final class Manager {
    public let store: Store
    public init(store: Store = Store()) { self.store = store }
    public var configPath: String {
        if AdminBridge.managedProxy { return AdminBridge.configPath }
        let prefix = Runner.executable("brew").map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? "/opt/homebrew"
        return prefix + "/etc/dnscrypt-proxy.toml"
    }

    public static func parseServices(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }
    public func services() throws -> [String] {
        Self.parseServices(try Runner.checked("/usr/sbin/networksetup", ["-listallnetworkservices"]))
    }
    public func dns(for service: String) throws -> [String] {
        guard try services().contains(service) else { throw ManagerError.message("Choisis un service réseau existant.") }
        let output = try Runner.checked("/usr/sbin/networksetup", ["-getdnsservers", service])
        let lines = output.components(separatedBy: .newlines)
        let addresses = lines.filter { Validation.ip($0) }
        guard !addresses.isEmpty || output.contains("aren't any DNS") || output.contains("aucun") else {
            throw ManagerError.message("Impossible d'interpréter les DNS du service : \(output)")
        }
        return addresses
    }

    public func check(endpoint: String, domain: String) -> CheckResult {
        do {
            guard Validation.domain(domain) else { throw ManagerError.message("Domaine de test invalide.") }
            guard !endpoint.isEmpty, !endpoint.contains(where: { $0.isWhitespace }), !endpoint.hasPrefix("-") else { throw ManagerError.message("Adresse de test invalide.") }
            guard let doggo = Runner.executable("doggo") else { throw ManagerError.message("doggo n'est pas installé.") }
            // Ignore local doggo config as well as environment defaults.
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
            try Data().write(to: empty)
            defer { try? FileManager.default.removeItem(at: empty) }
            let result = try Runner.run(doggo, ["--config", empty.path, "--query", domain, "--type", "A", "--nameserver", endpoint, "--json", "--timeout", "3s", "--search=false"], timeout: 6)
            return Self.parseDoggo(result, title: endpoint)
        } catch { return CheckResult(title: endpoint, ok: false, detail: error.localizedDescription) }
    }
    public static func parseDoggo(_ result: CommandResult, title: String) -> CheckResult {
        guard result.succeeded, let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = object["responses"] as? [[String: Any]] else {
            return CheckResult(title: title, ok: false, detail: result.output.isEmpty ? "Aucune réponse DNS." : result.output)
        }
        let answers = responses.flatMap { $0["answers"] as? [[String: Any]] ?? [] }
        let addresses = answers.compactMap { $0["address"] as? String }.filter { Validation.ip($0) }
        let times = Set(answers.compactMap { $0["rtt"] as? String }).sorted().joined(separator: ", ")
        return CheckResult(title: title, ok: !addresses.isEmpty, detail: addresses.isEmpty ? "Aucune adresse A reçue (nom absent, refus ou filtrage)." : addresses.joined(separator: ", ") + " · " + times)
    }

    public func nativeCheck(domain: String) -> CheckResult {
        do {
            guard Validation.domain(domain) else { throw ManagerError.message("Domaine invalide.") }
            let output = try Runner.checked("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", domain], timeout: 6)
            let ok = output.contains("ip_address:") || output.contains("ipv6_address:")
            return CheckResult(title: "Résolution native macOS", ok: ok, detail: ok ? output : "Aucune adresse reçue.")
        } catch { return CheckResult(title: "Résolution native macOS", ok: false, detail: error.localizedDescription) }
    }

    public func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        do {
            let settings = try store.load()
            snapshot.services = (try? services()) ?? []
            snapshot.selectedService = settings.service
            let connections = (try? connections()) ?? []
            snapshot.connections = connections
            snapshot.serviceDisplayName = connections.first { $0.service == settings.service }?.label ?? settings.service
            if !settings.service.isEmpty {
                do { snapshot.manualDNS = try dns(for: settings.service) }
                catch { snapshot.checks.append(CheckResult(title: "Service réseau", ok: false, detail: error.localizedDescription)) }
            }
            snapshot.systemDNS = (try? Runner.checked("/usr/sbin/scutil", ["--dns"])) ?? "Lecture DNS indisponible."
            snapshot.vpns = vpnConnections()
            snapshot.networkSummary = networkSummary(connections: connections, vpns: snapshot.vpns, systemDNS: snapshot.systemDNS)
            snapshot.versions = ["doggo", "dnscrypt-proxy", "brew"].map { name in
                let executable = name == "dnscrypt-proxy" && AdminBridge.managedProxy ? AdminBridge.proxyPath : Runner.executable(name)
                guard let path = executable else { return "\(name) : absent" }
                let argument = name == "dnscrypt-proxy" ? "-version" : "--version"
                return "\(name) : " + ((try? Runner.checked(path, [argument]))?.components(separatedBy: .newlines).first ?? "version inconnue")
            }.joined(separator: "\n")
            let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            snapshot.proxy = text.components(separatedBy: .newlines).first { $0.hasPrefix("server_names") } ?? "Configuration du proxy absente"
            snapshot.checks += [nativeCheck(domain: settings.testDomain), check(endpoint: "127.0.0.1", domain: settings.testDomain), check(endpoint: "[::1]", domain: settings.testDomain)]
            if !settings.lanResolver.isEmpty { snapshot.checks.append(check(endpoint: settings.lanResolver.contains(":") ? "[\(settings.lanResolver)]" : settings.lanResolver, domain: settings.testDomain)) }
            let nativeOK = snapshot.checks.first { $0.title == "Résolution native macOS" }?.ok == true
            // A healthy system is still orange if its manually selected DNS fail.
            let manualChecks = snapshot.manualDNS.map { check(endpoint: $0.contains(":") ? "[\($0)]" : $0, domain: settings.testDomain) }
            snapshot.checks += manualChecks.filter { check in !snapshot.checks.contains { $0.title == check.title } }
            snapshot.health = !nativeOK ? .red : (settings.service.isEmpty || !snapshot.services.contains(settings.service) || manualChecks.contains { !$0.ok } ? .orange : .green)
        } catch { snapshot.checks.append(CheckResult(title: "Configuration", ok: false, detail: error.localizedDescription)) }
        return snapshot
    }

    private func capture(service: String) throws -> RestorePoint {
        guard try connections().contains(where: { $0.service == service }) else { throw ManagerError.message("Choisis LAN ou Wi-Fi dans Configuration. Les DNS imposés par un VPN se règlent dans son client.") }
        let point = RestorePoint(service: service, dns: try dns(for: service), config: try? String(contentsOfFile: configPath, encoding: .utf8), date: Date())
        return point
    }
    private func setDNS(service: String, addresses: [String]) throws {
        guard try services().contains(service), addresses.allSatisfy(Validation.ip) else { throw ManagerError.message("Service ou adresses DNS invalides.") }
        let arguments = ["/usr/sbin/networksetup", "-setdnsservers", service] + (addresses.isEmpty ? ["empty"] : addresses)
        _ = try Runner.privileged("set -e; " + arguments.map(Runner.shellQuote).joined(separator: " ") + "; /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        guard try dns(for: service) == addresses else { throw ManagerError.message("Les DNS relus ne correspondent pas aux réglages demandés.") }
    }
    public func apply(mode: DNSMode) throws -> String {
        let settings = try store.load()
        let point = try capture(service: settings.service)
        let addresses: [String]
        switch mode {
        case .automatic: addresses = []
        case .local:
            for endpoint in ["127.0.0.1", "[::1]"] {
                let result = check(endpoint: endpoint, domain: settings.testDomain)
                guard result.ok else { throw ManagerError.message("Proxy non opérationnel : \(result.detail)") }
            }
            addresses = ["127.0.0.1", "::1"]
        }
        try store.write(point, to: store.backup)
        if AdminBridge.installed {
            return try AdminBridge.run(AdminRequest(action: "mode", service: settings.service, mode: mode == .local ? "local" : "automatic", domain: settings.testDomain))
        }
        do {
            try setDNS(service: settings.service, addresses: addresses)
            guard nativeCheck(domain: settings.testDomain).ok else { throw ManagerError.message("La résolution macOS échoue après le changement.") }
            return "Mode \(mode.rawValue) appliqué à \(settings.service). Réglages précédents sauvegardés."
        } catch {
            let reason = error.localizedDescription
            if (try? dns(for: point.service)) == point.dns {
                throw ManagerError.message("\(reason)\nLes DNS précédents sont inchangés.")
            }
            do { try setDNS(service: point.service, addresses: point.dns) }
            catch { throw ManagerError.message("\(reason)\nRestauration échouée : \(error.localizedDescription). Utilise Restaurer ou repasse en Automatique.") }
            throw ManagerError.message("\(reason)\nLes DNS précédents ont été restaurés.")
        }
    }

    public static func configuredTOML(_ original: String, resolver: Resolver) throws -> String {
        try resolver.validate()
        guard resolver.canActivate else { throw ManagerError.message("Activation requiert un stamp DNSCrypt ou DoH valide. DoT/DoQ restent disponibles pour les tests avec doggo.") }
        let managedID = "dnsmanager-" + resolver.id
        var text = original.isEmpty ? "listen_addresses = ['127.0.0.1:53', '[::1]:53']\nbootstrap_resolvers = ['1.1.1.1:53', '9.9.9.9:53']\ncache = true\n" : original
        let serverPattern = "(?m)^server_names\\s*=.*$"
        if text.range(of: serverPattern, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: serverPattern, with: "server_names = ['\(managedID)']", options: .regularExpression)
        } else { text = "server_names = ['\(managedID)']\n" + text }
        for key in ["doh_servers", "dnscrypt_servers"] {
            text = text.replacingOccurrences(of: "(?m)^\(key)\\s*=.*$", with: "\(key) = true", options: .regularExpression)
        }
        // Each managed static block is replaced in place; unrelated sections are preserved.
        let block = "[static.'\(managedID)']"
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []; var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == block { skipping = true; continue }
            if skipping && trimmed.hasPrefix("[") { skipping = false }
            if !skipping { result.append(line) }
        }
        return result.joined(separator: "\n") + "\n\(block)\nstamp = '\(resolver.activationStamp)'\n"
    }

    private func installConfigAndDNS(_ text: String, service: String, addresses: [String], testLocal: Bool) throws {
        guard try connections().contains(where: { $0.service == service }), addresses.allSatisfy(Validation.ip) else {
            throw ManagerError.message("Connexion ou adresses DNS invalides.")
        }
        guard let proxy = AdminBridge.managedProxy ? AdminBridge.proxyPath : Runner.executable("dnscrypt-proxy") else { throw ManagerError.message("dnscrypt-proxy absent.") }
        let previousDNS = try dns(for: service)
        let domain = try store.load().testDomain
        guard Validation.domain(domain) else { throw ManagerError.message("Domaine de test invalide.") }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try text.write(to: stage, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stage) }
        _ = try Runner.checked(proxy, ["-config", stage.path, "-check"], timeout: 20)
        let backup = configPath + ".dnsmanager-" + UUID().uuidString + ".bak"
        guard FileManager.default.fileExists(atPath: configPath) else { throw ManagerError.message("Configuration initiale du proxy absente.") }
        let brew = Runner.executable("brew")
        let script = try Self.configurationTransaction(config: configPath, stage: stage.path, backup: backup, service: service, addresses: addresses, previousDNS: previousDNS, domain: domain, testLocal: testLocal, brew: brew)
        // A single authorization runs the entire operation, including rollback.
        _ = try Runner.privileged(script)
        guard try dns(for: service) == addresses else { throw ManagerError.message("Les DNS relus ne correspondent pas aux réglages demandés.") }
    }

    public static func configurationTransaction(config: String, stage: String, backup: String, service: String, addresses: [String], previousDNS: [String], domain: String, testLocal: Bool, brew: String?) throws -> String {
        guard addresses.allSatisfy(Validation.ip), previousDNS.allSatisfy(Validation.ip), Validation.domain(domain) else { throw ManagerError.message("Paramètres de transaction DNS invalides.") }
        func command(_ path: String, _ args: [String]) -> String { ([path] + args).map(Runner.shellQuote).joined(separator: " ") }
        let oldDNS = command("/usr/sbin/networksetup", ["-setdnsservers", service] + (previousDNS.isEmpty ? ["empty"] : previousDNS))
        let newDNS = command("/usr/sbin/networksetup", ["-setdnsservers", service] + (addresses.isEmpty ? ["empty"] : addresses))
        let restart = "/bin/launchctl kickstart -k system/sh.brew.dnscrypt-proxy"
        let start = brew.map { command($0, ["services", "start", "dnscrypt-proxy"]) } ?? "echo 'Homebrew absent : démarrage du service impossible.' >&2; exit 1"
        let flush = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        let localChecks = testLocal ? ["127.0.0.1", "::1"].map { address in
            "answer=$(" + command("/usr/bin/dig", ["@" + address, domain, "A", "+short", "+time=3", "+tries=1"]) + "); printf '%s\\n' \"$answer\" | /usr/bin/grep -Eq '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' || { echo 'Le proxy local ne répond pas correctement.' >&2; exit 1; }"
        }.joined(separator: "\n") : ""
        return """
        set -e
        \(command("/bin/cp", ["-p", config, backup]))
        rollback() {
            rc=$?
            trap - EXIT
            if [ "$rc" -ne 0 ]; then
                failed=0
                \(command("/bin/cp", ["-p", backup, config])) || failed=1
                \(restart) || failed=1
                \(oldDNS) || failed=1
                \(flush) || failed=1
                if [ "$failed" -eq 0 ]; then echo 'Configuration et DNS précédents restaurés.' >&2; else echo 'Restauration incomplète : utilise Restaurer dans le TUI.' >&2; fi
            fi
            exit "$rc"
        }
        trap rollback EXIT
        \(command("/usr/bin/install", ["-m", "644", "-o", "root", "-g", "wheel", stage, config]))
        if /bin/launchctl print system/sh.brew.dnscrypt-proxy >/dev/null 2>&1; then
            \(restart)
        else
            \(start)
        fi
        /bin/sleep 1
        \(localChecks)
        \(newDNS)
        \(flush)
        native=$(\(command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", domain])))
        printf '%s\\n' "$native" | /usr/bin/grep -Eq '^[[:space:]]*(ip_address|ipv6_address):' || { echo 'La résolution macOS échoue après le changement.' >&2; exit 1; }
        trap - EXIT
        """
    }

    public func activate(_ resolver: Resolver) throws -> String {
        let settings = try store.load()
        let point = try capture(service: settings.service)
        guard point.config != nil else { throw ManagerError.message("Configuration du proxy absente. Installe dnscrypt-proxy via Maintenance pour obtenir sa configuration initiale.") }
        let tested = check(endpoint: resolver.activationStamp, domain: settings.testDomain)
        guard resolver.canActivate, tested.ok else { throw ManagerError.message("Résolveur non activable ou test échoué : \(tested.detail)") }
        let text = try Self.configuredTOML(point.config ?? "", resolver: resolver)
        try store.write(point, to: store.backup)
        if AdminBridge.installed {
            return try AdminBridge.run(AdminRequest(action: "activate", service: settings.service, resolver: resolver, domain: settings.testDomain))
        }
        do {
            try installConfigAndDNS(text, service: settings.service, addresses: ["127.0.0.1", "::1"], testLocal: true)
            return "\(resolver.name) activé et testé. Configuration précédente sauvegardée."
        } catch {
            let reason = error.localizedDescription
            if (try? String(contentsOfFile: configPath, encoding: .utf8)) == point.config,
               (try? dns(for: point.service)) == point.dns {
                throw ManagerError.message("\(reason)\nConfiguration et DNS précédents conservés ou restaurés.")
            }
            throw ManagerError.message("\(reason)\nLes réglages précédents ne sont pas complètement rétablis. Utilise Restaurer dans le TUI.")
        }
    }
    private func restore(_ point: RestorePoint) throws {
        if let config = point.config {
            try installConfigAndDNS(config, service: point.service, addresses: point.dns, testLocal: point.dns.contains("127.0.0.1"))
            return
        }
        else if FileManager.default.fileExists(atPath: configPath) {
            throw ManagerError.message("La configuration était absente avant l'opération. Restaure les DNS via le mode Automatique et examine le fichier du proxy.")
        }
        try setDNS(service: point.service, addresses: point.dns)
    }
    public func restore() throws -> String {
        if AdminBridge.installed { return try AdminBridge.run(AdminRequest(action: "restore", domain: try store.load().testDomain)) }
        guard FileManager.default.fileExists(atPath: store.backup.path) else { throw ManagerError.message("Aucun point de restauration.") }
        let point = try JSONDecoder().decode(RestorePoint.self, from: Data(contentsOf: store.backup))
        try restore(point)
        return "Configuration et DNS de \(point.service) restaurés (\(point.date.formatted()))."
    }
    public func restart() throws -> String {
        if AdminBridge.installed { return try AdminBridge.run(AdminRequest(action: "restart")) }
        _ = try Runner.privileged("/bin/launchctl kickstart -k system/sh.brew.dnscrypt-proxy")
        Thread.sleep(forTimeInterval: 1)
        let output = try Runner.checked("/bin/launchctl", ["print", "system/sh.brew.dnscrypt-proxy"])
        guard output.contains("state = running") else { throw ManagerError.message("Le service n'est pas démarré.\n\(output)") }
        return "Service dnscrypt-proxy redémarré."
    }
    public func flush() throws -> String {
        if AdminBridge.installed { return try AdminBridge.run(AdminRequest(action: "flush")) }
        _ = try Runner.privileged("set -e; /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        return "Cache DNS macOS vidé."
    }
    public func maintenance(update: Bool) throws -> String {
        guard let brew = Runner.executable("brew") else { throw ManagerError.message("Installe Homebrew depuis https://brew.sh puis relance l'app.") }
        return try Runner.checked(brew, [update ? "upgrade" : "install", "doggo", "dnscrypt-proxy"], timeout: 900)
    }
    public func startService() throws -> String {
        if AdminBridge.installed { return try AdminBridge.run(AdminRequest(action: "start")) }
        if AdminBridge.managedProxy {
            _ = try Runner.privileged("if /bin/launchctl print system/sh.brew.dnscrypt-proxy >/dev/null 2>&1; then /bin/launchctl kickstart -k system/sh.brew.dnscrypt-proxy; else /bin/launchctl bootstrap system /Library/LaunchDaemons/sh.brew.dnscrypt-proxy.plist; fi")
            return "Service DNSCrypt protégé démarré."
        }
        guard let brew = Runner.executable("brew"), Runner.executable("dnscrypt-proxy") != nil else { throw ManagerError.message("Installe d'abord les outils.") }
        guard FileManager.default.fileExists(atPath: configPath) else { throw ManagerError.message("Configuration dnscrypt-proxy absente. Installe les outils puis configure un résolveur.") }
        _ = try Runner.privileged(Runner.shellQuote(brew) + " services start dnscrypt-proxy")
        return "Démarrage au niveau système demandé. Lance les contrôles pour vérifier le proxy."
    }
    public func logs() throws -> String {
        try Runner.checked("/bin/launchctl", ["print", "system/sh.brew.dnscrypt-proxy"])
    }
    public func optimizationReport() throws -> String {
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        func value(_ key: String) -> String {
            text.components(separatedBy: .newlines).first { $0.range(of: "^\(key)\\s*=", options: .regularExpression) != nil }?.components(separatedBy: "=").dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces) ?? "non explicite (valeur du moteur)"
        }
        return """
        AUDIT CACHE / QUAD9 — lecture seule

        Cache : \(value("cache"))
        Capacité (entrées) : \(value("cache_size"))
        TTL minimum : \(value("cache_min_ttl"))
        TTL maximum : \(value("cache_max_ttl"))
        \(value("server_names"))

        Quad9 recommande un cache et la redondance de ses serveurs.
        Éviter de plafonner systématiquement le cache à 30–60 secondes sans besoin mesuré.
        La QNAME minimisation n'a pas d'option dédiée dans dnscrypt-proxy.
        require_dnssec est un filtre de sélection des serveurs, pas un réglage de validation locale.
        Le service Quad9 « sans filtrage » ne bloque pas les domaines malveillants.
        ::1 est l'IPv6 local ; cela ne prouve pas une connectivité IPv6 Internet.

        Sources : docs.quad9.net et configuration officielle DNSCrypt.
        Aucun réglage n'a été changé par cet audit.
        """
    }
}
