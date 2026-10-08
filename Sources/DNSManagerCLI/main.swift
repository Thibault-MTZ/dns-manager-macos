import Foundation
import Darwin
import DNSManagerCore

final class TUI {
    let manager = Manager()
    var settings: Settings
    var connections: [NetworkConnection] = []
    var serviceLabel: String { settings.service.isEmpty ? "à choisir" : connections.first { $0.service == settings.service }?.label ?? settings.service }
    let interactive = isatty(STDIN_FILENO) == 1
    init() throws { settings = try manager.store.load() }
    func input(_ prompt: String, default value: String = "") -> String {
        print(prompt + (value.isEmpty ? " : " : " [\(value)] : "), terminator: "")
        fflush(stdout)
        return readLine().map { $0.isEmpty ? value : $0 } ?? ""
    }
    func pause() { if interactive { _ = input("Entrée pour continuer") } }
    func title(_ subtitle: String) {
        if interactive { print("\u{001B}[2J\u{001B}[H", terminator: "") }
        print("╭──────────────────────────────────────────────────╮")
        print("│  DNS MANAGER · macOS                             │")
        print("╰──────────────────────────────────────────────────╯")
        print("\n\(subtitle)\n")
    }
    func choose(_ options: [String]) -> Int? {
        for (index, option) in options.enumerated() { print("  \(index + 1). \(option)") }
        print("  0. Retour / Quitter\n")
        while let line = readLinePrompt("Choix › ") {
            if line == "0" || line.lowercased() == "q" { return nil }
            if let number = Int(line), number > 0, number <= options.count { return number - 1 }
            print("Saisis un numéro de 0 à \(options.count).")
        }
        return nil
    }
    func readLinePrompt(_ text: String) -> String? { print(text, terminator: ""); fflush(stdout); return readLine() }
    func perform(_ action: () throws -> String) {
        do { print("\n✓ " + (try action())) }
        catch { print("\n✗ " + error.localizedDescription) }
        pause()
    }
    func confirmed(_ message: String) -> Bool { input(message + " — taper OUI") == "OUI" }
    func save() throws { try manager.store.save(settings) }
    func selectService() throws {
        connections = try manager.connections()
        title("Choisir la connexion du Mac")
        print("Ce choix ne change pas les DNS. Les VPN sont affichés séparément dans l'état réseau.\n")
        guard !connections.isEmpty else { throw ManagerError.message("Aucune connexion LAN ou Wi-Fi disponible.") }
        if let choice = choose(connections.map { $0.label + ($0.active ? " · connexion utilisée" : "") }) { settings.service = connections[choice].service; try save() }
    }
    func requireService() throws {
        connections = try manager.connections()
        if !connections.contains(where: { $0.service == settings.service }) { try selectService() }
        guard !settings.service.isEmpty else { throw ManagerError.message("Choisis d'abord un service réseau.") }
    }
    func showStatus(verbose: Bool = true) {
        print("Contrôles en cours…")
        let snapshot = manager.snapshot()
        let symbol = snapshot.health == .green ? "🟢" : snapshot.health == .red ? "🔴" : "🟠"
        print("\n\(symbol) \(snapshot.health.rawValue)")
        print("Connexion choisie : \(snapshot.serviceDisplayName.isEmpty ? "à choisir dans Configuration" : snapshot.serviceDisplayName)")
        print("\n\(snapshot.networkSummary)\n")
        print("DNS manuels : \(snapshot.manualDNS.isEmpty ? "automatiques ou non lus" : snapshot.manualDNS.joined(separator: ", "))")
        print("Proxy : \(snapshot.proxy)\n\n\(snapshot.versions)\n")
        for check in snapshot.checks {
            print("\(check.ok ? "✓" : "✗") \(check.title)\n  \(check.detail.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        print("\nLe voyant décrit la résolution macOS et les DNS manuels du service choisi.")
        print("Il ne prouve pas le chiffrement de tous les logiciels ; les tests directs sont indépendants.")
        if verbose { print("\n── Règles DNS effectives (VPN et domaines inclus) ──\n\(snapshot.systemDNS)") }
    }
    func modes() {
        title("Modes DNS · connexion : \(serviceLabel)")
        print("Automatique : les DNS fournis par le réseau.\nDNS local : les requêtes passent par dnscrypt-proxy (127.0.0.1 et ::1).\n")
        guard let choice = choose(["Automatique (par défaut)", "Via DNS local (DNSCrypt)"]) else { return }
        let mode: DNSMode = choice == 0 ? .automatic : .local
        perform {
            try requireService()
            guard confirmed("Appliquer \(mode.rawValue) à \(serviceLabel)") else { return "Annulé." }
            return try manager.apply(mode: mode)
        }
    }
    func resolverEditor(_ existing: Resolver? = nil) throws {
        let id = input("Identifiant (lettres, chiffres, tirets)", default: existing?.id ?? "")
        let name = input("Nom", default: existing?.name ?? "")
        let endpoint = input("Adresse de test (IP, https://, tls://, quic:// ou sdns://)", default: existing?.endpoint ?? "")
        let enteredStamp = input("Stamp sdns:// (automatique pour HTTPS ; facultatif ; '-' pour effacer)", default: existing?.stamp ?? "")
        let serverIP = input("IP du serveur HTTPS (facultatif)", default: existing?.stampAddress ?? "")
        var stamp = enteredStamp == "-" ? "" : enteredStamp
        if !serverIP.isEmpty {
            guard let generated = Resolver.dohStamp(endpoint, address: serverIP) else { throw ManagerError.message("URL HTTPS et IP valide requises.") }
            stamp = generated
        }
        let resolver = Resolver(id: id, name: name, endpoint: endpoint, stamp: stamp)
        try resolver.validate()
        guard !settings.resolvers.contains(where: { $0.id == id && $0.id != existing?.id }) else { throw ManagerError.message("Cet identifiant existe déjà.") }
        if let existing, let index = settings.resolvers.firstIndex(where: { $0.id == existing.id }) { settings.resolvers[index] = resolver }
        else { settings.resolvers.append(resolver) }
        try save()
    }
    func resolvers() {
        while true {
            title("Résolveurs · tests DoH / DoT / DoQ / DNSCrypt")
            let labels = settings.resolvers.map { "\($0.name) · \($0.canActivate ? "activable" : "test seulement")" } + ["Ajouter un résolveur"]
            guard let choice = choose(labels) else { return }
            if choice == settings.resolvers.count { perform { try resolverEditor(); return "Résolveur ajouté." }; continue }
            let resolver = settings.resolvers[choice]
            title("\(resolver.name)\n\(resolver.endpoint)")
            guard let action = choose(["Tester avec doggo", "Activer dans le proxy et utiliser le DNS local", "Modifier", "Supprimer de la liste"]) else { continue }
            switch action {
            case 0:
                let check = manager.check(endpoint: resolver.endpoint, domain: settings.testDomain)
                print("\n\(check.ok ? "✓" : "✗") \(check.detail)"); pause()
            case 1:
                perform {
                    guard resolver.canActivate else { throw ManagerError.message("Utilise une URL HTTPS (DoH) ou un stamp DoH/DNSCrypt valide pour l'activer. Une IP LAN simple et DoT/DoQ sont des cibles de test.") }
                    try requireService()
                    guard confirmed("Activer \(resolver.name) sur \(serviceLabel)") else { return "Annulé." }
                    return try manager.activate(resolver)
                }
            case 2: perform { try resolverEditor(resolver); return "Résolveur modifié." }
            default:
                if confirmed("Supprimer \(resolver.name) de la liste (le proxy actif reste inchangé)") {
                    perform { settings.resolvers.removeAll { $0.id == resolver.id }; try save(); return "Résolveur retiré de la liste." }
                }
            }
        }
    }
    func tools() {
        title("Tests et outils")
        guard let choice = choose(["Tester une adresse DNS / URL", "Tester la résolution native macOS", "Vider le cache macOS", "Voir l'état launchd du proxy", "Afficher les règles DNS effectives", "Restaurer configuration + DNS précédents", "VPN détectés / DNS du tunnel"]) else { return }
        switch choice {
        case 0:
            let endpoint = input("Serveur", default: "127.0.0.1")
            let domain = input("Domaine", default: settings.testDomain)
            let result = manager.check(endpoint: endpoint, domain: domain)
            print("\n\(result.ok ? "✓" : "✗") \(result.detail)"); pause()
        case 1: let result = manager.nativeCheck(domain: settings.testDomain); print("\n\(result.ok ? "✓" : "✗") \(result.detail)"); pause()
        case 2: perform { try manager.flush() }
        case 3: perform { try manager.logs() }
        case 4: perform { try Runner.checked("/usr/sbin/scutil", ["--dns"]) }
        case 5:
            if confirmed("Restaurer le dernier point de sauvegarde") { perform { try manager.restore() } }
        default:
            perform {
                let networks = try manager.connections()
                let vpns = manager.vpnConnections()
                let dns = try Runner.checked("/usr/sbin/scutil", ["--dns"])
                return manager.networkSummary(connections: networks, vpns: vpns, systemDNS: dns) + "\n\nPour modifier un DNS imposé par le VPN, utilise les réglages de son client.\nPour WireGuard, la valeur DNS = 127.0.0.1 vise le proxy local : vérifie d'abord qu'il répond.\nL'adresse interne du tunnel n'est pas son serveur DNS."
            }
        }
    }
    func config() {
        title("Configuration partagée du TUI et du voyant")
        print("Fichier : \(manager.store.file.path)\n")
        guard let choice = choose(["Choisir LAN / Wi-Fi (actuel : \(serviceLabel))", "DNS LAN facultatif (\(settings.lanResolver))", "Domaine de test (\(settings.testDomain))", "Afficher la configuration dnscrypt-proxy", "Importer les résolveurs de l'ancien TUI"]) else { return }
        perform {
            switch choice {
            case 0: try selectService(); return "Connexion sélectionnée : \(serviceLabel)."
            case 1:
                let value = input("DNS LAN facultatif", default: settings.lanResolver)
                guard value.isEmpty || Validation.ip(value) else { throw ManagerError.message("IP invalide.") }
                if let index = settings.resolvers.firstIndex(where: { $0.id == "local-lan" && $0.endpoint == settings.lanResolver }) { settings.resolvers[index].endpoint = value }
                settings.lanResolver = value; try save(); return "IP sauvegardée."
            case 2:
                let value = input("Domaine de test", default: settings.testDomain)
                guard Validation.domain(value) else { throw ManagerError.message("Domaine invalide.") }
                settings.testDomain = value; try save(); return "Domaine sauvegardé."
            case 3: return try String(contentsOfFile: manager.configPath, encoding: .utf8)
            default:
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dnscrypt_custom_servers.txt")
                let text = try String(contentsOf: file, encoding: .utf8)
                var count = 0
                for line in text.components(separatedBy: .newlines) {
                    let fields = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard fields.count == 3, !settings.resolvers.contains(where: { $0.id == fields[0] }) else { continue }
                    let resolver = Resolver(id: fields[0], name: fields[1], endpoint: fields[2], stamp: fields[2])
                    try resolver.validate(); settings.resolvers.append(resolver); count += 1
                }
                try save(); return "\(count) résolveur(s) importé(s) ; les identifiants déjà présents ont été conservés."
            }
        }
    }
    func maintenance() {
        title("Installation et maintenance")
        print("Homebrew installe les outils dans ton compte.\nLe service système demande l'autorisation administrateur macOS.\n")
        guard let choice = choose(["Installer doggo et dnscrypt-proxy", "Mettre à jour les deux outils", "Installer / démarrer le service système", "Redémarrer le service", "Ouvrir le site Homebrew"]) else { return }
        perform {
            switch choice {
            case 0, 1:
                guard confirmed(choice == 0 ? "Installer les outils" : "Mettre à jour les outils (Homebrew)") else { return "Annulé." }
                print("Homebrew travaille… Cette opération peut prendre plusieurs minutes.")
                return try manager.maintenance(update: choice == 1) + "\nSi le proxy a été mis à jour, redémarre son service puis relance les contrôles."
            case 2: return try manager.startService()
            case 3: return try manager.restart()
            default: return try Runner.checked("/usr/bin/open", ["https://brew.sh"])
            }
        }
    }
    func run() {
        guard interactive else { print("Utilise --status ou --check en mode non interactif ; lance sans argument dans Terminal pour le TUI."); return }
        while true {
            // Reload changes saved by another instance.
            do { settings = try manager.store.load() }
            catch { print(error.localizedDescription); return }
            connections = (try? manager.connections()) ?? []
            title("Connexion : \(serviceLabel) · Domaine de test : \(settings.testDomain)")
            guard let choice = choose(["État et contrôles DNS", "Modes DNS : Automatique / DNS local", "Résolveurs : ajouter, modifier, tester, activer", "Tests et outils", "Configuration", "Installation et mises à jour"]) else { return }
            switch choice {
            case 0: title("État DNS"); showStatus(); pause()
            case 1: modes()
            case 2: resolvers()
            case 3: tools()
            case 4: config()
            default: maintenance()
            }
        }
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "--version" { print(AppRelease.version); exit(0) }
    if args.first == "--demo" { try Dashboard(manager: Manager(), demo: true).run(); exit(0) }
    let tui = try TUI()
    switch args.first {
    case "--status": tui.showStatus()
    case "--check":
        guard args.count >= 2 else { throw ManagerError.message("Usage : dns-manager --check SERVEUR [DOMAINE]") }
        let result = tui.manager.check(endpoint: args[1], domain: args.count >= 3 ? args[2] : tui.settings.testDomain)
        print("\(result.ok ? "✓" : "✗") \(result.title)\n\(result.detail)")
        exit(result.ok ? 0 : 1)
    case "--help", "-h": print("DNS Manager macOS \(AppRelease.version)\n\nSans argument ou --tui : TUI plein écran (flèches, Tab, panneaux)\n--demo : démonstration fictive en lecture seule\n--version : version\n--simple : menus numérotés\n--status : état complet (lecture seule)\n--check SERVEUR [DOMAINE] : test doggo (lecture seule)\n--audit-cache : audit des paramètres et conseils Quad9 (lecture seule)\n--admin-status : état de l'autorisation durable\n--admin-remove : retirer l'autorisation durable après confirmation\n--help : aide")
    case "--audit-cache": print(try tui.manager.optimizationReport())
    case "--simple": tui.run()
    case "--admin-status": print(AdminBridge.installed ? try AdminBridge.run(AdminRequest(action: "status")) : "Autorisation durable non installée.")
    case "--admin-remove":
        guard tui.confirmed("Retirer l'autorisation DNS durable") else { exit(0) }
        print(try AdminBridge.run(AdminRequest(action: "uninstall")))
    case nil, "--tui": try Dashboard(manager: tui.manager).run()
    default: throw ManagerError.message("Argument inconnu. Utilise --help.")
    }
} catch { fputs("Erreur : \(error.localizedDescription)\n", stderr); exit(1) }
