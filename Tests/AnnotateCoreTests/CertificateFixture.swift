import Foundation
import Security
import Testing

@MainActor
struct CertificateFixture {
    let directory: URL
    let identity: SecIdentity
    let certificate: SecCertificate

    /// A disposable self-signed identity. `extensions` are OpenSSL `-addext` values, such
    /// as `extendedKeyUsage=serverAuth`; with none, the certificate has no extensions.
    init(extensions: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-certificate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "certificate.pem", "-days", "1", "-subj", "/CN=Annotate Disposable Test Certificate"]
                + extensions.flatMap { ["-addext", $0] }, in: directory)
            try Self.openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "certificate.pem", "-out", "fixture.p12", "-passout", "pass:disposable-test-only"], in: directory)
            let data = try Data(contentsOf: directory.appendingPathComponent("fixture.p12"))
            var imported: CFArray?
            // The default macOS import writes identities to Keychain. This explicit
            // macOS 15+ option keeps the disposable fixture entirely in memory.
            let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: "disposable-test-only", kSecImportToMemoryOnly: true] as CFDictionary, &imported)
            #expect(status == errSecSuccess)
            let values = try #require(imported as? [[String: Any]])
            let value = try #require(values.first?[kSecImportItemIdentity as String])
            identity = value as! SecIdentity
            var cert: SecCertificate?
            #expect(SecIdentityCopyCertificate(identity, &cert) == errSecSuccess)
            certificate = try #require(cert)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    static func openssl(_ arguments: [String], in directory: URL, shouldSucceed: Bool = true) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let log = directory.appendingPathComponent("openssl-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        if shouldSucceed { #expect(process.terminationStatus == 0, "Disposable OpenSSL fixture or independent signature verification failed. Inspect \(log.path).") }
        return process.terminationStatus
    }
}
