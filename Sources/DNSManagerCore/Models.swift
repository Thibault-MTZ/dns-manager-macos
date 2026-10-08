import Foundation
import Darwin

public struct Resolver: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var endpoint: String
    public var stamp: String
    public init(id: String, name: String, endpoint: String, stamp: String = "") {
        self.id = id; self.name = name; self.endpoint = endpoint; self.stamp = stamp
    }
    public func validate() throws {
        guard !id.isEmpty, id.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ManagerError.message("Nom requis ; identifiant de 1 à 64 lettres, chiffres, tirets ou underscores.")
        }
        guard !endpoint.isEmpty, !endpoint.contains(where: { $0.isWhitespace }), !endpoint.hasPrefix("-") else {
            throw ManagerError.message("Adresse DNS requise, sans espace (IP, https://, tls://, quic:// ou sdns://).")
        }
        guard stamp.isEmpty || Self.stampProtocol(stamp) != nil else {
            throw ManagerError.message("Stamp sdns:// invalide.")
        }
    }
    public static func stampProtocol(_ stamp: String) -> UInt8? {
        guard stamp.hasPrefix("sdns://") else { return nil }
        var base64 = String(stamp.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count >= 9 else { return nil }
        return data.first
    }
    // DoH stamps use the standard DNS stamp format with unknown properties,
    // no pinned certificate hashes, and normal HTTPS certificate verification.
    public static func dohStamp(_ endpoint: String, address: String = "") -> String? {
        guard address.isEmpty || Validation.ip(address) else { return nil }
        guard let url = URLComponents(string: endpoint), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        let hostname = host + (url.port.map { ":\($0)" } ?? "")
        let path = (url.percentEncodedPath.isEmpty ? "/dns-query" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?\($0)" } ?? "")
        let hostBytes = Data(hostname.utf8), pathBytes = Data(path.utf8)
        let addressBytes = Data((address.contains(":") ? "[\(address)]" : address).utf8)
        guard hostBytes.count <= 255, pathBytes.count <= 255, addressBytes.count <= 255 else { return nil }
        var data = Data([2] + Array(repeating: UInt8(0), count: 8))
        data.append(UInt8(addressBytes.count)); data.append(addressBytes)
        data.append(0) // Empty certificate hash list.
        data.append(UInt8(hostBytes.count)); data.append(hostBytes)
        data.append(UInt8(pathBytes.count)); data.append(pathBytes)
        return "sdns://" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public var stampAddress: String {
        guard Self.stampProtocol(stamp) == 2 else { return "" }
        var base64 = String(stamp.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count > 9 else { return "" }
        let length = Int(bytes[9])
        guard bytes.count >= 10 + length else { return "" }
        return String(decoding: bytes[10..<(10 + length)], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    public var activationStamp: String { stamp.isEmpty ? Self.dohStamp(endpoint) ?? "" : stamp }
    public var canActivate: Bool { [UInt8(1), UInt8(2)].contains(Self.stampProtocol(activationStamp) ?? 255) }
}

public struct Settings: Codable {
    public var resolvers: [Resolver]
    public var service: String
    public var lanResolver: String
    public var testDomain: String
    private enum CodingKeys: String, CodingKey { case resolvers, service, lanResolver, homelab, testDomain }
    public init(resolvers: [Resolver], service: String, lanResolver: String, testDomain: String) {
        self.resolvers = resolvers; self.service = service; self.lanResolver = lanResolver; self.testDomain = testDomain
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolvers = try values.decode([Resolver].self, forKey: .resolvers)
        service = try values.decode(String.self, forKey: .service)
        lanResolver = try values.decodeIfPresent(String.self, forKey: .lanResolver) ?? values.decodeIfPresent(String.self, forKey: .homelab) ?? ""
        testDomain = try values.decode(String.self, forKey: .testDomain)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(resolvers, forKey: .resolvers); try values.encode(service, forKey: .service)
        try values.encode(lanResolver, forKey: .lanResolver); try values.encode(testDomain, forKey: .testDomain)
    }
    public static var defaults: Settings {
        Settings(resolvers: [
            Resolver(id: "cloudflare", name: "Cloudflare", endpoint: "https://cloudflare-dns.com/dns-query", stamp: "sdns://AgcAAAAAAAAABzEuMS4xLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5"),
            Resolver(id: "quad9", name: "Quad9", endpoint: "https://dns.quad9.net/dns-query"),
            Resolver(id: "quad9-nofilter", name: "Quad9 sans filtrage", endpoint: "https://dns10.quad9.net/dns-query", stamp: "sdns://AgMAAAAAAAAACDkuOS45LjEwAA9kbnMxMC5xdWFkOS5uZXQKL2Rucy1xdWVyeQ")
        ], service: "", lanResolver: "", testDomain: "example.com")
    }
}

public enum DNSMode: String, CaseIterable { case automatic = "Automatique (par défaut)", local = "Via DNS local (DNSCrypt)" }
public enum Health: String { case green = "Opérationnel", orange = "À vérifier", red = "Échec" }

public struct CheckResult: Identifiable {
    public var id: String { title }
    public var title: String
    public var ok: Bool
    public var detail: String
}
public struct Snapshot {
    public var date = Date()
    public var services: [String] = []
    public var selectedService = ""
    public var serviceDisplayName = ""
    public var networkSummary = ""
    public var connections: [NetworkConnection] = []
    public var vpns: [VPNConnection] = []
    public var manualDNS: [String] = []
    public var systemDNS = ""
    public var versions = ""
    public var proxy = ""
    public var checks: [CheckResult] = []
    public var health: Health = .orange
}

public enum Validation {
    public static func ip(_ value: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    public static func domain(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,252}$", options: .regularExpression) != nil
    }
}

public final class Store {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("settings.json") }
    public var backup: URL { directory.appendingPathComponent("restore.json") }
    public init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["DNS_MANAGER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        self.directory = directory ?? override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DNSManager")
    }
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: file.path) else { return .defaults }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
    }
    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ settings: Settings) throws {
        guard settings.lanResolver.isEmpty || Validation.ip(settings.lanResolver), Validation.domain(settings.testDomain) else { throw ManagerError.message("IP du DNS LAN ou domaine de test invalide.") }
        for resolver in settings.resolvers { try resolver.validate() }
        guard Set(settings.resolvers.map(\.id)).count == settings.resolvers.count else { throw ManagerError.message("Les identifiants des résolveurs doivent être uniques.") }
        try write(settings, to: file)
    }
}
