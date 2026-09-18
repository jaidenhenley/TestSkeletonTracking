import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
        .frame(minWidth: 600, minHeight: 800)
        .task { await DebugDump.run() }  // TEMP
    }
}

struct HomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Skeleton Lab").font(.extraLargeTitle)
            Text("Choose a mode").foregroundStyle(.secondary)

            NavigationLink { SkeletonLabView() } label: {
                ModeCard(title: "Skeleton testing",
                         subtitle: "Hand tracking, joints, gestures and physics",
                         systemImage: "hand.raised")
            }
            NavigationLink { AEDSimulationView() } label: {
                ModeCard(title: "AED cabinet simulation",
                         subtitle: "Open the cabinet and retrieve the AED",
                         systemImage: "cross.case")
            }
        }
        .buttonStyle(.plain)
        .padding(40)
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage).font(.largeTitle)
            VStack(alignment: .leading) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding(24)
        .frame(maxWidth: 500)
        .glassBackgroundEffect()
    }
}

struct AEDSimulationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var isImmersed = false

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section {
                Button(isImmersed ? "Exit simulation" : "Enter simulation") {
                    Task { await toggleImmersion() }
                }
                .frame(maxWidth: .infinity)
                .disabled(appModel.immersiveSpaceState == .inTransition)
                LabeledContent("Status", value: appModel.aedStatus)
            }

            Section("Placement") {
                Toggle("Attach to a wall", isOn: $appModel.aedAttachToWall)
                Toggle("Flip cabinet (if the door faces the wall)", isOn: $appModel.aedFlipCabinet)
                if appModel.aedAttachToWall {
                    Button("Move to where I'm looking") { appModel.aedPlaceRequest += 1 }
                        .disabled(!isImmersed)
                    LabeledContent("Gap from wall", value: String(format: "%.0f cm", appModel.aedWallGap * 100))
                    Slider(value: $appModel.aedWallGap, in: 0...0.15, step: 0.005)
                    Text("If the cabinet looks sunk into the wall, drag this up until its back sits on the surface.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(appModel.aedAttachToWall
                     ? "The cabinet mounts at 1.3 m on the wall you're looking at. Look at a spot on the wall, then tap Move to where I'm looking to reposition it."
                     : "The cabinet floats about 1.2 m in front of where you started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("How to") {
                Text("Pinch the handle and pull to swing the door open. Push the door with your fingers to swing it.")
                Text("A tap on the cabinet also opens or closes it, which is the only way to test in the simulator.")
            }
            .font(.callout)

            Section("Simulator preview") {
                Button("Show cabinet in a window") { openWindow(id: "AEDCabinet") }
                Text("A volume you can look at and drag without hand tracking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AED simulation")
        .onDisappear { if isImmersed { Task { await dismissImmersiveSpace(); isImmersed = false } } }
    }

    private func toggleImmersion() async {
        if isImmersed {
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            isImmersed = false
            return
        }
        // Only one immersive space can be open; close the skeleton lab's if it is.
        if appModel.immersiveSpaceState == .open { await dismissImmersiveSpace() }
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.aedSpaceID) {
        case .opened: isImmersed = true
        default: appModel.immersiveSpaceState = .closed
        }
    }
}
