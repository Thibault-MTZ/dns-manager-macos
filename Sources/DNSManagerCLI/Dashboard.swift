import Foundation
import Darwin
import CTerminal
import DNSManagerCore

private struct WorkResult {
    var snapshot: Snapshot?
    var text = ""
    var success = true
    var resolverID: String?
}
private final class BackgroundWork {
    private let lock = NSLock()
    private var result: WorkResult?
    func start(_ operation: @escaping () throws -> WorkResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value: WorkResult
            do { value = try operation() }
            catch { value = WorkResult(text: error.localizedDescription, success: false) }
            self.lock.lock(); self.result = value; self.lock.unlock()
        }
    }
    func take() -> WorkResult? {
        lock.lock(); defer { lock.unlock() }
        let value = result; result = nil; return value
    }
}
private struct Field { var label: String; var value: String; var cursor: Int }
private enum FormKind { case resolver(String?), settings, test }
private struct Form { var title: String; var fields: [Field]; var selected = 0; var kind: FormKind }

final class Dashboard {
    private let manager: Manager
    private let demo: Bool
    private var settings: Settings
    private var snapshot: Snapshot?
    private let work = BackgroundWork()
    private var busy = false
    private var refreshAfterWork = false
    private var busyTitle = ""
    private var banner = "Bienvenue · Choisis LAN ou Wi-Fi dans Connexion."
    private var bannerOK = true
    private var output = ""
    private var testResults: [String: String] = [:]
    private var screen = 0
    private var selected = Array(repeating: 0, count: 8)
    private var focus = 0
    private var scroll = 0
    private var form: Form?
    private var confirmation: (() -> Void)?
    private var confirmTitle = ""
    private var confirmYes = false
    private var help = false
    private var running = true
    private var dirty = true
    private var nextRefresh = Date.distantPast
    private let sections = ["Tableau de bord", "Connexion", "Modes DNS", "Résolveurs", "VPN", "Outils", "Configuration", "Maintenance"]
    init(manager: Manager, demo: Bool = false) throws {
        self.manager = manager; self.demo = demo
        settings = demo ? .defaults : try manager.store.load()
        if demo { settings.service = "Ethernet" }
    }

