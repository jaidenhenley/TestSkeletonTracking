import SwiftUI
import RealityKit

struct AEDCabinetView: View {
    @State private var door: Entity?
    @State private var closed = Transform()
    @State private var progress: Float = 0        // 0 = closed, 1 = fully open
    @State private var dragStart: DragStart?
    @State private var loadError: String?

    /// +110° opens outward. Flip the sign if the door swings into the cabinet (risk 4).
    private let openAngle: Float = 110 * .pi / 180

    private struct DragStart {
        var progress: Float
        var hand: SIMD3<Float>?   // nil when the drag began on the cabinet body, not the door
    }

    var body: some View {
        RealityView { content in
            do {
                let model = try await Entity(named: "AEDCabinet")

                let bounds = model.visualBounds(relativeTo: model)
                model.position = -bounds.center

                model.generateCollisionShapes(recursive: true)
                model.components.set(InputTargetComponent())
                model.components.set(HoverEffectComponent())

                content.add(model)

                guard let d = model.findEntity(named: "AED_Door") else {
                    loadError = "Loaded the model, but found no entity named AED_Door."
                    return
                }
                door = d
                closed = d.transform
            } catch {
                loadError = "Couldn't load AEDCabinet.usdz: \(error.localizedDescription)"
            }
        }
        .gesture(doorGesture)
        .overlay {
            if let loadError {
                Text(loadError)
                    .padding()
                    .glassBackgroundEffect()
            }
        }
    }

    // MARK: - Gesture

    private var doorGesture: some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let door, let parent = door.parent else { return }

                let onDoor = isPart(value.entity, of: door)
                let hand = onDoor ? value.convert(value.location3D, from: .local, to: parent) : nil

                if dragStart == nil {
                    door.stopAllAnimations()
                    dragStart = DragStart(progress: progress, hand: hand)
                }
                guard let start = dragStart, let startHand = start.hand, let hand else { return }

                let up = HingeMath.worldUp(in: parent)
                let hinge = door.position
                let a = HingeMath.flatten(startHand - hinge, along: up)
                let b = HingeMath.flatten(hand - hinge, along: up)
                guard length(a) > 0.02, length(b) > 0.02 else { return }

                let delta = HingeMath.signedAngle(from: a, to: b, around: up)
                let t = start.progress + delta / openAngle
                apply(progress: min(max(t, 0), 1), duration: nil)
            }
            .onEnded { _ in
                defer { dragStart = nil }
                guard let start = dragStart else { return }

                let moved = abs(progress - start.progress) > 0.02
                if moved {
                    apply(progress: progress > 0.5 ? 1 : 0, duration: 0.4)   // snap to nearest end
                } else {
                    apply(progress: start.progress < 0.5 ? 1 : 0, duration: 1.2)  // plain tap: toggle
                }
            }
    }

    // MARK: - Door pose

    private func apply(progress t: Float, duration: TimeInterval?) {
        guard let door, let parent = door.parent else { return }
        progress = t

        var target = closed
        target.rotation = simd_quatf(angle: t * openAngle, axis: HingeMath.worldUp(in: parent)) * closed.rotation

        if let duration {
            door.move(to: target, relativeTo: parent, duration: duration, timingFunction: .easeInOut)
        } else {
            door.transform = target
        }
    }

    private func isPart(_ entity: Entity, of ancestor: Entity) -> Bool {
        var current: Entity? = entity
        while let e = current {
            if e == ancestor { return true }
            current = e.parent
        }
        return false
    }
}

#Preview(windowStyle: .volumetric) {
    AEDCabinetView()
}

