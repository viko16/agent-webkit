import Security
import WebKit

extension Tab {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, affectsPage: true, completionHandler: completionHandler)
    }
    func authenticate(_ challenge: URLAuthenticationChallenge, affectsPage: Bool,
                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let tls else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host
        if tls.ignoreCertificateErrors == true {
            if affectsPage { tlsChallenge = ["host": host, "policy": "insecure", "accepted": true, "certificateErrorsIgnored": true] }
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        guard let certificate = tls.certificate,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
            if affectsPage { certificateError = BrowserError("certificate_rejected", "无法为 \(host) 配置 Space CA") }
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Keep WebKit's SSL/hostname policies. Only add this Space's anchor to this trust object.
        // Security requires this call to originate on the callback queue (the main queue here).
        let status = SecTrustEvaluateAsyncWithError(trust, .main) { [weak self] trust, accepted, error in
            let message = error.map { CFErrorCopyDescription($0) as String } ?? ""
            let details = accepted ? "" : String(describing: SecTrustCopyResult(trust))
            Task { @MainActor in
                if affectsPage { self?.tlsChallenge = ["host": host, "policy": "custom-ca", "accepted": accepted, "error": message, "details": details] }
                if accepted { completionHandler(.useCredential, URLCredential(trust: trust)) }
                else {
                    if affectsPage { self?.certificateError = BrowserError("certificate_rejected", "\(host): \(message)") }
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }
        if status != errSecSuccess {
            if affectsPage { certificateError = BrowserError("certificate_rejected", "\(host): SecTrust evaluation failed (\(status))") }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
