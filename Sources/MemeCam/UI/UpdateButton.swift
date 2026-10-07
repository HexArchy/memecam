import SwiftUI

/// Toolbar button that appears only when there is something to say about updates.
struct UpdateButton: View {
    @Environment(AppModel.self) private var model
    @State private var showDetail = false

    private var updater: Updater { model.updater }

    var body: some View {
        switch updater.state {
        case .idle, .checking, .upToDate:
            EmptyView()
        default:
            Button {
                showDetail.toggle()
            } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Design.brand)
            }
            .help("MemeCam update")
            .popover(isPresented: $showDetail, arrowEdge: .bottom) { UpdateDetail(updater: updater) }
            .onAppear { if case .available = updater.state { showDetail = false } }
        }
    }

    private var title: String {
        switch updater.state {
        case .available(let v, _): "Update \(v)"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .failed: "Update failed"
        default: ""
        }
    }

    private var symbol: String {
        switch updater.state {
        case .failed: "exclamationmark.triangle"
        case .downloading, .installing: "arrow.down.circle.dotted"
        default: "arrow.down.circle.fill"
        }
    }
}

struct UpdateDetail: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.state {
            case .available(let version, let notes):
                Label("MemeCam \(version) is available", systemImage: "sparkles")
                    .font(.headline)
                Text("You have \(updater.currentVersion).").foregroundStyle(.secondary)
                if !notes.isEmpty {
                    ScrollView {
                        Text(LocalizedStringKey(Self.plainNotes(notes)))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                }
                HStack {
                    Button("Later") { updater.dismiss() }
                    Spacer()
                    Button("Install & Relaunch") { Task { await updater.installUpdate() } }
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                }
            case .downloading, .installing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(updater.state == .downloading ? "Downloading the update…" : "Verifying and installing…")
                }
                Text("MemeCam will relaunch by itself.").font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Update failed", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Close") { updater.dismiss() }
                    Spacer()
                    Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                }
            case .upToDate:
                Label("MemeCam \(updater.currentVersion) is up to date", systemImage: "checkmark.seal")
            case .idle, .checking:
                ProgressView("Checking…").controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Release notes are Markdown with an HTML cover image; keep the text, drop the HTML.
    static func plainNotes(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
