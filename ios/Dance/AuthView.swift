import SwiftUI
import AuthenticationServices

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

struct AuthView: View {
    @Environment(AuthStore.self) private var authStore
    @State private var isSigningIn = false
    @State private var error: String?

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(kAccent)
                Text("Follow your dance friends")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("Sign in to follow friends and see the classes they've saved and logged.")
                    .font(.subheadline)
                    .foregroundStyle(kSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 40)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        if isSigningIn {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "apple.logo")
                        }
                        Text("Sign in with Apple")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSigningIn)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { error = nil }
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        do {
            try await authStore.signInWithApple()
        } catch let authError as ASAuthorizationError where authError.code == .canceled {
            // User dismissed the sign-in sheet — a deliberate choice, not a failure.
        } catch {
            self.error = error.localizedDescription
        }
        isSigningIn = false
    }
}
