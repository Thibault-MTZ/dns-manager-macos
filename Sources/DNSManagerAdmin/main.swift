import Foundation
import Darwin
import DNSManagerCore

private struct Installation: Codable { var uid: UInt32; var prefix: String }
private struct Recovery: Codable { var service: String; var dns: [String]; var config: String? }

private final class Administrator {
    let installation: Installation
    let directory = URL(fileURLWithPath: AdminBridge.privatePath)
    var config: String { AdminBridge.configPath }
    let manager = Manager()
    var recovery: URL { directory.appendingPathComponent("restore.json") }

    init() throws {
        guard geteuid() == 0 else { throw ManagerError.message("Ce composant doit être appelé par l'autorisation DNS Manager.") }
        let path = directory.appendingPathComponent("installation.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw ManagerError.message("Installation administrateur non protégée.") }
        installation = try JSONDecoder().decode(Installation.self, from: Data(contentsOf: path))
        guard let caller = ProcessInfo.processInfo.environment["SUDO_UID"], UInt32(caller) == installation.uid else { throw ManagerError.message("Ce compte n'est pas autorisé à utiliser DNS Manager Admin.") }
        guard ["/opt/homebrew", "/usr/local"].contains(installation.prefix) else { throw ManagerError.message("Préfixe d'installation interdit.") }
    }
    func save(_ value: Recovery) throws {
        try JSONEncoder().encode(value).write(to: recovery, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recovery.path)
    }
    func capture(_ service: String) throws -> Recovery {
        guard try manager.connections().contains(where: { $0.service == service }) else { throw ManagerError.message("Seules les connexions LAN et Wi-Fi sont autorisées.") }
        return Recovery(service: service, dns: try manager.dns(for: service), config: try? String(contentsOfFile: config, encoding: .utf8))
    }
    func dnsCommand(_ service: String, _ addresses: [String]) throws -> String {
        guard addresses.allSatisfy(Validation.ip) else { throw ManagerError.message("Adresses DNS invalides.") }
        return (["/usr/sbin/networksetup", "-setdnsservers", service] + (addresses.isEmpty ? ["empty"] : addresses)).map(Runner.shellQuote).joined(separator: " ")
    }
    func nativeTest(_ domain: String) -> String {
        "native=$(/usr/bin/dscacheutil -q host -a name \(Runner.shellQuote(domain))); printf '%s\\n' \"$native\" | /usr/bin/grep -Eq '^[[:space:]]*(ip_address|ipv6_address):'"
    }
    func localTests(_ domain: String) -> String {
        ["127.0.0.1", "::1"].map { ip in
            "answer=$(/usr/bin/dig \(Runner.shellQuote("@" + ip)) \(Runner.shellQuote(domain)) A +short +time=3 +tries=1); printf '%s\\n' \"$answer\" | /usr/bin/grep -Eq '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$'"
        }.joined(separator: "\n")
    }
    func setDNS(_ point: Recovery, addresses: [String], domain: String, savePoint: Bool) throws -> String {
        if savePoint { try save(point) }
        let old = try dnsCommand(point.service, point.dns), new = try dnsCommand(point.service, addresses)
        let flush = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        let script = """
        set -e
        rollback() { rc=$?; trap - EXIT; if [ "$rc" -ne 0 ]; then \(old); \(flush); echo 'DNS précédents restaurés.' >&2; fi; exit "$rc"; }
        trap rollback EXIT
        \(addresses.contains("127.0.0.1") ? localTests(domain) : "")
        \(new)
        \(flush)
        \(nativeTest(domain))
        trap - EXIT
        """
        _ = try Runner.checked("/bin/sh", ["-c", script], timeout: 60)
        return "DNS appliqués à la connexion sélectionnée, sans nouvelle demande de mot de passe."
    }
    func installConfig(_ text: String, service: String, dns: [String], domain: String) throws -> String {
        guard text.utf8.count <= 1_048_576 else { throw ManagerError.message("Configuration trop volumineuse.") }
        let current = try capture(service)
        let stage = directory.appendingPathComponent("stage-" + UUID().uuidString + ".toml")
        try text.write(to: stage, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        defer { try? FileManager.default.removeItem(at: stage) }
        _ = try Runner.checked(AdminBridge.proxyPath, ["-config", stage.path, "-check"], timeout: 20)
        let script = try Manager.configurationTransaction(config: config, stage: stage.path, backup: directory.appendingPathComponent("config-" + UUID().uuidString + ".bak").path, service: service, addresses: dns, previousDNS: current.dns, domain: domain, testLocal: dns.contains("127.0.0.1"), brew: nil)
        _ = try Runner.checked("/bin/sh", ["-c", script], timeout: 120)
        return "Configuration du proxy et DNS appliqués sans nouvelle demande de mot de passe."
    }
    func trustedService() throws {
        let path = "/Library/LaunchDaemons/sh.brew.dnscrypt-proxy.plist"
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw ManagerError.message("Le service DNSCrypt système n'est pas protégé.") }
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == [AdminBridge.proxyPath, "-config", config] else { throw ManagerError.message("Le service DNSCrypt utilise une commande inattendue.") }
    }
    func run(_ request: AdminRequest) throws -> String {
        try request.validate()
        let domain = request.domain ?? "example.com"
        switch request.action {
        case "status": return "Autorisation DNS durable active pour le compte UID \(installation.uid)."
        case "uninstall":
            try FileManager.default.removeItem(atPath: AdminBridge.rulePath)
            try FileManager.default.removeItem(atPath: AdminBridge.helperPath)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("installation.json"))
            return "Autorisation durable retirée. Les DNS et le service DNSCrypt restent inchangés."
        case "flush":
            _ = try Runner.checked("/usr/bin/dscacheutil", ["-flushcache"])
            _ = try Runner.checked("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            return "Cache DNS vidé."
        case "restart", "start":
            try trustedService()
            if request.action == "start", !(try Runner.run("/bin/launchctl", ["print", "system/sh.brew.dnscrypt-proxy"]).succeeded) {
                _ = try Runner.checked("/bin/launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/sh.brew.dnscrypt-proxy.plist"])
            } else { _ = try Runner.checked("/bin/launchctl", ["kickstart", "-k", "system/sh.brew.dnscrypt-proxy"]) }
            return "Service DNSCrypt démarré / redémarré."
        case "mode":
            let point = try capture(request.service!)
            return try setDNS(point, addresses: request.mode == "local" ? ["127.0.0.1", "::1"] : [], domain: domain, savePoint: true)
        case "activate":
            try trustedService()
            let point = try capture(request.service!)
            guard let original = point.config else { throw ManagerError.message("Configuration DNSCrypt absente.") }
            let text = try Manager.configuredTOML(original, resolver: request.resolver!)
            try save(point)
            return try installConfig(text, service: point.service, dns: ["127.0.0.1", "::1"], domain: domain)
        case "restore":
            let point = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: recovery))
            _ = try capture(point.service)
            if let text = point.config { try trustedService(); return try installConfig(text, service: point.service, dns: point.dns, domain: domain) }
            return try setDNS(capture(point.service), addresses: point.dns, domain: domain, savePoint: false)
        default: throw ManagerError.message("Action interdite.")
        }
    }
}

do {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].utf8.count <= 8192 else { throw ManagerError.message("Une requête DNS structurée est requise.") }
    let request = try JSONDecoder().decode(AdminRequest.self, from: Data(CommandLine.arguments[1].utf8))
    try request.validate()
    if geteuid() == 0 { setenv("TMPDIR", AdminBridge.privatePath, 1); unsetenv("DNS_MANAGER_DATA_DIR") }
    let administrator = try Administrator()
    guard FileManager.default.changeCurrentDirectoryPath(AdminBridge.statePath) else { throw ManagerError.message("Dossier administrateur indisponible.") }
    let descriptor = open(AdminBridge.privatePath + "/operation.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw ManagerError.message("Verrou administrateur indisponible.") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ManagerError.message("Une opération DNS est déjà en cours.") }
    defer { flock(descriptor, LOCK_UN) }
    print(try administrator.run(request))
} catch { fputs("Erreur : \(error.localizedDescription)\n", stderr); exit(1) }
