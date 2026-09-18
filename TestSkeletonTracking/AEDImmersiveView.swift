//
//  AEDImmersiveView.swift
//  TestSkeletonTracking
//

import SwiftUI
import RealityKit

struct AEDImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @State private var controller: AEDCabinetController?
    @State private var updateSubscription: EventSubscription?

    var body: some View {
        RealityView { content in
            let controller = AEDCabinetController(appModel: appModel)
            content.add(controller.root)
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                controller.update(deltaTime: event.deltaTime)
            }
            self.controller = controller
            await controller.load()
        }
        // Simulator fallback: no hands there, so a click still toggles the door.
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { _ in controller?.toggle() }
        )
        .task {
            while controller == nil { await Task.yield() }
            await controller?.run()
        }
        .onDisappear {
            controller?.stop()
            updateSubscription?.cancel()
        }
    }
}
