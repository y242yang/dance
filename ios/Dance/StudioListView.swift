import SwiftUI

struct StudioListView: View {
    @State private var studios: [Studio] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView("Loading studios…")
                    .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48)).foregroundStyle(.orange)
                    Text("Could not load studios").font(.headline).foregroundStyle(.white)
                    Text(err).font(.caption).foregroundStyle(Color(white: 0.5))
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try Again") { Task { await fetch() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(studios) { studio in
                            StudioRow(studio: studio)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Studios")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await fetch() }
    }

    private func fetch() async {
        isLoading = true
        errorMessage = nil
        do {
            let result: [Studio] = try await supabase
                .from("studios")
                .select("name, schedule_urls")
                .order("name", ascending: true)
                .execute()
                .value
            // Deduplicate by name (e.g. How About Dance has San Jose + San Mateo locations)
            var seen = Set<String>()
            let deduped = result.filter { seen.insert($0.name).inserted }
            await MainActor.run {
                studios = deduped
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Studio Row

struct StudioRow: View {
    let studio: Studio
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let urlStr = studio.scheduleUrl,
                  let url = URL(string: urlStr) else { return }
            openURL(url)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                }

                Text(studio.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.4))
            }
            .padding(16)
            .background(Color(white: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
