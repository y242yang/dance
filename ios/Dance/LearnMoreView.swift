import SwiftUI

struct LearnMoreView: View {
    @State private var studios: [String] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    InfoCard(
                        icon: "clock.fill",
                        iconColor: Color(red: 0.62, green: 0.35, blue: 1.0),
                        title: "Updated once daily",
                        detail: "The schedule refreshes every morning at 6 AM with the latest classes from each studio."
                    )

                    InfoCard(
                        icon: "calendar",
                        iconColor: .pink,
                        title: "Classes in the next 2 weeks",
                        detail: "We only surface classes happening within the next 14 days, so everything you see is coming up soon."
                    )

                    InfoCard(
                        icon: "exclamationmark.circle.fill",
                        iconColor: .yellow,
                        title: "Drop-in classes only",
                        detail: "Multi-class workshops and courses are not listed here. Check each studio's website directly for their workshop offerings."
                    )

                    // Studios card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.18))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "building.2.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Tracked studios")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("We currently pull schedules from these Bay Area studios:")
                                    .font(.subheadline)
                                    .foregroundStyle(Color(white: 0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(studios.enumerated()), id: \.offset) { idx, studio in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Color(white: 0.35))
                                        .frame(width: 5, height: 5)
                                    Text(studio)
                                        .font(.subheadline)
                                        .foregroundStyle(Color(white: 0.80))
                                    Spacer()
                                }
                                .padding(.vertical, 7)
                                if idx < studios.count - 1 {
                                    Divider().overlay(Color(white: 0.18))
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(18)
                    .background(Color(white: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    RequestStudioCard()

                    Spacer().frame(height: 16)
                }
                .padding(20)
            }
        }
        .navigationTitle("Learn More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            guard studios.isEmpty else { return }
            if let result = try? await supabase
                .from("studios")
                .select("name")
                .order("name", ascending: true)
                .execute()
                .value as [Studio]
            {
                var seen = Set<String>()
                studios = result.map(\.name).filter { seen.insert($0).inserted }
            }
        }
    }
}

// MARK: - Request Studio Card

struct RequestStudioCard: View {
    @State private var showForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Request a studio")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Don't see your studio? Let us know and we'll look into adding it.")
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                showForm = true
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("Request a Studio")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.green.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showForm) {
            RequestStudioSheet()
        }
    }
}

// MARK: - Request Studio Form Sheet

struct RequestStudioSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var studioName = ""
    @State private var websiteURL = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !studioName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !websiteURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle bar
                Capsule()
                    .fill(Color(white: 0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 28)

                if submitted {
                    successView
                } else {
                    formView
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Request a Studio")
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("We'll review your request and add it if we can.")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.5))
            }

            VStack(spacing: 14) {
                DarkField(label: "Studio name", placeholder: "e.g. City Dance Studios", text: $studioName)
                DarkField(label: "Scheduling website URL", placeholder: "e.g. https://studiobooking.com", text: $websiteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                submit()
            } label: {
                HStack {
                    if isSubmitting {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    }
                    Text(isSubmitting ? "Submitting…" : "Submit Request")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmit ? Color.green : Color(white: 0.2))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canSubmit || isSubmitting)
            .animation(.easeInOut(duration: 0.15), value: canSubmit)

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }
            Text("Request submitted!")
                .font(.title3).fontWeight(.bold)
                .foregroundStyle(.white)
            Text("Thanks for the suggestion. We'll look into adding this studio.")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Done") { dismiss() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(white: 0.15))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await supabase
                    .from("studio_requests")
                    .insert([
                        "studio_name": studioName.trimmingCharacters(in: .whitespaces),
                        "website_url": websiteURL.trimmingCharacters(in: .whitespaces),
                    ])
                    .execute()
                await MainActor.run { submitted = true }
            } catch {
                await MainActor.run {
                    errorMessage = "Something went wrong. Please try again."
                    isSubmitting = false
                }
            }
        }
    }
}

// MARK: - Dark Text Field

struct DarkField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color(white: 0.55))
                .textCase(.uppercase)
                .tracking(0.5)
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(white: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(white: 0.22), lineWidth: 1)
                )
        }
    }
}

// MARK: - Info Card

struct InfoCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