    private var connectionLabel: String {
        settings.service.isEmpty ? "à choisir" : snapshot?.connections.first { $0.service == settings.service }?.label ?? "à vérifier"
    }
    private func rows() -> [String] {
        switch screen {
        case 0: return (snapshot?.checks.map { ($0.ok ? "✓ " : "✗ ") + $0.title } ?? ["Chargement des contrôles…"]) + ["Actualiser les contrôles"]
        case 1: return snapshot?.connections.map { ($0.service == settings.service ? "● " : "  ") + $0.label + ($0.active ? " · utilisée" : "") } ?? []
        case 2: return ["Automatique (par défaut)", "Via DNS local (DNSCrypt)"]
        case 3: return settings.resolvers.map { (isActive($0) ? "● " : "  ") + $0.name }
        case 4: return (snapshot?.vpns.map { ($0.connected ? "● " : "○ ") + $0.client + " · " + $0.name } ?? []) + ["Règles DNS de macOS"]
        case 5: return ["Test DNS personnalisé", "Tester la résolution macOS", "Vider le cache DNS", "État du service DNSCrypt", "Règles DNS de macOS", "Restaurer les réglages précédents", "Audit cache / Quad9"]
        case 6: return ["Modifier les paramètres", "Importer l'ancien TUI", "Voir la configuration du proxy", "Choisir LAN / Wi-Fi"]
        default: return ["Installer les outils", "Mettre à jour les outils", "Installer / démarrer le service", "Redémarrer le proxy", "Site officiel Homebrew", "Autorisation DNS durable : état", "Retirer l'autorisation durable"]
        }
    }
    private var index: Int { min(selected[screen], max(0, rows().count - 1)) }
    private var resolver: Resolver? { screen == 3 && settings.resolvers.indices.contains(index) ? settings.resolvers[index] : nil }
    private func isActive(_ resolver: Resolver) -> Bool {
        let proxy = snapshot?.proxy ?? ""
        return proxy.contains("'dnsmanager-\(resolver.id)'") || proxy.contains("'\(resolver.id)'") || proxy.contains("\"dnsmanager-\(resolver.id)\"") || proxy.contains("\"\(resolver.id)\"")
    }
    private func protocolName(_ resolver: Resolver) -> String {
        if resolver.endpoint.hasPrefix("https://") { return "HTTPS / DoH" }
        if resolver.endpoint.hasPrefix("tls://") { return "TLS / DoT" }
        if resolver.endpoint.hasPrefix("quic://") { return "QUIC / DoQ" }
        if resolver.endpoint.hasPrefix("sdns://") { return "Stamp DNS" }
        return "DNS direct (UDP)"
    }
    private func details() -> String {
        switch screen {
        case 0:
            return "ÉTAT DU MAC\n\n" + (snapshot?.networkSummary ?? "Détection du réseau et des VPN…") + "\n\nConnexion administrée : \(connectionLabel)\nDNS manuels : \(snapshot?.manualDNS.joined(separator: ", ").isEmpty == false ? snapshot!.manualDNS.joined(separator: ", ") : "automatiques ou non lus")\n\n" + (snapshot?.proxy ?? "") + "\n\n" + (snapshot?.versions ?? "") + "\n\n" + (snapshot?.checks.indices.contains(index) == true ? snapshot!.checks[index].detail : "Entrée ou R : relancer tous les contrôles.") + "\n\nLe voyant indique la résolution ; il ne prouve pas le chiffrement de toutes les applications."
        case 1:
            guard let connections = snapshot?.connections, connections.indices.contains(index) else { return "Détection du LAN et du Wi-Fi en cours.\n\nR : actualiser." }
            let connection = connections[index]
            return "\(connection.label)\n\n\(connection.active ? "Connexion utilisée par la route principale." : "Connexion configurée dans macOS.")\n\nEntrée : sélectionner cette connexion.\n\nLa sélection ne change pas les DNS.\n\nLes VPN se consultent dans leur panneau dédié."
        case 2:
            return index == 0 ? "AUTOMATIQUE\n\nUtiliser les DNS fournis par le réseau.\n\nConnexion : \(connectionLabel)\n\nEntrée : appliquer après confirmation.\n\nLes DNS imposés par un VPN restent gérés par son client." : "DNS LOCAL\n\nLe Mac interroge dnscrypt-proxy sur 127.0.0.1 et ::1.\n\nConnexion : \(connectionLabel)\n\nLe résolveur distant se choisit dans Résolveurs.\n\nLe proxy doit répondre avant la bascule.\n\nEntrée : appliquer après confirmation."
        case 3:
            guard let resolver else { return "Aucun résolveur.\n\nA : ajouter une adresse DNS." }
            return "\(resolver.name)\n\n\(resolver.endpoint)\n\nProtocole : \(protocolName(resolver))\n\(isActive(resolver) ? "Sélectionné dans la configuration du proxy." : "")\n\n\(resolver.canActivate ? "Activable dans le proxy local." : "Disponible pour les tests directs.")\n\nT : tester\nEntrée : activer\nE : modifier\nD : retirer de la liste\nA : ajouter\n\nDERNIER TEST\n\n" + (testResults[resolver.id] ?? "Pas encore testé dans cette session.")
        case 4:
            if let vpns = snapshot?.vpns, vpns.indices.contains(index) {
                let vpn = vpns[index]
                return "\(vpn.client)\n\(vpn.name)\n\nÉtat : \(vpn.stateLabel)\n\(vpn.dnsSummary)\n\n\(vpn.device.isEmpty ? "" : "Tunnel : \(vpn.device)")\n\nEntrée : détails\nT : tester les DNS du tunnel\n\nLe client VPN gère ses DNS. L'adresse interne du tunnel n'est pas le serveur DNS.\n\nWireGuard peut viser 127.0.0.1 dans son champ DNS si le proxy local est opérationnel.\n\nDERNIER TEST\n" + (testResults["vpn:" + vpn.id] ?? "Pas encore testé dans cette session.")
            }
            return (snapshot?.networkSummary ?? "Détection en cours…") + "\n\nEntrée : lire les règles DNS de macOS.\n\nLes clients qui n'exposent pas de profil peuvent rester non identifiés."
        case 5: return "\(rows()[index])\n\nEntrée : ouvrir ou lancer cet outil.\n\nLes opérations qui modifient le système nécessitent une confirmation.\n\n" + output
        case 6: return "PARAMÈTRES\n\nDomaine de test : \(settings.testDomain)\nDNS LAN : \(settings.lanResolver)\nConnexion : \(connectionLabel)\n\nEntrée : ouvrir la sélection.\n\nLes réglages sont communs au TUI et au voyant.\n\n" + output
        default: return "\(rows()[index])\n\nHomebrew gère doggo et dnscrypt-proxy.\n\nEntrée : lancer l'action.\n\nL'installation et les mises à jour peuvent prendre plusieurs minutes. Le TUI reste navigable.\n\n" + output
        }
    }

