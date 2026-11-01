import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// OAuth 2.1 for remote MCP servers: discovery, dynamic client registration and PKCE.
/// Tokens are stored in the Keychain per server.
enum MCPOAuth {
    struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiry: Date
        var clientID: String
        var tokenEndpoint: String
        var resource: String
    }

    static let redirect = "dosanjhai://oauth/callback"

    // MARK: Using stored tokens

    static func accessToken(for server: MCPServerSnapshot) async throws -> String? {
        if let pasted = Keychain.get(server.tokenAccount), !pasted.isEmpty { return pasted }
        guard let raw = Keychain.get(server.oauthAccount), var stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)) else { return nil }
        if stored.expiry.timeIntervalSinceNow < 60, let refresh = stored.refreshToken {
            let reply = try await token(endpoint: stored.tokenEndpoint, form: [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": stored.clientID, "resource": stored.resource,
            ])
            stored.accessToken = reply.access
            stored.refreshToken = reply.refresh ?? refresh
            stored.expiry = Date().addingTimeInterval(reply.expiresIn)
            Keychain.set(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), for: server.oauthAccount)
        }
        return stored.accessToken
    }

    // MARK: Sign in

    @MainActor
    static func signIn(serverURL: URL, resourceMetadata: URL?, tokenAccount: String, oauthAccount: String) async throws {
        let origin = URL(string: "\(serverURL.scheme ?? "https")://\(serverURL.host ?? "")")!
        let metadataURL = resourceMetadata ?? origin.appending(path: ".well-known/oauth-protected-resource")
        let resourceMeta = try await getJSON(metadataURL)
        guard let issuer = resourceMeta["authorization_servers"]?.array?.first?.string, let issuerURL = URL(string: issuer) else {
            throw MCPError.server("This server doesn't describe how to sign in.")
        }
        let server = try await authorizationServerMetadata(issuerURL)
        guard let authorize = server["authorization_endpoint"]?.string, let tokenEndpoint = server["token_endpoint"]?.string else {
            throw MCPError.server("The sign-in service is incomplete.")
        }
        guard let registration = server["registration_endpoint"]?.string else {
            throw MCPError.server("This server needs a pre-registered app, which DosanjhAI can't do. Paste an access token instead.")
        }
        let register = try await postJSON(try secure(registration), body: [
            "client_name": .string("DosanjhAI"), "redirect_uris": .array([.string(redirect)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]), "token_endpoint_auth_method": .string("none"),
        ])
        guard let clientID = register["client_id"]?.string else { throw MCPError.server("Sign-in registration failed.") }

        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        let resource = resourceMeta["resource"]?.string ?? serverURL.absoluteString
        guard var comps = URLComponents(url: try secure(authorize), resolvingAgainstBaseURL: false) else { throw MCPError.server("Bad sign-in address.") }
        var items = comps.queryItems ?? []
        items += [.init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                  .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                  .init(name: "state", value: state), .init(name: "resource", value: resource)]
        if let scopes = resourceMeta["scopes_supported"]?.array?.compactMap(\.string), !scopes.isEmpty {
            items.append(.init(name: "scope", value: scopes.joined(separator: " ")))
        }
        comps.queryItems = items

        guard let authURL = comps.url else { throw MCPError.server("Bad sign-in address.") }
        let callback = try await WebAuth.run(url: authURL, scheme: "dosanjhai")
        let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard returned.first(where: { $0.name == "state" })?.value == state, let code = returned.first(where: { $0.name == "code" })?.value else {
            throw MCPError.server("Sign-in was cancelled or failed.")
        }
        let reply = try await token(endpoint: tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientID, "code_verifier": verifier, "resource": resource,
        ])
        let stored = Stored(accessToken: reply.access, refreshToken: reply.refresh, expiry: Date().addingTimeInterval(reply.expiresIn),
                            clientID: clientID, tokenEndpoint: tokenEndpoint, resource: resource)
        Keychain.delete(tokenAccount)
        Keychain.set(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), for: oauthAccount)
    }

    // MARK: Helpers

    private static func authorizationServerMetadata(_ issuer: URL) async throws -> JSONValue {
        let origin = URL(string: "\(issuer.scheme ?? "https")://\(issuer.host ?? "")\(issuer.port.map { ":\($0)" } ?? "")")!
        let path = issuer.path == "/" ? "" : issuer.path
        for candidate in [origin.appending(path: ".well-known/oauth-authorization-server" + path),
                          issuer.appending(path: ".well-known/oauth-authorization-server"),
                          issuer.appending(path: ".well-known/openid-configuration")] {
            if let json = try? await getJSON(candidate), json["token_endpoint"] != nil { return json }
        }
        throw MCPError.server("Couldn't find the sign-in service for this server.")
    }

    private static func getJSON(_ url: URL) async throws -> JSONValue {
        let (data, response) = try await AppNet.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw MCPError.server("Couldn't reach the sign-in service.")
        }
        return json
    }

    private static func postJSON(_ url: URL, body: [String: JSONValue]) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, _) = try await AppNet.session.data(for: request)
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }

    private static func token(endpoint: String, form: [String: String]) async throws -> (access: String, refresh: String?, expiresIn: TimeInterval) {
        var request = URLRequest(url: try secure(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (data, _) = try await AppNet.session.data(for: request)
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), let access = json["access_token"]?.string else {
            throw MCPError.server("Sign-in didn't return a token.")
        }
        return (access, json["refresh_token"]?.string, TimeInterval(json["expires_in"]?.int ?? 3600))
    }

    /// Server-supplied addresses must be https; a plain-http token endpoint would leak the sign-in code.
    private static func secure(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { throw MCPError.server("The sign-in service gave an insecure or invalid address.") }
        return url
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Presents the system sign-in sheet.
@MainActor
private enum WebAuth {
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
    private static let anchor = Anchor()
    private static var session: ASWebAuthenticationSession?

    static func run(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? MCPError.server("Sign-in was cancelled.")) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            Self.session = session
            if !session.start() { continuation.resume(throwing: MCPError.server("Couldn't open the sign-in window.")) }
        }
    }
}

/// The parts of a server record the OAuth code needs, safe to pass across threads.
struct MCPServerSnapshot: Sendable {
    let id: UUID
    let name: String
    let url: URL
    let readOnly: Bool
    let tokenAccount: String
    let oauthAccount: String
}
