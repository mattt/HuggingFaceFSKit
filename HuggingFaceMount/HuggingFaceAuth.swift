import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

@MainActor
@Observable
final class HuggingFaceAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    let clientID = "hf_oauth_client_id_replace_me"
    var manualToken: String = ""
    var repoPath: String = "gpt2"
    var revision: String = "main"
    var mountPoint: String = "~/Volumes/HFMount"
    var isAuthenticating = false
    var statusMessage: String = "No token in shared keychain."

    private let callbackScheme = "hfmount"
    private let callbackURL = "hfmount://oauth/callback"
    private var authSession: ASWebAuthenticationSession?
    private var codeVerifier = ""
    private var expectedState = ""

    func startOAuthSignIn() {
        let verifier = randomURLSafeString(length: 64)
        let state = randomURLSafeString(length: 32)
        guard let challenge = challengeFromVerifier(verifier) else {
            statusMessage = "Could not create PKCE challenge."
            return
        }

        var components = URLComponents(string: "https://huggingface.co/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read-repos"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authorizeURL = components?.url else {
            statusMessage = "Could not build authorize URL."
            return
        }

        codeVerifier = verifier
        expectedState = state
        isAuthenticating = true
        statusMessage = "Waiting for OAuth approval..."

        authSession = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if let error {
                    self.statusMessage = "Auth cancelled: \(error.localizedDescription)"
                    return
                }
                guard let callbackURL else {
                    self.statusMessage = "No callback URL."
                    return
                }
                await self.handleCallback(callbackURL: callbackURL)
            }
        }

        authSession?.prefersEphemeralWebBrowserSession = true
        authSession?.presentationContextProvider = self
        _ = authSession?.start()
    }

    func saveManualToken() {
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a token before saving."
            return
        }

        do {
            try SharedHFTokenStore.saveAccessToken(token)
            manualToken = ""
            statusMessage = "Token saved to shared keychain."
        } catch {
            statusMessage = "Failed to save token: \(error.localizedDescription)"
        }
    }

    func clearToken() {
        do {
            try SharedHFTokenStore.deleteAccessToken()
            statusMessage = "Stored token removed."
        } catch {
            statusMessage = "Failed to clear token: \(error.localizedDescription)"
        }
    }

    func refreshStatus() {
        do {
            let token = try SharedHFTokenStore.readAccessToken()
            statusMessage = token == nil ? "No token in shared keychain." : "Token present in shared keychain."
        } catch {
            statusMessage = "Keychain read failed: \(error.localizedDescription)"
        }
    }

    func mountVolume() {
        let repoPath = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoPath.isEmpty else {
            statusMessage = "Enter a Hugging Face repo path first."
            return
        }

        let mountPoint = NSString(string: mountPoint).expandingTildeInPath
        let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : revision.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = repositoryURLString(from: repoPath, revision: revision)

        statusMessage = "Mounting..."
        Task.detached {
            do {
                try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
                _ = try Self.runProcess("/sbin/mount", arguments: ["-t", "hfmount", urlString, mountPoint])
                await MainActor.run {
                    self.statusMessage = "Mounted \(urlString) at \(mountPoint)"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Mount failed: \(error.localizedDescription). If needed, enable extension once from Terminal with: pluginkit -e use -i co.dododo.HuggingFaceMount.HuggingFaceFS"
                }
            }
        }
    }

    func unmountVolume() {
        let mountPoint = NSString(string: mountPoint).expandingTildeInPath
        statusMessage = "Unmounting..."
        Task.detached {
            do {
                _ = try Self.runProcess("/sbin/umount", arguments: [mountPoint])
                await MainActor.run {
                    self.statusMessage = "Unmounted \(mountPoint)"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Unmount failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    private func handleCallback(callbackURL: URL) async {
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
            state == expectedState
        else {
            statusMessage = "OAuth state mismatch."
            return
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            statusMessage = "No authorization code in callback."
            return
        }

        do {
            let token = try await exchangeCodeForToken(code: code, verifier: codeVerifier)
            try SharedHFTokenStore.saveAccessToken(token)
            statusMessage = "OAuth complete. Token saved to shared keychain."
        } catch {
            statusMessage = "Token exchange failed: \(error.localizedDescription)"
        }
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://huggingface.co/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: callbackURL),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: text])
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return payload.accessToken
    }

    private func challengeFromVerifier(_ verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }

    private func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func repositoryURLString(from pathOrURL: String, revision: String) -> String {
        if pathOrURL.hasPrefix("https://") || pathOrURL.hasPrefix("http://") {
            if pathOrURL.contains("?") {
                return pathOrURL
            }
            return "\(pathOrURL)?revision=\(revision)"
        }
        return "https://huggingface.co/\(pathOrURL)?revision=\(revision)"
    }

    nonisolated private static func runProcess(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let reason = output.isEmpty ? "command failed with status \(process.terminationStatus)" : output
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return output
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private enum SharedHFTokenStore {
    private static let service = "co.dododo.HuggingFaceMount"
    private static let account = "hf_access_token"
    private static let logicalAccessGroupSuffix = ".co.dododo.HuggingFaceMount.shared"

    static func saveAccessToken(_ token: String) throws {
        try deleteAccessToken()
        let data = Data(token.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        if let group = accessGroup() {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func readAccessToken() throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group = accessGroup() {
            query[kSecAttrAccessGroup as String] = group
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAccessToken() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup() {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func accessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return nil
        }
        guard let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else {
            return nil
        }
        guard let groups = value as? [String] else {
            return nil
        }
        for group in groups {
            if group.hasSuffix(logicalAccessGroupSuffix) {
                return group
            }
        }
        return groups.first
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
