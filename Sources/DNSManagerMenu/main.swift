import AppKit
import DNSManagerCore

final class MenuDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var refreshing = false
    private let manager = Manager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◌ DNS"
        item.button?.toolTip = "DNS Manager — contrôles en cours"
        updateMenu(nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func updateMenu(_ snapshot: Snapshot?) {
        let menu = NSMenu()
        let title = snapshot.map { "DNS : \($0.health.rawValue)" } ?? "Contrôles en cours…"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if let snapshot {
            let service = snapshot.serviceDisplayName.isEmpty ? "Connexion à choisir dans le TUI" : snapshot.serviceDisplayName
            menu.addItem(withTitle: service, action: nil, keyEquivalent: "")
            let vpnRow = menu.addItem(withTitle: "Réseau / VPN (détails au survol)", action: nil, keyEquivalent: "")
            vpnRow.toolTip = snapshot.networkSummary
            menu.addItem(withTitle: "Vérifié à " + snapshot.date.formatted(date: .omitted, time: .shortened), action: nil, keyEquivalent: "")
            for check in snapshot.checks.prefix(6) {
                let row = menu.addItem(withTitle: "\(check.ok ? "✓" : "✗") \(check.title)", action: nil, keyEquivalent: "")
                row.toolTip = check.detail
            }
        }
        menu.addItem(.separator())
        let launch = menu.addItem(withTitle: "Ouvrir le TUI…", action: #selector(openTUI), keyEquivalent: "t")
        launch.target = self
        let check = menu.addItem(withTitle: "Relancer les contrôles", action: #selector(refresh), keyEquivalent: "r")
        check.target = self; check.isEnabled = !refreshing
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quitter le voyant", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
    }
    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.manager.snapshot()
            DispatchQueue.main.async {
                self.refreshing = false
                let color: NSColor = snapshot.health == .green ? .systemGreen : snapshot.health == .red ? .systemRed : .systemOrange
                let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: snapshot.health.rawValue)
                symbol?.isTemplate = true
                self.item.button?.image = symbol
                self.item.button?.imagePosition = .imageLeading
                self.item.button?.contentTintColor = color
                self.item.button?.title = " DNS"
                self.item.button?.toolTip = "\(snapshot.health.rawValue) · cliquer pour ouvrir le TUI"
                self.updateMenu(snapshot)
            }
        }
    }
    @objc private func openTUI() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dns-manager").path
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("dns-manager").path
        let path = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : sibling
        let command = Runner.shellQuote(path) + " --tui"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            do {
                _ = try Runner.checked("/usr/bin/osascript", ["-e", "tell application \"Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"], timeout: 30)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Ouverture du TUI impossible"
                    alert.informativeText = error.localizedDescription + "\nLance le fichier Lancer TUI.command dans le dossier dist."
                    alert.runModal()
                }
            }
        }
    }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

let application = NSApplication.shared
let delegate = MenuDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
