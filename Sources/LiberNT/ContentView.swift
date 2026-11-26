import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = VMController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch vm.phase {
            case .needsDisk, .downloading:
                SetupView(vm: vm)
            case .needsJIT:
                JITView(vm: vm)
            case .running:
                MachineView(vm: vm)
            case .stopped(let message):
                MessageView(title: "LiberNT stopped", message: message + "\n\nClose and reopen the app to start again.")
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { vm.refresh() }
        }
    }
}

// MARK: - Running machine

struct MachineView: View {
    @ObservedObject var vm: VMController
    @State private var showKeyboard = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FramebufferView(frame: vm.frame, vnc: vm.vnc, showKeyboard: $showKeyboard)
                .ignoresSafeArea()

            if vm.frame == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting LiberNT…")
                        .font(.headline)
                    Text("The first boot takes a minute or two.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            Menu {
                Button { showKeyboard.toggle() } label: {
                    Label(showKeyboard ? "Hide Keyboard" : "Keyboard", systemImage: "keyboard")
                }
                Section("Keys") {
                    Button("Esc") { vm.vnc.tap(Keysym.escape) }
                    Button("Tab") { vm.vnc.tap(Keysym.tab) }
                    Button("Windows Key") { vm.vnc.tap(Keysym.windows) }
                    Button("Ctrl+Alt+Del") { vm.vnc.chord([Keysym.control, Keysym.alt, Keysym.delete]) }
                    Button("Alt+F4") { vm.vnc.chord([Keysym.alt, 0xffc1]) }
                }
                Section("Machine") {
                    Button { vm.powerButton() } label: { Label("Power Button", systemImage: "power") }
                    Button(role: .destructive) { vm.reset() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .padding(10)
                    .opacity(0.6)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
    }
}

// MARK: - First launch

struct SetupView: View {
    @ObservedObject var vm: VMController
    @State private var importing = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("LiberNT")
                .font(.largeTitle.bold())
            Text("LiberNT needs its disk (about 320 MB to download). It's saved in Files › On My iPhone › LiberNT.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if case .downloading(let fraction, let text) = vm.phase {
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Keep the app open until it finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button { vm.downloadDisk() } label: {
                    Text("Download LiberNT").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Use a Disk from Files") { importing = true }
            }

            if let error = vm.setupError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text(BuildInfo.label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { vm.importDisk(from: url) }
        }
    }
}

struct JITView: View {
    @ObservedObject var vm: VMController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Turn on JIT", systemImage: "bolt.fill")
                    .font(.title.bold())
                Text("LiberNT runs in an emulator that needs JIT. Open it from StikDebug:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. In StikDebug, assign the script **legacy.js** to LiberNT.")
                    Text("2. Launch LiberNT from StikDebug.")
                    Text("3. LiberNT starts by itself once JIT is on.")
                }
                Button { vm.refresh() } label: {
                    Text("Check Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(BuildInfo.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(32)
            .frame(maxWidth: 520)
        }
    }
}

struct MessageView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: VMController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ramMB") private var ramMB = 3072
    @AppStorage("cores") private var cores = 4
    @State private var confirmDelete = false
    @State private var deleted = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Memory", selection: $ramMB) {
                        Text("2 GB").tag(2048)
                        Text("3 GB").tag(3072)
                        Text("4 GB").tag(4096)
                    }
                    Picker("CPU Cores", selection: $cores) {
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("6").tag(6)
                    }
                } footer: {
                    Text("Used the next time you open LiberNT.")
                }

                Section("Logs") {
                    ShareLink(item: VMFiles.serialLog) { Label("Share Boot Log", systemImage: "doc.text") }
                    ShareLink(item: VMFiles.qemuLog) { Label("Share QEMU Log", systemImage: "doc.text") }
                }

                Section {
                    Button("Delete LiberNT Disk", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(deleted ? "Deleted. Close and reopen the app to set it up again." : "Erases everything saved in LiberNT.")
                }

                Section {
                    LabeledContent("JIT", value: JIT.isEnabled ? "On" : "Off")
                    LabeledContent("Version", value: BuildInfo.label)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete the LiberNT disk?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    vm.powerButton()
                    VMFiles.deleteDisk()
                    deleted = true
                }
            }
        }
    }
}
