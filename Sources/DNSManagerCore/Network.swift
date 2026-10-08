import Foundation

public struct NetworkConnection {
    public var service: String
    public var device: String
    public var label: String
    public var active: Bool
}

public struct VPNConnection {
    public var id: String
    public var name: String
    public var client: String
    public var connected: Bool
    public var state = ""
    public var device = ""
    public var dns: [String] = []
    public var dnsSummary: String {
        !connected ? "déconnecté" : dns.isEmpty ? "DNS du tunnel non exposés par le client" : "DNS : " + dns.joined(separator: ", ")
    }
    public var stateLabel: String {
        ["Connected": "connecté", "Disconnected": "déconnecté", "Connecting": "connexion en cours", "Disconnecting": "déconnexion en cours"][state] ?? (connected ? "connecté" : "déconnecté")
    }
}

public enum NetworkParser {
    public static func connections(_ order: String, defaultDevice: String) -> [NetworkConnection] {
        var service = ""
        var result: [NetworkConnection] = []
        for line in order.components(separatedBy: .newlines) {
            if line.range(of: "^\\([0-9*]+\\) ", options: .regularExpression) != nil {
                if line.hasPrefix("(*)") { service = ""; continue }
                service = String(line.dropFirst(line.firstIndex(of: ")").map { line.distance(from: line.startIndex, to: $0) + 2 } ?? line.count))
                if service.hasPrefix("*") { service = "" }
                continue
            }
            guard !service.isEmpty, line.hasPrefix("(Hardware Port: "), let delimiter = line.range(of: ", Device: ") else { continue }
            let hardware = String(line[line.index(line.startIndex, offsetBy: 16)..<delimiter.lowerBound]).lowercased()
            let device = String(line[delimiter.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            let label: String
            if hardware == "wi-fi" || hardware == "airport" { label = "Wi-Fi" }
            else if device.hasPrefix("en"), hardware.contains("ethernet") || hardware.contains(" lan") || hardware == "lan" { label = "LAN" }
            else { continue }
            result.append(NetworkConnection(service: service, device: device, label: label, active: device == defaultDevice))
        }
        for label in ["LAN", "Wi-Fi"] {
            let indices = result.indices.filter { result[$0].label == label }
            if indices.count > 1 {
                for (number, index) in indices.enumerated() { result[index].label = "\(label) \(number + 1)" }
            }
        }
        return result
    }
    public static func defaultDevice(_ text: String) -> String {
        text.components(separatedBy: .newlines).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    public static func vpns(_ text: String) -> [VPNConnection] {
        let regex = try! NSRegularExpression(pattern: "\\((Connected|Disconnected|Connecting|Disconnecting)\\)\\s+([A-Fa-f0-9-]{36}).*?VPN \\(([^)]+)\\)\\s+\"([^\"]+)\"")
        return text.components(separatedBy: .newlines).compactMap { line in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let provider = ns.substring(with: match.range(at: 3))
            let client = provider.lowercased().contains("wireguard") ? "WireGuard" : provider.lowercased().contains("draytek") ? "DrayTek" : provider
            let state = ns.substring(with: match.range(at: 1))
            var connection = VPNConnection(id: ns.substring(with: match.range(at: 2)), name: ns.substring(with: match.range(at: 4)), client: client, connected: state == "Connected")
            connection.state = state
            return connection
        }
    }
    public static func vpnDetails(_ status: String, connection: VPNConnection) -> VPNConnection {
        var connection = connection
        var readingDNS = false
        for line in status.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("DNSServers : <array>") { readingDNS = true; continue }
            if readingDNS && trimmed == "}" { readingDNS = false; continue }
            if readingDNS, let value = trimmed.components(separatedBy: " : ").last, Validation.ip(value) { connection.dns.append(value) }
            if trimmed.hasPrefix("InterfaceName : ") { connection.device = String(trimmed.dropFirst(16)) }
        }
        // RemoteAddress / ServerAddress may be 127.0.0.1 for NetworkExtension.
        // They are never DNS server fields.
        return connection
    }
}

extension Manager {
    public func connections() throws -> [NetworkConnection] {
        let order = try Runner.checked("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        let route = (try? Runner.checked("/sbin/route", ["-n", "get", "default"])) ?? ""
        return NetworkParser.connections(order, defaultDevice: NetworkParser.defaultDevice(route))
    }
    public func vpnConnections() -> [VPNConnection] {
        guard let list = try? Runner.checked("/usr/sbin/scutil", ["--nc", "list"]) else { return [] }
        return NetworkParser.vpns(list).map { connection in
            guard connection.connected, let status = try? Runner.checked("/usr/sbin/scutil", ["--nc", "status", connection.id]) else { return connection }
            return NetworkParser.vpnDetails(status, connection: connection)
        }
    }
    public func networkSummary(connections: [NetworkConnection], vpns: [VPNConnection], systemDNS: String) -> String {
        var lines = connections.map { "\($0.label) : \($0.active ? "connexion utilisée" : "disponible")" }
        if vpns.isEmpty { lines.append("VPN : aucun profil identifié par macOS") }
        lines += vpns.map { "\($0.client) · \($0.name) : \($0.stateLabel)" + ($0.connected ? " · \($0.dnsSummary)" : "") }
        let known = Set(vpns.filter(\.connected).map(\.device).filter { !$0.isEmpty })
        let regex = try! NSRegularExpression(pattern: "\\((utun[0-9]+)\\)")
        let ns = systemDNS as NSString
        let unknown = Set(regex.matches(in: systemDNS, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }).subtracting(known)
        for device in unknown.sorted() { lines.append("Tunnel \(device) : règles DNS présentes, client non identifié") }
        return lines.joined(separator: "\n")
    }
}
