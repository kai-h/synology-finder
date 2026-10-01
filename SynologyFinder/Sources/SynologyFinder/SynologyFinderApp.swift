import AppKit
import SwiftUI
import SynologyDiscovery

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SynologyFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = FinderModel()

    var body: some Scene {
        WindowGroup("Synology Finder") {
            DeviceListView(model: model)
                .frame(minWidth: 820, minHeight: 180)  // about four rows
                .task {
                    model.refreshNetworks()
                    model.startScan()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshNetworks()
                }
        }
        .defaultSize(width: 942, height: 372)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search Again") { model.startScan() }.keyboardShortcut("r")
            }
        }
    }
}

/// Reads `model.progress` in its own view so the 10 Hz updates redraw only the bar, not the table
/// (redrawing the table mid-click drops the row selection).
struct ScanFooter: View {
    let model: FinderModel

    var body: some View {
        HStack {
            if model.phase == .scanning {
                ProgressView(value: model.progress).frame(maxWidth: 240)
            }
            if let notice = model.notice {
                Text(notice).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("Total \(model.devices.count) Synology server(s) found.")
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

/// Shown only when a VPN-routed private subnet exists. Those networks are listed but disabled: the
/// NAS ignores discovery probes from another subnet, even over a site-to-site VPN.
struct NetworkMenu: View {
    let model: FinderModel

    var body: some View {
        Menu {
            Button { } label: { Label("Local network", systemImage: "checkmark") }
            Divider()
            Section("Via VPN (not scannable)") {
                ForEach(model.remoteNetworks) { network in
                    Button("\(network.description)  (\(network.interface))") { }.disabled(true)
                }
            }
        } label: {
            Label("Local network", systemImage: "wifi")
        }
        .help("Scanning the local network. \(model.remoteNetworks.count) VPN network(s) are listed but cannot be scanned: a Synology only answers discovery from its own subnet.")
    }
}

/// A table row: a server, or, as a child of it, one network port of a server that has several.
struct ServerRow: Identifiable, Hashable {
    let id: String
    let device: SynologyDevice
    let port: SynologyDevice.NetworkInterface?
    let portNumber: Int
    let children: [ServerRow]?

    init(_ device: SynologyDevice) {
        id = device.id
        self.device = device
        port = nil
        portNumber = 0
        children = device.interfaces.count > 1
            ? device.interfaces.enumerated().map { ServerRow(device: device, port: $1, portNumber: $0 + 1) }
            : nil
    }

    private init(device: SynologyDevice, port: SynologyDevice.NetworkInterface, portNumber: Int) {
        id = "\(device.id)#\(portNumber)"
        self.device = device
        self.port = port
        self.portNumber = portNumber
        children = nil
    }

    var isPort: Bool { port != nil }
}

struct DeviceListView: View {
    let model: FinderModel
    @State private var selection: ServerRow.ID?
    @State private var search = ""

    private var visible: [SynologyDevice] {
        guard !search.isEmpty else { return model.devices }
        return model.devices.filter {
            ([$0.name, $0.model, $0.serial, $0.dsmVersion] + $0.interfaces.flatMap { [$0.ip, $0.mac] }).contains {
                $0.localizedCaseInsensitiveContains(search)
            }
        }
    }

    private var rows: [ServerRow] { visible.map(ServerRow.init) }

    private func device(forRowID id: ServerRow.ID?) -> SynologyDevice? {
        guard let id else { return nil }
        let deviceID = id.components(separatedBy: "#")[0]
        return model.devices.first { $0.id == deviceID }
    }

    /// The network port a row stands for, or the server's main one.
    private func port(forRowID id: ServerRow.ID) -> SynologyDevice.NetworkInterface? {
        guard let device = device(forRowID: id) else { return nil }
        let parts = id.components(separatedBy: "#")
        let number = parts.count > 1 ? Int(parts[1]) : nil
        return device.interfaces[(number ?? 1) - 1]
    }

    private var selected: SynologyDevice? { device(forRowID: selection) }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, children: \.children, selection: $selection) {
                TableColumn("Server name") { row in
                    if row.isPort {
                        Text("Port \(row.portNumber)").foregroundStyle(.secondary)
                    } else {
                        Text(row.device.name)
                    }
                }
                .width(min: 70, ideal: 99)
                TableColumn("IP address") { row in
                    Text(row.port?.ip ?? row.device.ipSummary)
                        .help(row.port == nil ? row.device.interfaces.map(\.ip).joined(separator: "\n") : "")
                }
                .width(min: 60, ideal: 89)
                TableColumn("IP status") { Text($0.isPort ? "" : $0.device.ipAssignment.rawValue) }
                    .width(min: 50, ideal: 72)
                TableColumn("Status") { Text($0.isPort ? "" : $0.device.status) }
                    .width(min: 45, ideal: 60)
                TableColumn("MAC address") { row in
                    Text(row.port?.mac ?? row.device.macSummary)
                        .help(row.port == nil ? row.device.interfaces.map(\.mac).joined(separator: "\n") : "")
                }
                .width(min: 100, ideal: 133)
                TableColumn("Version") { Text($0.isPort ? "" : $0.device.dsmVersion) }
                    .width(min: 55, ideal: 82)
                TableColumn("Model") { Text($0.isPort ? "" : $0.device.model) }
                    .width(min: 45, ideal: 60)
                TableColumn("Serial no") { Text($0.isPort ? "" : $0.device.serial) }
                    .width(min: 80, ideal: 112)
                TableColumn("WOL status") { Text($0.isPort ? "" : (model.isWOLEnabled($0.device) ? "Enabled" : "--")) }
                    .width(min: 50, ideal: 72)
            }
            .contextMenu(forSelectionType: ServerRow.ID.self) { ids in
                if let id = ids.first, let device = device(forRowID: id), let port = port(forRowID: id) {
                    Button("Connect") { open(device) }.disabled(!device.isOnline)
                    Button(model.isWOLEnabled(device) ? "Remove WOL" : "Set Up WOL") { model.toggleWOL(device) }
                    Button("Wake Up") { model.wake(device) }.disabled(!model.isWOLEnabled(device))
                    Divider()
                    Button("Copy IP Address") { copy(port.ip) }
                    Button("Copy MAC Address") { copy(port.mac) }
                }
            } primaryAction: { ids in
                if let device = device(forRowID: ids.first), device.isOnline { open(device) }
            }
            .overlay {
                switch model.phase {
                case .waitingForPermission:
                    ContentUnavailableView {
                        Label("Waiting for Local Network Access", systemImage: "network")
                    } description: {
                        Text("Click Allow when macOS asks whether Synology Finder may find devices on your local network. If you chose Don't Allow, turn Synology Finder on under Privacy & Security > Local Network. The search starts as soon as access is available.")
                    } actions: {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                    }
                case .idle, .scanning:
                    if let message = model.message, model.devices.isEmpty {
                        ContentUnavailableView("No Servers", systemImage: "externaldrive.badge.questionmark",
                                               description: Text(message))
                    }
                }
            }
            Divider()
            ScanFooter(model: model)
        }
        .searchable(text: $search, prompt: "Search")
        .toolbar {
            ToolbarItem {
                if !model.remoteNetworks.isEmpty { NetworkMenu(model: model) }
            }
            ToolbarItemGroup {
                Button("Connect", systemImage: "network") { if let selected { open(selected) } }
                    .disabled(selected?.isOnline != true)
                    .help("Open the selected server's DSM web interface in your browser")
                Button(selected.map(model.isWOLEnabled) == true ? "Remove WOL" : "Set Up WOL", systemImage: "power") {
                    if let selected { model.toggleWOL(selected) }
                }
                .disabled(selected == nil)
                .help(selected.map(model.isWOLEnabled) == true
                      ? "Stop remembering the selected server for Wake-on-LAN"
                      : "Remember the selected server so it can be woken up with Wake-on-LAN, even while it is offline")
                Button("Wake Up", systemImage: "sun.max") { if let selected { model.wake(selected) } }
                    .disabled(selected.map(model.isWOLEnabled) != true)
                    .help("Send a Wake-on-LAN packet to the selected server (first use Set Up WOL)")
                Button("Search Again", systemImage: "arrow.clockwise") { model.startScan() }
                    .disabled(model.phase == .scanning)
                    .help("Scan the local network again")
            }
        }
    }

    private func open(_ device: SynologyDevice) {
        if let url = device.webURL { NSWorkspace.shared.open(url) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
