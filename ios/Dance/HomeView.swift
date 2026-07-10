import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HeroHeader(onBrowseAll: { selectedTab = 1 })

                    if !authStore.isSignedIn {
                        CreateProfileCard(onSignIn: { selectedTab = 2 })
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Search in 5 ways")
                            .font(.title3).fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.top, 28)
                            .padding(.bottom, 6)

                        Button { selectedTab = 1 } label: {
                            SearchOptionContent(
                                icon: "calendar.badge.clock",
                                title: "Search by Date",
                                subtitle: "Pick a date or date range",
                                color: Color(red: 0.62, green: 0.35, blue: 1.0)
                            )
                        }.buttonStyle(.plain)
                        Button { selectedTab = 1 } label: {
                            SearchOptionContent(
                                icon: "figure.socialdance",
                                title: "Search by Dance Style",
                                subtitle: "Explore styles you love",
                                color: .pink
                            )
                        }.buttonStyle(.plain)
                        Button { selectedTab = 1 } label: {
                            SearchOptionContent(
                                icon: "chart.bar.fill",
                                title: "Search by Level",
                                subtitle: "Find classes that match your skill",
                                color: .orange
                            )
                        }.buttonStyle(.plain)
                        Button { selectedTab = 1 } label: {
                            SearchOptionContent(
                                icon: "mappin.circle.fill",
                                title: "Search by Location",
                                subtitle: "Find classes near you",
                                color: .green
                            )
                        }
                        .buttonStyle(.plain)
                        NavigationLink(destination: StudioListView()) {
                            SearchOptionContent(
                                icon: "building.2.fill",
                                title: "Search by Studio",
                                subtitle: "See what's happening at local studios",
                                color: .blue
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .toolbarBackground(Color.black, for: .navigationBar)
    }
}

// MARK: - Hero

struct HeroHeader: View {
    let onBrowseAll: () -> Void  // kept for future use

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Night sky gradient
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.06, blue: 0.32),
                    Color(red: 0.38, green: 0.12, blue: 0.22),
                    Color(red: 0.06, green: 0.03, blue: 0.06),
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            .ignoresSafeArea(edges: .top)

            // Stars
            GeometryReader { geo in
                let starData: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
                    (0.08, 0.12, 1.5, 0.9), (0.22, 0.05, 2.0, 0.7), (0.45, 0.08, 1.5, 0.8),
                    (0.62, 0.15, 2.5, 0.9), (0.78, 0.06, 1.5, 0.6), (0.90, 0.18, 2.0, 0.8),
                    (0.15, 0.28, 1.5, 0.5), (0.55, 0.22, 1.5, 0.7), (0.82, 0.30, 2.0, 0.6),
                    (0.35, 0.35, 1.5, 0.4), (0.70, 0.40, 1.5, 0.5),
                ]
                ForEach(Array(starData.enumerated()), id: \.offset) { _, s in
                    Circle()
                        .fill(Color.white.opacity(s.o))
                        .frame(width: s.r, height: s.r)
                        .position(x: s.x * geo.size.width, y: s.y * geo.size.height)
                }
                Image(systemName: "sparkles")
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.system(size: 22))
                    .position(x: geo.size.width * 0.74, y: geo.size.height * 0.20)
            }

            // Text content
            VStack(alignment: .leading, spacing: 6) {
                Text("Find your next")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.72))

                Text("Dance Class")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.pink, Color(red: 0.72, green: 0.42, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("in the Bay Area")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.62, green: 0.45, blue: 1.0))

                Spacer().frame(height: 10)

                NavigationLink(destination: LearnMoreView()) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                        Text("Learn More")
                            .font(.subheadline)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 290)
    }
}

// MARK: - Create Profile Card

struct CreateProfileCard: View {
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a profile")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Sign in to save classes and share with friends")
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.55))
                }
            }
            Button(action: onSignIn) {
                Text("Sign In")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Search Option Row

struct SearchOptionContent: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 54, height: 54)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.52))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.38))
        }
        .padding(16)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SearchOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SearchOptionContent(icon: icon, title: title, subtitle: subtitle, color: color)
        }
        .buttonStyle(.plain)
    }
}
