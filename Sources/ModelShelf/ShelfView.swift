#if os(macOS)  // the menu bar panel; Linux and Windows print the list instead (App.swift)
import AppKit
import ShelfCore
import SwiftUI

// MARK: - Look

private let sections: [(id: String, name: String, hint: String, color: Color)] = [
    ("used", "In use", "A job or skill uses these", Color(nsColor: .systemGreen)),
    ("idle", "Resting", "Kept, but no job runs them now", Color(nsColor: .systemOrange)),
    ("unused", "Leftovers", "Nothing uses these", Color(nsColor: .systemGray)),
]

private func swatch(_ name: String) -> Color {
    let map: [String: NSColor] = ["pink": .systemPink, "orange": .systemOrange, "blue": .systemBlue, "teal": .systemTeal,
                                  "purple": .systemPurple, "indigo": .systemIndigo, "red": .systemRed, "mint": .systemMint,
                                  "cyan": .systemCyan, "yellow": .systemYellow, "green": .systemGreen, "gray": .systemGray]
    return Color(nsColor: map[name] ?? .systemGray)
}

struct ShelfView: View {
    @EnvironmentObject var shelf: Shelf
    @State private var open: String?

    init(open: String? = nil) { _open = State(initialValue: open) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let scan = shelf.scan {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.id) { sec in
                            let list = scan.entries.filter { $0.section == sec.id }
                            if !list.isEmpty {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(sec.name)
                                        Spacer()
                                        Text(gbText(list.reduce(0) { $0 + $1.gb })).monospacedDigit()
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    Text(sec.hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                                ForEach(list) { e in
                                    ModelRow(entry: e, isOpen: open == e.id) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { open = open == e.id ? nil : e.id }
                                    }
                                    .id(e.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .frame(height: 520)  // a menu bar panel shrinks a scroll list to nothing without a set height
                .onAppear { if let open { proxy.scrollTo(open, anchor: .center) } }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the disk").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 380)
        .onAppear { shelf.refreshIfOld() }
    }

    private var header: some View {
        let entries = shelf.scan?.entries ?? []
        let total = entries.reduce(0) { $0 + $1.gb }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models").font(.system(size: 15, weight: .bold))
                Spacer()
                if !entries.isEmpty {
                    Text("\(gbText(total)) · \(entries.count) models").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Button { shelf.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(shelf.busy ? 360 : 0))
                        .animation(shelf.busy ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: shelf.busy)
                }
                .buttonStyle(.borderless).help("Check again")
            }
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(sections, id: \.id) { sec in
                            let gb = entries.filter { $0.section == sec.id }.reduce(0) { $0 + $1.gb }
                            if gb > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(sec.color)
                                    .frame(width: max(2, (geo.size.width - 4) * gb / total))
                            }
                        }
                    }
                }
                .frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 14) {
                    ForEach(sections, id: \.id) { sec in
                        let gb = entries.filter { $0.section == sec.id }.reduce(0) { $0 + $1.gb }
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(sec.color).frame(width: 8, height: 8)
                            Text("\(sec.name) \(gbText(gb))").monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(shelf.scan?.warnings ?? [], id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            if let at = shelf.scan?.at {
                Text("Checked \(at.formatted(date: .omitted, time: .shortened)) · only reads")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}

struct ModelRow: View {
    let entry: Entry
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false

    // What it does in a few words (from the settings), then who uses it; a new download says when it arrived.
    private var subtitle: String {
        if entry.loaded && entry.users.isEmpty { return "In memory now, no job names it" }
        let jobs = entry.users.filter { $0.tag != "skill" }.map(\.agent)
        let names = jobs.isEmpty ? entry.users.map(\.agent) : jobs
        if let does = entry.does {
            guard entry.section == "used", let first = names.first else { return does }
            return does + " · " + first + (names.count > 1 ? " +\(names.count - 1)" : "")
        }
        if entry.section == "unused" {
            guard entry.isNew else { return "Nothing uses it" }
            return "New on disk" + (entry.added.map { " · " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
        }
        if names.isEmpty { return "Nothing calls it now" }
        return (entry.section == "idle" ? "Can be used by " : "") + names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(swatch(entry.color)).frame(width: 28, height: 28)
                        .overlay(Image(systemName: entry.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if entry.loaded { Pill(text: "Loaded", color: .blue) }
                            if entry.isNew { Pill(text: "New", color: .purple) }
                        }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(gbText(entry.gb)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover && !isOpen ? 0.06 : 0)))
            .onHover { hover = $0 }

            if isOpen { detail.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(isOpen ? 0.05 : 0)))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.what).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.section == "idle" && !entry.users.isEmpty ? "Can be used by" : "Used by").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if entry.users.isEmpty {
                    Text("Nothing uses it now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(entry.users, id: \.self) { u in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(u.tag == "job" ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray)).frame(width: 6, height: 6)
                        (Text(u.agent).fontWeight(.semibold) + Text("  " + u.how).foregroundColor(.secondary))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note = entry.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let tech = entry.tech {
                Text(tech).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Text(entry.store).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(.leading, 48).padding(.trailing, 12).padding(.bottom, 12).padding(.top, 2)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(color))
    }
}
#endif