    private func text(_ row: Int, _ col: Int, _ width: Int, _ value: String, style: Int = 1) {
        value.withCString { dm_text(Int32(row), Int32(col), Int32(max(0, width)), $0, Int32(style)) }
    }
    private func wrap(_ value: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        return value.components(separatedBy: .newlines).flatMap { line -> [String] in
            if line.isEmpty { return [""] }
            var result: [String] = []; var rest = line
            while rest.count > width { result.append(String(rest.prefix(width))); rest = String(rest.dropFirst(width)) }
            result.append(rest); return result
        }
    }
    private func panel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, title: String, focused: Bool) {
        dm_box(Int32(y), Int32(x), Int32(h), Int32(w), focused ? 1 : 0)
        text(y, x + 2, w - 4, " \(title) ", style: focused ? 5 : 1)
    }
    private func list(_ values: [String], x: Int, y: Int, width: Int, height: Int, selection: Int, focused: Bool) {
        guard height > 0 else { return }
        let start = max(0, selection - height + 1)
        for (row, value) in values.dropFirst(start).prefix(height).enumerated() {
            let highlighted = row + start == selection
            text(y + row, x, width, (highlighted ? "› " : "  ") + value, style: highlighted ? (focused ? 6 : 5) : 1)
        }
        if values.isEmpty { text(y, x, width, "Aucun élément", style: 3) }
    }
    private func render() {
        dm_clear()
        let w = Int(dm_columns()), h = Int(dm_rows())
        guard w >= 64, h >= 18 else {
            text(0, 0, w, "DNS MANAGER — agrandir la fenêtre (64 × 18 minimum)", style: 3)
            text(2, 0, w, "Q : quitter · le terminal reste redimensionnable")
            dm_present(); return
        }
        let health = snapshot?.health
        let status = busy ? "Contrôles / opération en cours" : health?.rawValue ?? "À vérifier"
        text(0, 1, w - 2, "DNS MANAGER  \(AppRelease.version)  /  \(connectionLabel)  /  \(demo ? "DÉMO" : status)", style: busy ? 5 : health == .green ? 2 : health == .red ? 4 : 3)
        text(1, 1, w - 2, busy ? busyTitle : banner, style: busy ? 5 : bannerOK ? 1 : 4)
        let bodyY = 3, bodyH = h - 6
        let navW = 23
        panel(0, bodyY, navW, bodyH, title: "Navigation", focused: focus == 0)
        list(sections, x: 1, y: bodyY + 2, width: navW - 2, height: bodyH - 4, selection: screen, focused: focus == 0)
        if w >= 110 {
            let listX = navW + 1, listW = min(37, (w - navW - 2) / 2)
            panel(listX, bodyY, listW, bodyH, title: sections[screen], focused: focus == 1)
            list(rows(), x: listX + 1, y: bodyY + 2, width: listW - 2, height: bodyH - 4, selection: index, focused: focus == 1)
            let detailX = listX + listW + 1, detailW = w - detailX
            panel(detailX, bodyY, detailW, bodyH, title: "Détails / résultats", focused: focus == 2)
            let lines = wrap(details(), width: detailW - 4)
            scroll = min(scroll, max(0, lines.count - (bodyH - 4)))
            for (row, line) in lines.dropFirst(scroll).prefix(bodyH - 4).enumerated() { text(bodyY + 2 + row, detailX + 2, detailW - 4, line) }
        } else {
            let contentX = navW + 1, contentW = w - contentX
            panel(contentX, bodyY, contentW, bodyH, title: focus == 2 ? "Détails / résultats" : sections[screen], focused: focus != 0)
            if focus == 2 {
                let lines = wrap(details(), width: contentW - 4)
                scroll = min(scroll, max(0, lines.count - (bodyH - 4)))
                for (row, line) in lines.dropFirst(scroll).prefix(bodyH - 4).enumerated() { text(bodyY + 2 + row, contentX + 2, contentW - 4, line) }
            } else { list(rows(), x: contentX + 1, y: bodyY + 2, width: contentW - 2, height: bodyH - 4, selection: index, focused: focus == 1) }
        }
        text(h - 2, 1, w - 2, "↑↓ Naviguer  ←→/Tab Panneau  Entrée Choisir  R Actualiser  ? Aide  Q Quitter", style: 5)
        text(h - 1, 1, w - 2, screen == 3 ? "T Tester · A Ajouter · E Modifier · D Retirer · Pg↑/Pg↓ Défiler les détails" : "DNS local = 127.0.0.1 / ::1 · Les DNS VPN restent gérés par leur client.")
        if let form { renderForm(form, width: w, height: h) }
        if confirmation != nil { renderConfirmation(width: w, height: h) }
        if help { renderHelp(width: w, height: h) }
        dm_present()
    }

    private func modal(width: Int, height: Int, screenW: Int, screenH: Int, title: String) -> (Int, Int, Int, Int) {
        let width = min(width, screenW - 4), height = min(height, screenH - 4)
        let x = (screenW - width) / 2, y = (screenH - height) / 2
        for row in y..<(y + height) { text(row, x, width, "") }
        panel(x, y, width, height, title: title, focused: true)
        return (x, y, width, height)
    }
    private func renderForm(_ form: Form, width: Int, height: Int) {
        let (x, y, w, h) = modal(width: 82, height: form.fields.count * 3 + 6, screenW: width, screenH: height, title: form.title)
        let visible = max(1, (h - 5) / 3)
        let start = max(0, form.selected - visible + 1)
        for (offset, field) in form.fields.dropFirst(start).prefix(visible).enumerated() {
            text(y + 2 + offset * 3, x + 2, w - 4, field.label, style: 5)
            let characters = Array(field.value)
            let cursor = min(field.cursor, characters.count)
            let before = String(characters.prefix(cursor)), after = String(characters.dropFirst(cursor))
            let value = before + (offset + start == form.selected ? "│" : "") + after
            let start = max(0, cursor - (w - 7))
            let shown = String(value.dropFirst(start).prefix(w - 6))
            text(y + 3 + offset * 3, x + 2, w - 4, shown, style: offset + start == form.selected ? 6 : 1)
        }
        text(y + h - 2, x + 2, w - 4, "Tab / ↑↓ Champs · Entrée Suivant/Valider · Esc Annuler · Ctrl-U Effacer", style: 5)
    }
    private func renderConfirmation(width: Int, height: Int) {
        let (x, y, w, h) = modal(width: 76, height: 12, screenW: width, screenH: height, title: "Confirmer")
        for (row, line) in wrap(confirmTitle, width: w - 6).prefix(h - 7).enumerated() { text(y + 2 + row, x + 3, w - 6, line) }
        text(y + h - 4, x + 3, (w - 8) / 2, "Annuler", style: confirmYes ? 1 : 6)
        text(y + h - 4, x + w / 2, (w - 8) / 2, "Confirmer", style: confirmYes ? 6 : 1)
        text(y + h - 2, x + 3, w - 6, "←→ / Tab Choisir · Entrée Valider · Esc Annuler", style: 5)
    }
    private func renderHelp(width: Int, height: Int) {
        let lines = ["Flèches ↑↓ : naviguer dans le panneau", "Flèches ←→ ou Tab : changer de panneau", "Entrée : sélectionner ou appliquer", "R : actualiser l'état réseau et DNS", "T : tester le résolveur ou les DNS du VPN", "A / E / D : ajouter / modifier / retirer un résolveur", "Pg↑ / Pg↓ : défiler les détails et les résultats", "Esc : revenir à la navigation ou annuler un formulaire", "Q / Ctrl-C : quitter (hors opération en cours)", "", "Les changements DNS nécessitent une confirmation.", "Aucune action réseau n'est déclenchée par les flèches.", "", "Une touche pour fermer cette aide."]
        let (x, y, w, h) = modal(width: 78, height: 19, screenW: width, screenH: height, title: "Raccourcis")
        for (row, line) in lines.prefix(h - 3).enumerated() { text(y + 2 + row, x + 2, w - 4, line) }
    }

    private func start(_ title: String, refreshAfter: Bool = false, operation: @escaping () throws -> WorkResult) {
        guard !busy else { banner = "Une opération est déjà en cours."; dirty = true; return }
        busy = true; busyTitle = title; refreshAfterWork = refreshAfter; dirty = true
        work.start(operation)
    }
    private func refresh() {
        let manager = manager
        let demo = demo
        start("Détection LAN / Wi-Fi / VPN et tests DNS…") { WorkResult(snapshot: demo ? Manager.demoSnapshot() : manager.snapshot()) }
    }
    private func operation(_ title: String, refreshAfter: Bool = false, action: @escaping () throws -> String) {
        start(title, refreshAfter: refreshAfter) { WorkResult(text: try action()) }
    }
    private func confirm(_ title: String, action: @escaping () -> Void) {
        guard !busy else { banner = "Attends la fin des contrôles ou de l'opération."; return }
        confirmTitle = title; confirmYes = false; confirmation = action
    }
    private func needsConnection() -> Bool {
        if snapshot?.connections.contains(where: { $0.service == settings.service }) != true {
            screen = 1; focus = 1; scroll = 0; banner = "Choisis d'abord LAN ou Wi-Fi avec Entrée."; return true
        }
        return false
    }
    private func testResolver() {
        guard let resolver else { return }
        if demo {
            start("Test fictif…") { WorkResult(text: "✓ 203.0.113.80 · 12 ms (démonstration)", resolverID: resolver.id) }
            return
        }
        let manager = manager, domain = settings.testDomain
        start("Test de \(resolver.name)…") {
            let check = manager.check(endpoint: resolver.endpoint, domain: domain)
            return WorkResult(text: (check.ok ? "✓ " : "✗ ") + check.detail, success: check.ok, resolverID: resolver.id)
        }
    }
    private func editResolver(_ existing: Resolver? = nil) {
        if demo { banner = "Démonstration en lecture seule : aucune modification."; return }
        guard !busy else { return }
        let values = [("Identifiant", existing?.id ?? ""), ("Nom", existing?.name ?? ""), ("Adresse (IP, https://, tls://, quic:// ou sdns://)", existing?.endpoint ?? ""), ("Stamp facultatif — automatique pour HTTPS", existing?.stamp ?? "")]
        form = Form(title: existing == nil ? "Ajouter un résolveur" : "Modifier le résolveur", fields: values.map { Field(label: $0.0, value: $0.1, cursor: $0.1.count) }, kind: .resolver(existing?.id))
    }
    private func submitForm(_ value: Form) {
        do {
            let fields = value.fields.map(\.value)
            switch value.kind {
            case .resolver(let existingID):
                let resolver = Resolver(id: fields[0], name: fields[1], endpoint: fields[2], stamp: fields[3])
                var next = settings
                if let existingID, let i = next.resolvers.firstIndex(where: { $0.id == existingID }) { next.resolvers[i] = resolver }
                else { next.resolvers.append(resolver) }
                try manager.store.save(next); settings = next
                selected[3] = settings.resolvers.firstIndex(where: { $0.id == resolver.id }) ?? 0
                banner = "Résolveur enregistré."; bannerOK = true
            case .settings:
                var next = settings
                next.testDomain = fields[0]; next.lanResolver = fields[1]
                if let i = next.resolvers.firstIndex(where: { $0.id == "local-lan" && $0.endpoint == settings.lanResolver }) { next.resolvers[i].endpoint = fields[1] }
                try manager.store.save(next); settings = next; banner = "Paramètres enregistrés."; bannerOK = true
            case .test:
                guard Validation.domain(fields[1]), !fields[0].isEmpty else { throw ManagerError.message("Adresse et domaine requis.") }
                let manager = manager
                start("Test DNS personnalisé…") {
                    let check = manager.check(endpoint: fields[0], domain: fields[1])
                    return WorkResult(text: "\(fields[0])\n\(check.detail)", success: check.ok)
                }
            }
            form = nil
        } catch { banner = error.localizedDescription; bannerOK = false }
    }
    private func formKey(_ key: Int) {
        guard var value = form else { return }
        if key == 27 { form = nil; return }
        if key == 9 || key == -1002 { value.selected = (value.selected + 1) % value.fields.count }
        else if key == -1005 || key == -1001 { value.selected = (value.selected + value.fields.count - 1) % value.fields.count }
        else if key == 10 || key == 13 {
            if value.selected == value.fields.count - 1 { submitForm(value); return }
            value.selected += 1
        } else {
            var field = value.fields[value.selected]; var characters = Array(field.value)
            switch key {
            case -1003: field.cursor = max(0, field.cursor - 1)
            case -1004: field.cursor = min(characters.count, field.cursor + 1)
            case -1008, 1: field.cursor = 0
            case 5: field.cursor = characters.count
            case 21: characters = []; field.cursor = 0
            case 127, 8:
                if field.cursor > 0 { characters.remove(at: field.cursor - 1); field.cursor -= 1 }
            case -1009:
                if field.cursor < characters.count { characters.remove(at: field.cursor) }
            default:
                if key >= 32, let scalar = UnicodeScalar(key), characters.count < 2048 {
                    characters.insert(Character(String(scalar)), at: field.cursor); field.cursor += 1
                }
            }
            field.value = String(characters); value.fields[value.selected] = field
        }
        form = value
    }

    private func activateSelection() {
        if demo { banner = "Démonstration en lecture seule : aucune action système."; focus = 2; return }
        guard !busy else { banner = "Attends la fin des contrôles ou de l'opération."; return }
        let manager = manager
        switch screen {
        case 0:
            if index < (snapshot?.checks.count ?? 0) { focus = 2; scroll = 0 } else { refresh() }
        case 1:
            guard let connection = snapshot?.connections[safe: index] else { return }
            do {
                var next = settings; next.service = connection.service
                try manager.store.save(next); settings = next
                banner = "\(connection.label) sélectionné. Aucun DNS changé."; bannerOK = true; refresh()
            } catch { banner = error.localizedDescription; bannerOK = false }
        case 2:
            guard !needsConnection() else { return }
            let mode: DNSMode = index == 0 ? .automatic : .local
            confirm("Appliquer \(mode.rawValue) à \(connectionLabel) ?") { [weak self] in self?.operation("Application du mode DNS…", refreshAfter: true) { try manager.apply(mode: mode) } }
        case 3:
            guard let resolver else { return }
            guard resolver.canActivate else { output = "Cette cible permet un test direct. Pour l'activer, utilise une URL HTTPS ou un stamp DoH/DNSCrypt."; banner = output; bannerOK = false; return }
            guard !needsConnection() else { return }
            confirm("Activer \(resolver.name) dans le proxy local pour \(connectionLabel) ?") { [weak self] in self?.operation("Test puis activation de \(resolver.name)…", refreshAfter: true) { try manager.activate(resolver) } }
        case 4:
            output = details(); focus = 2; scroll = 0
        case 5:
            switch index {
            case 0: form = Form(title: "Test DNS", fields: [Field(label: "Serveur / URL", value: "127.0.0.1", cursor: 9), Field(label: "Domaine", value: settings.testDomain, cursor: settings.testDomain.count)], kind: .test)
            case 1:
                let domain = settings.testDomain
                start("Résolution native macOS…") { let result = manager.nativeCheck(domain: domain); return WorkResult(text: result.detail, success: result.ok) }
            case 2: confirm("Vider le cache DNS de macOS ?") { [weak self] in self?.operation("Vidage du cache…", refreshAfter: true) { try manager.flush() } }
            case 3: operation("Lecture du service…") { try manager.logs() }
            case 4: output = snapshot?.systemDNS ?? "Actualise d'abord les contrôles."; focus = 2; scroll = 0
            case 5: confirm("Restaurer la configuration du proxy et les DNS précédents ?") { [weak self] in self?.operation("Restauration…", refreshAfter: true) { try manager.restore() } }
            default: operation("Audit des réglages du cache…") { try manager.optimizationReport() }
            }
        case 6:
            switch index {
            case 0: form = Form(title: "Paramètres", fields: [Field(label: "Domaine de test", value: settings.testDomain, cursor: settings.testDomain.count), Field(label: "DNS LAN facultatif (vide pour désactiver)", value: settings.lanResolver, cursor: settings.lanResolver.count)], kind: .settings)
            case 1: importLegacy()
            case 2:
                do { output = try String(contentsOfFile: manager.configPath, encoding: .utf8); focus = 2; scroll = 0 }
                catch { banner = error.localizedDescription; bannerOK = false }
            default: screen = 1; focus = 1; scroll = 0
            }
        default:
            switch index {
            case 0, 1:
                let update = index == 1
                confirm(update ? "Mettre à jour doggo et dnscrypt-proxy avec Homebrew ?" : "Installer doggo et dnscrypt-proxy avec Homebrew ?") { [weak self] in
                    self?.operation("Homebrew travaille — tu peux naviguer pendant l'opération…") { try manager.maintenance(update: update) + "\nRedémarre le proxy après une mise à jour et relance les contrôles." }
                }
            case 2: confirm("Installer / démarrer le service système DNSCrypt ?") { [weak self] in self?.operation("Démarrage du service…", refreshAfter: true) { try manager.startService() } }
            case 3: confirm("Redémarrer le proxy DNS local ?") { [weak self] in self?.operation("Redémarrage du proxy…", refreshAfter: true) { try manager.restart() } }
            case 4: operation("Ouverture de Homebrew…") { try Runner.checked("/usr/bin/open", ["https://brew.sh"]) }
            case 5: operation("Vérification de l'autorisation…") { AdminBridge.installed ? try AdminBridge.run(AdminRequest(action: "status")) : "Autorisation durable non installée." }
            default:
                confirm("Retirer l'autorisation DNS durable ? Les prochaines opérations demanderont de nouveau le mot de passe.") { [weak self] in
                    self?.operation("Retrait de l'autorisation…") { try AdminBridge.run(AdminRequest(action: "uninstall")) }
                }
            }
        }
    }
    private func importLegacy() {
        do {
            var next = settings
            for name in [".dnscrypt_custom_servers.txt", ".dnscrypt_resolvers.txt"] {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                    let fields = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard fields.count == 3, !next.resolvers.contains(where: { $0.id == fields[0] }) else { continue }
                    let resolver = Resolver(id: fields[0], name: fields[1], endpoint: fields[2], stamp: fields[2])
                    try resolver.validate(); next.resolvers.append(resolver)
                }
            }
            let count = next.resolvers.count - settings.resolvers.count
            try manager.store.save(next); settings = next; output = "\(count) résolveur(s) importé(s)."; banner = output; bannerOK = true
        } catch { banner = error.localizedDescription; bannerOK = false }
    }
    private func key(_ key: Int) {
        if key == -1010 { dirty = true; return }
        if help { help = false; return }
        if form != nil { formKey(key); return }
        if confirmation != nil {
            switch key {
            case 27, 3: confirmation = nil
            case 9, -1005, -1003, -1004: confirmYes.toggle()
            case 10, 13:
                let action = confirmation; confirmation = nil
                if confirmYes { action?() }
            default: break
            }
            return
        }
        switch key {
        case 113, 81, 3:
            if busy { banner = "Attends la fin de l'opération avant de quitter." } else { running = false }
        case 63: help = true
        case 114, 82: if !busy { refresh() }
        case 9: focus = (focus + 1) % 3
        case -1005: focus = (focus + 2) % 3
        case -1003: focus = max(0, focus - 1)
        case -1004: focus = min(2, focus + 1)
        case 27: focus = 0; scroll = 0
        case -1001, -1002:
            let step = key == -1001 ? -1 : 1
            if focus == 0 { screen = (screen + sections.count + step) % sections.count; scroll = 0 }
            else if focus == 1 { selected[screen] = max(0, min(rows().count - 1, index + step)); scroll = 0 }
            else { scroll = max(0, scroll + step) }
        case -1006: focus = 2; scroll = max(0, scroll - 10)
        case -1007: focus = 2; scroll += 10
        case 10, 13: if focus == 0 { focus = 1 } else { activateSelection() }
        case 116, 84:
            if screen == 3 { testResolver() }
            else if !demo, screen == 4, let vpn = snapshot?.vpns[safe: index], vpn.connected, !vpn.dns.isEmpty {
                let manager = manager, domain = settings.testDomain
                start("Test des DNS du VPN…") {
                    let checks = vpn.dns.map { manager.check(endpoint: $0.contains(":") ? "[\($0)]" : $0, domain: domain) }
                    return WorkResult(text: checks.map { "\($0.ok ? "✓" : "✗") \($0.title)\n\($0.detail)" }.joined(separator: "\n"), success: checks.allSatisfy(\.ok), resolverID: "vpn:" + vpn.id)
                }
            }
        case 97, 65: if screen == 3 { editResolver() }
        case 101, 69: if let resolver { editResolver(resolver) }
        case 100, 68:
            if !demo, let resolver {
                confirm("Retirer \(resolver.name) de la liste ? Le proxy actif reste inchangé.") { [weak self] in
                    guard let self else { return }
                    do {
                        var next = self.settings; next.resolvers.removeAll { $0.id == resolver.id }
                        try self.manager.store.save(next); self.settings = next
                        self.selected[3] = min(self.selected[3], max(0, next.resolvers.count - 1))
                        self.banner = "Résolveur retiré de la liste."; self.bannerOK = true
                    } catch { self.banner = error.localizedDescription; self.bannerOK = false }
                }
            }
        default: break
        }
    }

    func run() throws {
        guard isatty(STDIN_FILENO) == 1 else { throw ManagerError.message("Lance --tui dans Ghostty ou Terminal. Pour un contrôle sans interface, utilise --status.") }
        guard dm_start() != 0 else { throw ManagerError.message("Impossible d'initialiser le terminal.") }
        defer { dm_finish() }
        refresh()
        while running {
            if let result = work.take() {
                busy = false
                if let value = result.snapshot {
                    snapshot = value
                    banner = "État actualisé à " + value.date.formatted(date: .omitted, time: .shortened)
                    bannerOK = true; nextRefresh = Date().addingTimeInterval(60)
                    if !demo { settings = (try? manager.store.load()) ?? settings }
                } else {
                    output = result.text; banner = result.text.components(separatedBy: .newlines).first ?? "Opération terminée."
                    bannerOK = result.success
                    if let id = result.resolverID { testResults[id] = result.text }
                }
                dirty = true
                if refreshAfterWork { refreshAfterWork = false; refresh() }
            }
            if !busy && form == nil && confirmation == nil && Date() >= nextRefresh { refresh() }
            if dirty { render(); dirty = false }
            let pressed = Int(dm_key())
            if pressed != -1 { key(pressed); dirty = true }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
