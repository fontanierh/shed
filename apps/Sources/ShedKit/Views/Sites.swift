// Sites: web servers the agents started, found by the bridge from the ports their processes listen on. Listed for the
// whole tailnet in the sidebar, and for the open session in its header, so a preview is one tap away on the Mac and
// the phone.
import SwiftUI

#if os(iOS)
import SafariServices
#endif

/// Opens a site where it reads best: in the app on the phone, in the browser on the Mac.
@MainActor
enum SiteOpener {
    #if os(iOS)
    /// The browser sheet in front of the app, so a preview doesn't take the user out of their sessions.
    static func open(_ url: String) {
        guard let url = URL(string: url),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController
        else { return }
        let sheet = SFSafariViewController(url: url)
        sheet.preferredControlTintColor = UIColor(Palette.amber)
        root.topMost.present(sheet, animated: true)
    }
    #else
    static func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    static func copy(_ url: String) {
        Clipboard.copy(url)
    }
}

#if os(iOS)
private extension UIViewController {
    var topMost: UIViewController {
        presentedViewController?.topMost ?? self
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first { $0.isKeyWindow } ?? windows.first
    }
}
#endif

/// The header button: a globe and how many sites the session serves. Opens the list.
struct SitesButton: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var open = false

    var body: some View {
        let count = session.sites.count
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                if count > 0 {
                    Text("\(count)").monospacedDigit().contentTransition(.numericText())
                    Ember(size: 6)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(count > 0 ? Palette.moon : Color.secondary)
            .pill()
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: count)
        }
        .buttonStyle(PressStyle())
        .help(count == 0 ? "Sites" : count == 1 ? "1 site running" : "\(count) sites running")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SitesPanel(entries: session.sites.map { SiteEntry(site: $0, session: session) },
                       title: session.isSubagent ? (session.name ?? "Subagent") : session.title,
                       empty: "Servers this session starts appear here.")
                .frame(width: 420)
        }
    }
}

/// Every site on the tailnet, whatever session serves it: the sidebar's list, in a popover on the Mac and a sheet on
/// the phone.
struct AllSitesButton: View {
    let store: SessionStore
    @State private var open = false

    var body: some View {
        let count = store.allSites.count
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(count > 0 ? Palette.moon : Color.secondary)
            .frame(height: 30)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Sites on this tailnet")
        #if os(iOS)
        .sheet(isPresented: $open) {
            NavigationStack { SitesPanel(entries: store.allSites, title: "Sites", empty: EmptyCopy.all) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #else
        .popover(isPresented: $open, arrowEdge: .top) {
            SitesPanel(entries: store.allSites, title: "Sites", empty: EmptyCopy.all)
                .frame(width: 460, height: 380)
        }
        #endif
    }

    enum EmptyCopy {
        static let all = "Servers the agents start appear here. Publishing them on the tailnet is off unless `sites.publish` is set in the bridge's config.json."
        static let none = "No sites running."
    }
}

/// The list of sites: each one's name, where it is, and the session serving it.
struct SitesPanel: View {
    let entries: [SiteEntry]
    let title: String
    let empty: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ice)
                    .frame(width: 30, height: 30).card(radius: 9, fill: Palette.raised)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.moon).lineLimit(1)
                if !entries.isEmpty {
                    Text("· \(entries.count)").font(.system(size: 13.5)).foregroundStyle(.secondary)
                }
                Spacer()
                #if os(iOS)
                Button("Done") { dismiss() }.font(.system(size: 14, weight: .medium))
                #endif
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(Palette.border).frame(height: 1)
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No sites").font(.system(size: 16, design: .serif)).foregroundStyle(Palette.moon)
                    Text(empty).font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            SiteRow(entry: entry)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Velvet(base: Palette.surface))
    }
}

private struct SiteRow: View {
    let entry: SiteEntry
    @State private var copied = false

    var body: some View {
        let site = entry.site
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: site.published ? "network" : "desktopcomputer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(site.published ? Palette.ice : .secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.moon)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(site.host).font(.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                    if !site.published {
                        Text("this Mac only").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if site.exposed {
                        Label("on your LAN too", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.amber)
                            .help("The server listens on every interface, so devices on your local network can reach it, not just your tailnet.")
                    }
                }
                Text(entry.session.isSubagent ? (entry.session.name ?? "subagent") : entry.session.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    SiteOpener.copy(site.url)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Copy the address")
                Button { SiteOpener.open(site.url) } label: {
                    Text("Open").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 26)
                        .card(radius: 13, fill: Palette.ice.opacity(0.12), border: Palette.ice.opacity(0.4))
                }
                .buttonStyle(PressStyle())
                .help(site.url)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .card(radius: 9, fill: Palette.raised.opacity(0.5))
    }
}
