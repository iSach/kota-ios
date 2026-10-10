import AuthenticationServices
import CryptoKit
import Network
import UIKit

/// "Sign in with ChatGPT" using the Codex CLI's OAuth (PKCE) flow. That client only allows a
/// http://localhost:1455 redirect, so we listen on that port while the system sign-in sheet is up.
@MainActor
final class CodexSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var listener: NWListener?
    private var session: ASWebAuthenticationSession?

    static func run(for account: Account) async throws {
        let verifier = self.randomToken()
        let state = self.randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let code = try await CodexSignIn().authorizationCode(
            url: UsageFetcher.codexAuthorizeURL(challenge: challenge, state: state),
            state: state)
        try await UsageFetcher.codexToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": UsageFetcher.codexRedirectURI,
            "code_verifier": verifier,
        ], for: account)
    }

    private func authorizationCode(url: URL, state: String) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback // never reachable from the network
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: 1455)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let result = Result { try UsageFetcher.codexCallbackCode(request: request, state: state) }
                let (status, body) = switch result {
                case .success(.some): ("200 OK", "Signed in. Returning to Kota…")
                case .success(.none): ("404 Not Found", "")
                case .failure: ("400 Bad Request", "Sign-in failed. Close this and try again in Kota.")
                }
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                Task { @MainActor in
                    switch result {
                    case let .success(code?): self.finish(.success(code))
                    case .success(nil): break
                    case let .failure(error): self.finish(.failure(error))
                    }
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { Task { @MainActor in self.finish(.failure(error)) } }
        }
        listener.start(queue: .main)

        // No callback scheme: the redirect lands on our listener, and finish() dismisses the sheet.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
            Task { @MainActor in self.finish(.failure(error ?? CancellationError())) }
        }
        session.presentationContextProvider = self
        // Private session: no shared Safari cookies, so a second account doesn't silently reuse the first.
        session.prefersEphemeralWebBrowserSession = true
        self.listener = listener
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if !session.start() { self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.listener?.cancel()
        self.session?.cancel()
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                ?? ASPresentationAnchor()
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
