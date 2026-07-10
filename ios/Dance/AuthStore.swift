import Foundation
import Observation
import Supabase
import AuthenticationServices
import CryptoKit
import UIKit

@Observable
final class AuthStore: NSObject {
    private(set) var currentUserId: UUID?
    private(set) var username: String?
    private(set) var avatarUrl: String?
    private(set) var needsUsername: Bool = false
    private(set) var isLoadingProfile: Bool = false

    var isSignedIn: Bool { currentUserId != nil }

    private var currentNonce: String?
    private var signInContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        currentUserId = supabase.auth.currentSession?.user.id
        Task { await observeAuthChanges() }
    }

    private func observeAuthChanges() async {
        for await (event, session) in supabase.auth.authStateChanges {
            guard event == .initialSession || event == .signedIn || event == .signedOut else { continue }
            await MainActor.run { self.currentUserId = session?.user.id }
            if let userId = session?.user.id {
                await refreshProfile(userId: userId)
            } else {
                await MainActor.run {
                    self.username = nil
                    self.avatarUrl = nil
                    self.needsUsername = false
                }
            }
        }
    }

    @MainActor
    private func refreshProfile(userId: UUID) async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        do {
            let profile: ProfileRow? = try await supabase
                .from("profiles")
                .select("username, avatar_url")
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            username = profile?.username
            avatarUrl = profile?.avatarUrl
            needsUsername = profile == nil
        } catch {
            // No row found decodes as an error with .single(); treat as needing onboarding.
            username = nil
            avatarUrl = nil
            needsUsername = true
        }
    }

    func claimUsername(_ name: String) async throws {
        guard let userId = currentUserId else { return }
        try await supabase
            .from("profiles")
            .insert(["id": userId.uuidString, "username": name])
            .execute()
        await MainActor.run {
            self.username = name
            self.needsUsername = false
        }
    }

    /// Uploads a new avatar image to the "avatars" storage bucket (path
    /// "{userId}/avatar.jpg", overwriting any previous one) and points
    /// profiles.avatar_url at its public URL. A cache-busting query param is
    /// appended since the path itself doesn't change on re-upload.
    func updateAvatar(imageData: Data) async throws {
        guard let userId = currentUserId else { return }
        // Storage RLS compares this folder segment against auth.uid()::text, which
        // Postgres renders lowercase — Swift's uuidString is uppercase, so this must
        // be lowercased or every upload gets silently rejected by the policy.
        let path = "\(userId.uuidString.lowercased())/avatar.jpg"
        try await supabase.storage.from("avatars")
            .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg", upsert: true))

        var url = try supabase.storage.from("avatars").getPublicURL(path: path)
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
            url = components.url ?? url
        }

        try await supabase.from("profiles")
            .update(["avatar_url": url.absoluteString])
            .eq("id", value: userId)
            .execute()
        await MainActor.run { self.avatarUrl = url.absoluteString }
    }

    func signInWithApple() async throws {
        let nonce = Self.randomNonceString()
        currentNonce = nonce

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.signInContinuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    /// Permanently deletes the account (Apple Guideline 5.1.1(v) requires this
    /// be possible from within the app, not just by contacting support). Runs
    /// server-side via an Edge Function since it needs the service role key,
    /// which never ships in the client. Cascades to profiles/follows/
    /// saved_classes/log_entries automatically once the auth user is gone.
    func deleteAccount() async throws {
        try await supabase.functions.invoke("delete-account")
        try await supabase.auth.signOut()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ProfileRow: Codable {
    let username: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarUrl = "avatar_url"
    }
}

extension AuthStore: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              let nonce = currentNonce else {
            signInContinuation?.resume(throwing: URLError(.badServerResponse))
            signInContinuation = nil
            return
        }

        Task {
            do {
                try await supabase.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: identityToken, nonce: nonce)
                )
                signInContinuation?.resume()
            } catch {
                signInContinuation?.resume(throwing: error)
            }
            signInContinuation = nil
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        signInContinuation?.resume(throwing: error)
        signInContinuation = nil
    }
}
