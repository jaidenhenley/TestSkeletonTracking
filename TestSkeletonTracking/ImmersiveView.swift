//
//  ImmersiveView.swift
//  TestSkeletonTracking
//
//  Created by Jaiden Henley on 9/17/26.
//

import SwiftUI
import RealityKit

struct ImmersiveView: View {
    @Environment(AppModel.self) var appModel
    @State private var tracker: HandSkeletonTracker?
    @State private var updateSubscription: EventSubscription?

    var body: some View {
        RealityView { content, attachments in
            let tracker = HandSkeletonTracker(
                appModel: appModel,
                leftLabel: attachments.entity(for: "leftLabel"),
                rightLabel: attachments.entity(for: "rightLabel"),
                measureLabel: attachments.entity(for: "measure")
            )
            content.add(tracker.root)
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                tracker.update(deltaTime: event.deltaTime)
            }
            self.tracker = tracker
        } attachments: {
            Attachment(id: "leftLabel") { HandLabel(title: "Left", stats: appModel.left) }
            Attachment(id: "rightLabel") { HandLabel(title: "Right", stats: appModel.right) }
            Attachment(id: "measure") {
                if let d = appModel.handDistance {
                    Text(String(format: "%.1f cm", d * 100))
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassBackgroundEffect()
                }
            }
        }
        .task {
            // Wait for the RealityView make closure to create the tracker.
            while tracker == nil { await Task.yield() }
            await tracker?.run()
        }
        .onDisappear {
            tracker?.stop()
            updateSubscription?.cancel()
        }
    }
}

private struct HandLabel: View {
    let title: String
    let stats: HandStats

    var body: some View {
        VStack(spacing: 2) {
            Text(stats.gesture.rawValue).font(.title3.bold())
            Text("\(title) · \(stats.trackedJoints) joints")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassBackgroundEffect()
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
