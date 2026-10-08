import Foundation
import DNSManagerCore

private var failures = 0
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    if !value { failures += 1; print("ÉCHEC \(file):\(line)") }
}
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(!value, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(left == right, file: file, line: line) }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value(); XCTAssertTrue(false, file: file, line: line) } catch { }
}

final class CoreTests {
    func testIPValidationRejectsShellAndMalformedValues() {
        XCTAssertTrue(Validation.ip("127.0.0.1"))
        XCTAssertTrue(Validation.ip("::1"))
        XCTAssertFalse(Validation.ip("999.1.1.1"))
        XCTAssertFalse(Validation.ip("127.0.0.1; touch /tmp/x"))
    }
    func testConfigurePreservesUnrelatedSectionsAndReplacesManagedBlock() throws {
        let resolver = Settings.defaults.resolvers[0]
        let original = "server_names = ['old']\ncache_size = 4096\ndnscrypt_servers = false\n[static.'old']\nstamp = 'old'\n[forwarding_rules]\nfile = 'rules.txt'\n"
        let once = try Manager.configuredTOML(original, resolver: resolver)
        let twice = try Manager.configuredTOML(once, resolver: resolver)
        XCTAssertTrue(twice.contains("cache_size = 4096"))
        XCTAssertTrue(twice.contains("[static.'old']\nstamp = 'old'"))
        XCTAssertTrue(twice.contains("[forwarding_rules]\nfile = 'rules.txt'"))
        XCTAssertTrue(twice.contains("dnscrypt_servers = true"))
        XCTAssertEqual(twice.components(separatedBy: "[static.'dnsmanager-cloudflare']").count, 2)
    }
    func testDoTStampCannotBeActivatedInProxy() throws {
        let resolver = Resolver(id: "dot", name: "DoT", endpoint: "tls://dns.example.com", stamp: "sdns://AwAAAAAAAAAAAAATZG5zLmV4YW1wbGUuY29tOjg1Mw")
        XCTAssertFalse(resolver.canActivate)
        XCTAssertThrowsError(try Manager.configuredTOML("", resolver: resolver))
    }
    func testDoggoEmptyOrFailedRepliesAreNeverGreen() {
        XCTAssertFalse(Manager.parseDoggo(CommandResult(code: 0, output: "{\"responses\":[{\"answers\":null}]}"), title: "test").ok)
        XCTAssertFalse(Manager.parseDoggo(CommandResult(code: 1, output: "timeout"), title: "test").ok)
        XCTAssertFalse(Manager.parseDoggo(CommandResult(code: 0, output: "not json"), title: "test").ok)
        XCTAssertTrue(Manager.parseDoggo(CommandResult(code: 0, output: "{\"responses\":[{\"answers\":[{\"address\":\"1.1.1.1\",\"rtt\":\"10ms\"}]}]}"), title: "test").ok)
    }
    func testSettingsRoundTripAndDuplicateProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        var settings = Settings.defaults
        settings.service = "USB Ethernet"
        try store.save(settings)
        XCTAssertEqual(try store.load().service, "USB Ethernet")
        settings.resolvers.append(settings.resolvers[0])
        XCTAssertThrowsError(try store.save(settings))
        XCTAssertEqual(try store.load().resolvers.count, Settings.defaults.resolvers.count)
    }
    func testDisabledNetworkServicesExcluded() {
        XCTAssertEqual(Manager.parseServices("An asterisk denotes a disabled service.\nWi-Fi\n*Ethernet\nUSB LAN\n"), ["Wi-Fi", "USB LAN"])
    }
    func testShellQuotingProtectsUserStrings() {
        XCTAssertEqual(Runner.shellQuote("a'b $x"), "'a'\\''b $x'")
    }
    func testTimeoutStopsChild() {
        XCTAssertThrowsError(try Runner.run("/bin/sleep", ["5"], timeout: 0.1))
    }
    func testGeneratedConfigWithRealProxy() throws {
        guard let proxy = Runner.executable("dnscrypt-proxy") else { print("dnscrypt-proxy absent : contrôle TOML réel ignoré."); return }
        let manager = Manager()
        let original = (try? String(contentsOfFile: manager.configPath, encoding: .utf8)) ?? ""
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: file) }
        for resolver in Settings.defaults.resolvers.filter(\.canActivate) {
            let text = try Manager.configuredTOML(original, resolver: resolver)
            try text.write(to: file, atomically: true, encoding: .utf8)
            let result = try Runner.run(proxy, ["-config", file.path, "-check"])
            XCTAssertTrue(result.succeeded)
            if !result.succeeded { print(result.output) }
        }
    }
    func testDoHAutoStampAndPlainLAN() {
        let custom = Resolver(id: "home", name: "Home", endpoint: "https://dns.example.com/dns-query")
        XCTAssertTrue(custom.canActivate)
        XCTAssertEqual(custom.activationStamp, "sdns://AgAAAAAAAAAAAAAPZG5zLmV4YW1wbGUuY29tCi9kbnMtcXVlcnk")
        XCTAssertFalse(Resolver(id: "lan", name: "LAN", endpoint: "192.0.2.53").canActivate)
        XCTAssertTrue(Resolver.dohStamp("https://user:password@dns.example.com/dns-query") == nil)
    }
    func testLANAndWiFiNamesAndFiltering() {
        let order = """
        An asterisk denotes a disabled service.
        (1) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en7)
        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (3) iPhone USB
        (Hardware Port: iPhone USB, Device: en9)
        (4) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        (5) VPN démo
        (Hardware Port: com.wireguard.macos, Device: )
        (*) Disabled Ethernet
        (Hardware Port: Ethernet, Device: en4)
        """
        let connections = NetworkParser.connections(order, defaultDevice: "en7")
        XCTAssertEqual(connections.map(\.label), ["LAN", "Wi-Fi"])
        XCTAssertEqual(connections.first?.service, "USB 10/100/1000 LAN")
        XCTAssertEqual(connections.first?.device, "en7")
        XCTAssertTrue(connections.first?.active == true)
        XCTAssertEqual(NetworkParser.defaultDevice("  interface: en7\n"), "en7")
    }
    func testVPNDetectionAndDNSAreNotRemoteAddress() throws {
        let list = "* (Connected) 00000000-0000-4000-8000-000000000001 VPN (com.wireguard.macos) \"VPN démo\" [VPN:com.wireguard.macos]\n* (Connecting) 00000000-0000-4000-8000-000000000002 VPN (other.client) \"Other VPN\" [VPN:other.client]"
        let vpns = NetworkParser.vpns(list)
        XCTAssertEqual(vpns.count, 2)
        XCTAssertEqual(vpns[0].client, "WireGuard")
        XCTAssertTrue(vpns[0].connected)
        XCTAssertEqual(vpns[1].stateLabel, "connexion en cours")
        let status = """
        DNSServers : <array> {
          0 : 192.0.2.53
        }
        InterfaceName : utun6
        ServerAddress : 127.0.0.1
        RemoteAddress : 127.0.0.1
        """
        let connection = NetworkParser.vpnDetails(status, connection: vpns[0])
        XCTAssertEqual(connection.dns, ["192.0.2.53"])
        XCTAssertEqual(connection.device, "utun6")
        let local = NetworkParser.vpnDetails("DNSServers : <array> {\n0 : 127.0.0.1\n}\n", connection: vpns[0])
        XCTAssertEqual(local.dns, ["127.0.0.1"])
    }
    func testAdminRequestsRejectUnrelatedPrivileges() throws {
        XCTAssertThrowsError(try AdminRequest(action: "shell").validate())
        XCTAssertThrowsError(try AdminRequest(action: "mode", service: "Wi-Fi", mode: "arbitrary").validate())
        XCTAssertThrowsError(try AdminRequest(action: "activate", service: "Wi-Fi", resolver: Resolver(id: "x", name: "X", endpoint: "192.0.2.53")).validate())
        XCTAssertThrowsError(try AdminRequest(action: "mode", service: "Wi-Fi", mode: "local", domain: "example.com; id").validate())
        try AdminRequest(action: "status").validate()
        try AdminRequest(action: "flush").validate()
        try AdminRequest(action: "mode", service: "Wi-Fi", mode: "local", domain: "example.com").validate()
    }
    func testOneAuthorizationTransactionSyntax() throws {
        let script = try Manager.configurationTransaction(config: "/tmp/config.toml", stage: "/tmp/a file's.toml", backup: "/tmp/config.bak", service: "LAN's adapter", addresses: ["127.0.0.1", "::1"], previousDNS: ["192.0.2.53"], domain: "example.com", testLocal: true, brew: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: file) }
        try script.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Runner.run("/bin/sh", ["-n", file.path]).succeeded)
        XCTAssertTrue(script.contains("trap rollback EXIT"))
        XCTAssertTrue(script.contains("'LAN'\\''s adapter'"))
        XCTAssertThrowsError(try Manager.configurationTransaction(config: "/tmp/config", stage: "/tmp/stage", backup: "/tmp/backup", service: "Wi-Fi", addresses: ["x; id"], previousDNS: [], domain: "example.com", testLocal: true, brew: nil))
    }
    func testGenericDefaultsAndLegacySettingsMigration() throws {
        let defaults = Settings.defaults
        XCTAssertTrue(defaults.lanResolver.isEmpty)
        let publicHosts = Set(["cloudflare-dns.com", "dns.quad9.net", "dns10.quad9.net"])
        XCTAssertTrue(defaults.resolvers.allSatisfy { publicHosts.contains(URLComponents(string: $0.endpoint)?.host ?? "") })
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        legacy.removeValue(forKey: "lanResolver"); legacy["homelab"] = "192.0.2.53"
        let loaded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(loaded.lanResolver, "192.0.2.53")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
        XCTAssertTrue(encoded["homelab"] == nil)
        XCTAssertEqual(encoded["lanResolver"] as? String, "192.0.2.53")
    }
    func testReleaseVersionConsistency() throws {
        let version = try String(contentsOfFile: "VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version, AppRelease.version)
    }
    func testDemoUsesDocumentedFixtures() {
        let demo = Manager.demoSnapshot()
        XCTAssertEqual(demo.selectedService, "Ethernet")
        XCTAssertEqual(demo.vpns.first?.id, "00000000-0000-4000-8000-000000000001")
        XCTAssertTrue(demo.checks.allSatisfy { $0.detail.contains("203.0.113.80") })
        XCTAssertTrue(demo.systemDNS.contains("fictives"))
    }
    func testPinnedDoHAddressPreservesTLSHostname() {
        let stamp = Resolver.dohStamp("https://dns.example.com/dns-query", address: "192.0.2.53")!
        let resolver = Resolver(id: "custom", name: "Custom", endpoint: "https://dns.example.com/dns-query", stamp: stamp)
        XCTAssertTrue(resolver.canActivate)
        XCTAssertEqual(resolver.stampAddress, "192.0.2.53")
        var encoded = String(stamp.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        XCTAssertTrue(Data(base64Encoded: encoded)!.range(of: Data("dns.example.com".utf8)) != nil)
        let ipv6 = Resolver.dohStamp("https://dns.example.com/dns-query", address: "2001:db8::53")!
        XCTAssertEqual(Resolver(id: "v6", name: "V6", endpoint: "https://dns.example.com/dns-query", stamp: ipv6).stampAddress, "2001:db8::53")
        XCTAssertTrue(Resolver.dohStamp("https://dns.example.com/dns-query", address: "not-an-ip") == nil)
    }
}

do {
    let suite = CoreTests()
    suite.testIPValidationRejectsShellAndMalformedValues()
    try suite.testConfigurePreservesUnrelatedSectionsAndReplacesManagedBlock()
    try suite.testDoTStampCannotBeActivatedInProxy()
    suite.testDoggoEmptyOrFailedRepliesAreNeverGreen()
    try suite.testSettingsRoundTripAndDuplicateProtection()
    suite.testDisabledNetworkServicesExcluded()
    suite.testShellQuotingProtectsUserStrings()
    suite.testTimeoutStopsChild()
    try suite.testGeneratedConfigWithRealProxy()
    suite.testDoHAutoStampAndPlainLAN()
    suite.testLANAndWiFiNamesAndFiltering()
    try suite.testVPNDetectionAndDNSAreNotRemoteAddress()
    try suite.testAdminRequestsRejectUnrelatedPrivileges()
    try suite.testOneAuthorizationTransactionSyntax()
    try suite.testGenericDefaultsAndLegacySettingsMigration()
    try suite.testReleaseVersionConsistency()
    suite.testDemoUsesDocumentedFixtures()
    suite.testPinnedDoHAddressPreservesTLSHostname()
} catch { failures += 1; print("ÉCHEC : \(error)") }
print(failures == 0 ? "✓ 18 scénarios de vérification réussis." : "✗ \(failures) échec(s).")
exit(failures == 0 ? 0 : 1)
