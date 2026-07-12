import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

struct ChooseUsernameView: View {
    @Environment(AuthStore.self) private var authStore
    @State private var username = ""
    @State private var isSaving = false
    @State private var error: String?

    private var isValid: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.count <= 20
            && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "at")
                    .font(.system(size: 48))
                    .foregroundStyle(kAccent)
                Text("Choose a username")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("This is how friends will find you to follow.")
                    .font(.subheadline)
                    .foregroundStyle(kSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color(white: 0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("One word, no spaces — like a handle")
                        .font(.caption)
                        .foregroundStyle(kSecondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 40)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Continue")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isValid ? kAccent : Color(white: 0.25))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isValid || isSaving)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await authStore.claimUsername(username.trimmingCharacters(in: .whitespaces).lowercased())
        } catch {
            self.error = "That username is taken — try another."
        }
        isSaving = false
    }
}
