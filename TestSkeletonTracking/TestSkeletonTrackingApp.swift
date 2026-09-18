//
//  TestSkeletonTrackingApp.swift
//  TestSkeletonTracking
//
//  Created by Jaiden Henley on 9/17/26.
//

import SwiftUI

@main
struct TestSkeletonTrackingApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(appModel.hideRealHands ? .hidden : .visible)

        ImmersiveSpace(id: appModel.aedSpaceID) {
            AEDImmersiveView()
                .environment(appModel)
                .onAppear { appModel.immersiveSpaceState = .open }
                .onDisappear { appModel.immersiveSpaceState = .closed }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        WindowGroup(id: "AEDCabinet") {
            AEDCabinetView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.6, height: 0.6, depth: 0.6, in: .meters)
    }
}
