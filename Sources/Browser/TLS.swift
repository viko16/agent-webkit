import Foundation
import Security
import CryptoKit

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
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 1_048_576 else { throw BrowserError("invalid_certificate", "CA 文件超过 1 MiB") }
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
