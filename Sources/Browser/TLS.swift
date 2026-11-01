import Foundation
import Security
import CryptoKit
import Darwin

struct TLSConfiguration: Codable {
    let certificateDER: Data?
    let ignoreCertificateErrors: Bool?

    private init(ignoreCertificateErrors: Bool) {
        certificateDER = nil
        self.ignoreCertificateErrors = ignoreCertificateErrors
    }

    static var insecure: TLSConfiguration { TLSConfiguration(ignoreCertificateErrors: true) }

    init(path: String) throws {
        ignoreCertificateErrors = false
        guard !path.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        // Nonblocking open also lets us reject FIFOs without waiting for a writer.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        let limit = 1_048_576
        var data = Data()
        // Bound the reads themselves: the file can grow after fstat.
        while data.count <= limit {
            guard let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw BrowserError("invalid_certificate", "CA 文件超过 1 MiB") }
        if let pem = String(data: data, encoding: .utf8), pem.contains("-----BEGIN CERTIFICATE-----") {
            let parts = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            guard parts.count == 2, let body = parts.last?.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let der = Data(base64Encoded: body.filter { !$0.isWhitespace }) else {
                throw BrowserError("invalid_certificate", "请提供单张 PEM 或 DER CA 证书")
            }
            certificateDER = der
        } else { certificateDER = data }
        guard certificate != nil else { throw BrowserError("invalid_certificate", "无法解析 X.509 CA 证书") }
    }

    var certificate: SecCertificate? { certificateDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) } }
    var summary: [String: Any] {
        if ignoreCertificateErrors == true {
            return ["policy": "insecure", "hostnameValidation": false, "certificateErrorsIgnored": true,
                    "warning": "Only for controlled development: certificate chain, hostname and expiry errors are accepted in this Space."]
        }
        return ["policy": "custom-ca", "caSHA256": SHA256.hash(data: certificateDER ?? Data()).map { String(format: "%02x", $0) }.joined(),
         "systemAnchorsAllowed": true, "hostnameValidation": true, "certificateErrorsIgnored": false]
    }

    static var systemSummary: [String: Any] {
        ["policy": "system", "hostnameValidation": true, "certificateErrorsIgnored": false]
    }
}
