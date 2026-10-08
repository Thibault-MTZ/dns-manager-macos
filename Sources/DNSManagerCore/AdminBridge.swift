import Foundation

public struct AdminRequest: Codable {
    public var action: String
    public var service: String?
    public var mode: String?
    public var resolver: Resolver?
    public var domain: String?
    public init(action: String, service: String? = nil, mode: String? = nil, resolver: Resolver? = nil, domain: String? = nil) {
        self.action = action; self.service = service; self.mode = mode; self.resolver = resolver; self.domain = domain
    }
    public func validate() throws {
        guard ["status", "mode", "activate", "restore", "flush", "restart", "start", "uninstall"].contains(action) else { throw ManagerError.message("Action administrateur interdite.") }
        if let domain { guard Validation.domain(domain) else { throw ManagerError.message("Domaine invalide.") } }
        if action == "mode" { guard mode == "automatic" || mode == "local" else { throw ManagerError.message("Mode DNS interdit.") } }
        if action == "activate" {
            guard let resolver, resolver.canActivate, resolver.activationStamp.count <= 4096 else { throw ManagerError.message("Résolveur interdit ou invalide.") }
            try resolver.validate()
        }
        if action == "mode" || action == "activate" {
            guard let service, !service.isEmpty, service.count <= 256 else { throw ManagerError.message("Connexion requise.") }
        }
    }
}

public enum AdminBridge {
    public static let helperPath = "/Library/PrivilegedHelperTools/org.dnsmanager.admin"
    public static let statePath = "/Library/Application Support/DNSManagerAdmin"
    public static let privatePath = statePath + "/private"
    public static let configPath = statePath + "/dnscrypt-proxy.toml"
    public static let proxyPath = "/Library/PrivilegedHelperTools/org.dnsmanager.proxy"
    public static let rulePath = "/etc/sudoers.d/dns-manager"
    public static var managedProxy: Bool {
        guard FileManager.default.fileExists(atPath: configPath), FileManager.default.isExecutableFile(atPath: proxyPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/LaunchDaemons/sh.brew.dnscrypt-proxy.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return (plist["ProgramArguments"] as? [String]) == [proxyPath, "-config", configPath]
    }
    public static var installed: Bool {
        guard managedProxy, FileManager.default.fileExists(atPath: rulePath), FileManager.default.isExecutableFile(atPath: helperPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: helperPath),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = attributes[.posixPermissions] as? NSNumber else { return false }
        return mode.intValue & 0o022 == 0
    }
    public static func run(_ request: AdminRequest) throws -> String {
        try request.validate()
        let data = try JSONEncoder().encode(request)
        return try Runner.checked("/usr/bin/sudo", ["-n", helperPath, String(decoding: data, as: UTF8.self)], timeout: 180)
    }
}
