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
                if vm.machine == .x86 {
                    PCSetupView(vm: vm)
                } else {
                    SetupView(vm: vm)
                }
            case .needsJIT:
                JITView(vm: vm)
            case .running:
                MachineView(vm: vm)
            case .stopped(let message):
                MessageView(title: "Stopped", message: message + "\n\nClose and reopen the app to start again.")
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
                    Text(vm.machine == .arm64 ? "Starting LiberNT…" : "Starting the PC…")
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
                Button("Switch to x86 PC") { vm.switchMachine(to: .x86) }
                    .font(.footnote)
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

/// First launch of the x86 PC: make an empty disk (to install from a CD) or use one from Files.
struct PCSetupView: View {
    @ObservedObject var vm: VMController
    @State private var importing = false
    @State private var pickingISO = false
    @State private var sizeGB = 16

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "pc")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("x86 PC")
                    .font(.largeTitle.bold())
                Text("To install a system, put its install ISO in the CD drive and make an empty disk. Or use a ready-made disk from Files.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                GroupBox {
                    LabeledContent("CD", value: vm.cdName ?? "Empty")
                    HStack {
                        Button("Choose ISO…") { pickingISO = true }
                        if vm.cdName != nil {
                            Spacer()
                            Button("Eject", role: .destructive) { vm.ejectCD() }
                        }
                    }
                }
                .fileImporter(isPresented: $pickingISO, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { vm.insertCD(url) }
                }

                Picker("Disk size", selection: $sizeGB) {
                    Text("2 GB").tag(2)
                    Text("8 GB").tag(8)
                    Text("16 GB").tag(16)
                    Text("32 GB").tag(32)
                }
                .pickerStyle(.segmented)

                Button { vm.createBlankDisk(gigabytes: sizeGB) } label: {
                    Text("Make Empty Disk and Start").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Use a Disk from Files") { importing = true }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                        if case .success(let url) = result { vm.importDisk(from: url) }
                    }

                if case .downloading(_, let text) = vm.phase {
                    ProgressView(text)
                }
                if let error = vm.setupError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button("Switch to ARM64 (LiberNT)") { vm.switchMachine(to: .arm64) }
                    .font(.footnote)
                Text(BuildInfo.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(32)
            .frame(maxWidth: 480)
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

    init(vm: VMController) {
        self.vm = vm
        _ramMB = AppStorage(wrappedValue: vm.machine.defaultRAM, VMController.ramKey(vm.machine))
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage private var ramMB: Int
    @AppStorage("cores") private var cores = 4
    @State private var machine = Machine.current
    @State private var pickingISO = false
    @State private var confirmDelete = false
    @State private var deleted = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Memory", selection: $ramMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
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
                    Text("Used the next time you open the app.")
                }

                Section {
                    Picker("Machine", selection: $machine) {
                        ForEach(Machine.allCases) { Text($0.title).tag($0) }
                    }
                    if machine != vm.machine {
                        Button("Switch and Close App") { vm.switchMachine(to: machine) }
                    }
                } header: {
                    Text("Machine")
                } footer: {
                    Text(machine.detail + (machine != vm.machine ? " The app closes; open it again from StikDebug." : ""))
                }

                Section {
                    LabeledContent("CD", value: vm.cdName ?? "Empty")
                    Button("Choose ISO…") { pickingISO = true }
                    if vm.cdName != nil {
                        Button("Eject", role: .destructive) { vm.ejectCD() }
                    }
                } header: {
                    Text("CD Drive")
                } footer: {
                    Text("The machine starts from the CD when one is in. Eject it after installing.")
                }

                Section("Logs") {
                    ShareLink(item: VMFiles.serialLog) { Label("Share Boot Log", systemImage: "doc.text") }
                    ShareLink(item: VMFiles.qemuLog) { Label("Share QEMU Log", systemImage: "doc.text") }
                }

                Section {
                    Button("Delete Disk", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(deleted ? "Deleted. Close and reopen the app to set it up again." : "Erases everything saved on this machine's disk.")
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
            .fileImporter(isPresented: $pickingISO, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { vm.insertCD(url) }
            }
            .confirmationDialog("Delete this machine's disk?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    vm.powerButton()
                    VMFiles.deleteDisk()
                    deleted = true
                }
            }
        }
    }
}
