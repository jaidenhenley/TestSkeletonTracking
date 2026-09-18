//
//  ContentView.swift
//  TestSkeletonTracking
//
//  Created by Jaiden Henley on 9/17/26.
//

import SwiftUI
import RealityKit

struct SkeletonLabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section {
                ToggleImmersiveSpaceButton()
                    .frame(maxWidth: .infinity)
                LabeledContent("Status", value: appModel.status)
                LabeledContent("Update rate", value: String(format: "%.0f Hz", appModel.updateRate))
                LabeledContent("Scene mesh chunks", value: "\(appModel.sceneMeshCount)")
            }

            Section("Visualize") {
                Toggle("Joints (27 per hand)", isOn: $appModel.showJoints)
                Toggle("Bones", isOn: $appModel.showBones)
                Toggle("Joint orientation axes", isOn: $appModel.showJointAxes)
                Toggle("Fingertip trails", isOn: $appModel.showFingertipTrails)
                Toggle("Floating labels + ruler", isOn: $appModel.showLabels)
                Toggle("Hide my real hands", isOn: $appModel.hideRealHands)
            }

            Section("Interact") {
                Toggle("Physics & grabbing", isOn: $appModel.physicsEnabled)
                Picker("Pick up with", selection: $appModel.grabStyle) {
                    ForEach(GrabStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Pinch empty space to spawn", isOn: $appModel.spawnOnEmptyPinch)
                    .disabled(appModel.grabStyle == .palm)
                Toggle("Keep proportions when stretching", isOn: $appModel.uniformStretch)
                Toggle("Predicted anchors (low latency)", isOn: $appModel.usePredictedAnchors)
                LabeledContent("Objects spawned", value: "\(appModel.spawnedObjects)")
                LabeledContent("Claps", value: "\(appModel.claps)")
                LabeledContent("Last palm event", value: appModel.lastPalmEvent)
                Button("Drop objects on the floor") { appModel.dropRequest += 1 }
                Button("Clear objects", role: .destructive) { appModel.clearRequest += 1 }
            }

            HStack(alignment: .top, spacing: 20) {
                HandPanel(title: "Left hand", stats: appModel.left)
                HandPanel(title: "Right hand", stats: appModel.right)
            }
            .listRowBackground(Color.clear)

            Section("How to") {
                Text("Palm: turn your palm up and slide it under an object (even on the floor) to scoop it up. Tip your hand over to pour it out, flick upward to toss and catch, or make a fist to hold it while you turn your hand.")
                Text("Pinch: pinch near an object to pick it up — it follows your hand and wrist. Let go to drop or throw it.")
                Text("Pinch the same object with both hands, then pull apart or push together to stretch or squash it.")
            }
            .font(.callout)

            if let d = appModel.handDistance {
                LabeledContent("Index-tip distance", value: String(format: "%.1f cm", d * 100))
            }
        }
        .navigationTitle("Skeleton Lab")
    }
}

private struct HandPanel: View {
    let title: String
    let stats: HandStats

    private let fingers = ["Thumb", "Index", "Middle", "Ring", "Little"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Circle()
                    .fill(stats.isTracked ? .green : .red)
                    .frame(width: 10, height: 10)
            }
            Text(stats.gesture.rawValue).font(.title2.bold())
            Text("Joints tracked: \(stats.trackedJoints)/27").font(.caption)
            Text(String(format: "Pinch gap: %.1f cm", stats.pinchDistance * 100)).font(.caption.monospacedDigit())
            Text(String(format: "Palm up: %.2f%@", stats.palmFacingUp, stats.isHoldingInPalm ? " · holding" : ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(stats.isHoldingInPalm ? .green : stats.palmFacingUp > 0.45 ? .primary : .secondary)

            ForEach(fingers.indices, id: \.self) { i in
                HStack {
                    Text(fingers[i]).font(.caption).frame(width: 50, alignment: .leading)
                    ProgressView(value: Double(min(stats.curls[i], 270)), total: 270)
                    Text("\(Int(stats.curls[i]))°").font(.caption2.monospacedDigit()).frame(width: 36)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
    }
}

#Preview(windowStyle: .automatic) {
    SkeletonLabView()
        .environment(AppModel())
}
