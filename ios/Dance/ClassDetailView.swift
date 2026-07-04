import SwiftUI
import EventKit
import EventKitUI

struct ClassDetailView: View {
    let cls: DanceClass
    @State private var showCalendar = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero header
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: [cls.styleColor.opacity(0.35), Color.black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 200)

                        VStack(alignment: .leading, spacing: 6) {
                            if let style = cls.danceStyle, !style.isEmpty {
                                Text(style.uppercased())
                                    .font(.caption).fontWeight(.bold)
                                    .tracking(1.5)
                                    .foregroundStyle(cls.styleColor)
                            }

                            Text(cls.title)
                                .font(.title2).fontWeight(.bold)
                                .foregroundStyle(.white)

                            if let instructor = cls.instructor, !instructor.isEmpty {
                                Text("with \(instructor)")
                                    .font(.subheadline)
                                    .foregroundStyle(Color(white: 0.65))
                            }

                            if let level = cls.level {
                                HStack(spacing: 6) {
                                    Circle().fill(level.levelColor).frame(width: 7, height: 7)
                                    Text(level.levelDisplayName)
                                        .font(.subheadline)
                                        .foregroundStyle(level.levelColor)
                                }
                            }
                        }
                        .padding(20)
                    }

                    // Info card
                    VStack(spacing: 0) {
                        DarkDetailRow(icon: "calendar", label: "Date", value: cls.date.dateLabel)
                        Separator()
                        DarkDetailRow(
                            icon: "clock",
                            label: "Time",
                            value: cls.formattedTime + (cls.durationMinutes.map { " · \($0) min" } ?? "")
                        )
                        if let studio = cls.studios?.name {
                            Separator()
                            DarkDetailRow(icon: "building.2", label: "Studio", value: studio)
                        }
                        if let loc = cls.locations {
                            if let address = loc.address, !address.isEmpty {
                                Separator()
                                DarkDetailRow(icon: "mappin.and.ellipse", label: "Location", value: address)
                            } else if let city = loc.city, !city.isEmpty {
                                Separator()
                                DarkDetailRow(icon: "mappin.and.ellipse", label: "City", value: city)
                            }
                        }
                    }
                    .background(Color(white: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(16)

                    // Description
                    if let desc = cls.description, !desc.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("About this class")
                                .font(.headline).foregroundStyle(.white)
                            Text(desc)
                                .font(.body)
                                .foregroundStyle(Color(white: 0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    // Buttons
                    VStack(spacing: 12) {
                        if let urlStr = cls.studios?.scheduleUrl, let url = URL(string: urlStr) {
                            Link(destination: url) {
                                Label("Book this class", systemImage: "arrow.up.right")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(cls.styleColor)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        Button {
                            showCalendar = true
                        } label: {
                            Label("Add to Calendar", systemImage: "calendar.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(white: 0.15))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .sheet(isPresented: $showCalendar) {
                        CalendarEventSheet(cls: cls)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct DarkDetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Color(white: 0.5))
                .padding(.leading, 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption).foregroundStyle(Color(white: 0.45))
                Text(value)
                    .font(.subheadline).foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.vertical, 13)
    }
}

private struct Separator: View {
    var body: some View {
        Divider()
            .overlay(Color(white: 0.18))
            .padding(.leading, 50)
    }
}

private struct CalendarEventSheet: UIViewControllerRepresentable {
    let cls: DanceClass
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = cls.title

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        if let start = fmt.date(from: "\(cls.date) \(cls.startTime)") {
            event.startDate = start
            let minutes = Double(cls.durationMinutes ?? 60)
            event.endDate = start.addingTimeInterval(minutes * 60)
        }

        var notes: [String] = []
        if let instructor = cls.instructor, !instructor.isEmpty { notes.append("Instructor: \(instructor)") }
        if let studio = cls.studios?.name { notes.append("Studio: \(studio)") }
        if let address = cls.locations?.address, !address.isEmpty { notes.append(address) }
        else if let city = cls.locations?.city, !city.isEmpty { notes.append(city) }
        event.notes = notes.joined(separator: "\n")

        let vc = EKEventEditViewController()
        vc.event = event
        vc.eventStore = store
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    class Coordinator: NSObject, EKEventEditViewDelegate {
        let parent: CalendarEventSheet
        init(_ parent: CalendarEventSheet) { self.parent = parent }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            parent.dismiss()
        }
    }
}
