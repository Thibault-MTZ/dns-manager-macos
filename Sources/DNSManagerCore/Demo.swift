import Foundation

extension Manager {
    public static func demoSnapshot() -> Snapshot {
        var value = Snapshot()
        value.services = ["Ethernet", "Wi-Fi"]
        value.selectedService = "Ethernet"; value.serviceDisplayName = "LAN"
        value.connections = [NetworkConnection(service: "Ethernet", device: "en0", label: "LAN", active: true), NetworkConnection(service: "Wi-Fi", device: "en1", label: "Wi-Fi", active: false)]
        var vpn = VPNConnection(id: "00000000-0000-4000-8000-000000000001", name: "VPN démo", client: "WireGuard", connected: true)
        vpn.state = "Connected"; vpn.device = "utun1"; vpn.dns = ["9.9.9.9"]
        value.vpns = [vpn]
        value.networkSummary = "LAN : connexion utilisée\nWi-Fi : configuré\nWireGuard · VPN démo : connecté · DNS : 9.9.9.9"
        value.manualDNS = ["127.0.0.1", "::1"]
        value.systemDNS = "Données fictives : aucune interrogation du système en mode démo."
        value.proxy = "server_names = ['dnsmanager-cloudflare']"
        value.versions = "doggo : installé\ndnscrypt-proxy : installé\nDémonstration — données fictives"
        value.checks = [CheckResult(title: "Résolution native macOS", ok: true, detail: "203.0.113.80 · données fictives"), CheckResult(title: "127.0.0.1", ok: true, detail: "203.0.113.80 · 2 ms (démo)"), CheckResult(title: "[::1]", ok: true, detail: "203.0.113.80 · 2 ms (démo)")]
        value.health = .green
        return value
    }
}
