//
//  AEDCarry.swift
//  TestSkeletonTracking
//
//  Picking the AED up by its handle and carrying it. With the cabinet door open, close your hand
//  around the top of the unit and it hangs from your fist like a real carry handle: it follows
//  your hand's position and yaw, swings like a pendulum when you move, and drops when you open
//  your hand. Let go of it over the shelf and it settles back into the cabinet.
//

import ARKit
import RealityKit

@MainActor
final class AEDCarry {
    enum State: Equatable {
        case stowed
        case carried(HandAnchor.Chirality)
        case falling
        case onFloor
        case returning
    }

    private(set) var state: State = .stowed
    var carryingHand: HandAnchor.Chirality? {
        if case .carried(let hand) = state { return hand }
        return nil
    }

    /// The AED_Unit entity: origin at the unit's centre, X across, Y up, Z toward the screen.
    private let unit: Entity
    private let world: Entity
    private let homeParent: Entity
    private let homeTransform: Transform
    private let halfHeight: Float
    /// Where the carry handle is, in the unit's space: top centre, a little toward the back.
    private let gripLocal: SIMD3<Float>

    // MARK: Tunables

    /// Where the handle bar sits inside a closed hand, in the palm frame
    /// (+Y out of the palm, -Z toward the fingertips), measured from the middle knuckle.
    private let gripInHand: SIMD3<Float> = [0, 0.03, -0.02]
    private let grabRadius: Float = 0.10
    /// Mean bend of the four fingers, in degrees. Hysteresis so the grip doesn't flicker.
    private let closeCurl: Float = 95, openCurl: Float = 60
    private let doorOpenEnough: Float = 50 * .pi / 180
    /// Hand tracking drops out briefly all the time; only let go if it stays gone this long.
    private let handLostGrace: Float = 0.4
    private let swingDamping: Float = 3.5
    private let gravity: Float = 9.81
    private let floorY: Float = 0
    /// Release the handle within this distance of its shelf position and it goes back in.
    private let returnZone: Float = 0.15

    // MARK: Carry dynamics

    private var pivot: SIMD3<Float> = .zero
    private var pivotVelocity: SIMD3<Float> = .zero
    private var pivotAcceleration: SIMD3<Float> = .zero
    private var yaw: Float = 0
    private var yawOffset: Float = 0
    /// Pendulum angles: x = swing about the handle axis (forward/back), y = sideways.
    private var swing = SIMD2<Float>.zero
    private var swingVelocity = SIMD2<Float>.zero
    private var handLostFor: Float = 0
    private var fallVelocity: SIMD3<Float> = .zero
    private var returnTimer: Float = 0

    init(unit: Entity, world: Entity) {
        self.unit = unit
        self.world = world
        homeParent = unit.parent ?? world
        homeTransform = unit.transform
        halfHeight = unit.visualBounds(relativeTo: unit).extents.y / 2
        gripLocal = [0, halfHeight - 0.005, -0.015]
    }

    /// Runs one frame. `doorAngle` is the cabinet door's current hinge angle.
    func update(poses: [HandPose], doorAngle: Float, dt: Float, status: (String) -> Void) {
        switch state {
        case .stowed:
            if abs(doorAngle) > doorOpenEnough { tryGrab(poses: poses, status: status) }
        case .onFloor:
            tryGrab(poses: poses, status: status)
        case .carried(let hand):
            if let pose = poses.first(where: { $0.chirality == hand }) {
                handLostFor = 0
                if meanCurl(pose) < openCurl { release(status: status) } else { follow(pose, dt: dt) }
            } else {
                handLostFor += dt
                if handLostFor > handLostGrace { release(status: status) }
            }
        case .falling:
            fall(dt: dt, status: status)
        case .returning:
            returnTimer -= dt
            if returnTimer <= 0 { state = .stowed }
        }
    }

    // MARK: Grab / release

    private func tryGrab(poses: [HandPose], status: (String) -> Void) {
        let grip = unit.convert(position: gripLocal, to: nil)
        for pose in poses {
            guard meanCurl(pose) > closeCurl, let hand = handGrip(pose), distance(hand, grip) < grabRadius,
                  let rotation = pose.palmRotation else { continue }
            unit.stopAllAnimations()
            unit.setParent(world, preservingWorldTransform: true)
            pivot = hand
            pivotVelocity = .zero
            pivotAcceleration = .zero
            swing = .zero
            swingVelocity = .zero
            yaw = Self.yaw(of: unit.orientation(relativeTo: nil))
            yawOffset = yaw - (Self.yaw(ofPalm: rotation) ?? 0)
            handLostFor = 0
            state = .carried(pose.chirality)
            status("AED in your \(pose.chirality == .left ? "left" : "right") hand · open your hand to let go")
            return
        }
    }

    private func release(status: (String) -> Void) {
        let gripNow = unit.convert(position: gripLocal, to: nil)
        let gripHome = homeParent.convert(position: homeTransform.translation + homeTransform.rotation.act(gripLocal), to: nil)
        if distance(gripNow, gripHome) < returnZone {
            unit.setParent(homeParent, preservingWorldTransform: true)
            unit.move(to: homeTransform, relativeTo: homeParent, duration: 0.35, timingFunction: .easeOut)
            returnTimer = 0.4
            state = .returning
            status("AED back in the cabinet")
        } else {
            let speed = length(pivotVelocity)
            fallVelocity = speed > 4 ? pivotVelocity * (4 / speed) : pivotVelocity
            state = .falling
            status("AED dropped")
        }
    }

    // MARK: Carrying

    private func follow(_ pose: HandPose, dt: Float) {
        guard dt > 0, let target = handGrip(pose), let rotation = pose.palmRotation else { return }

        // Light smoothing takes the tracking jitter out; the pendulum below supplies the weight.
        let next = simd_mix(pivot, target, SIMD3(repeating: 1 - exp(-30 * dt)))
        let velocity = (next - pivot) / dt
        var acceleration = (velocity - pivotVelocity) / dt
        let magnitude = length(acceleration)
        if magnitude > 30 { acceleration *= 30 / magnitude }
        pivotAcceleration = simd_mix(pivotAcceleration, acceleration, SIMD3(repeating: 0.25))
        pivotVelocity = velocity
        pivot = next

        // A handle-hung unit turns with your hand but doesn't tilt with it.
        if let palmYaw = Self.yaw(ofPalm: rotation) {
            yaw = Self.lerpAngle(yaw, palmYaw + yawOffset, 1 - exp(-15 * dt))
        }
        stepPendulum(dt: dt)
        hang(from: pivot)
    }

    /// Pendulum with the pivot at the handle and the mass at the unit's centre. Accelerating the
    /// pivot makes the body lag behind; gravity and damping bring it back to hanging straight.
    private func stepPendulum(dt: Float) {
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        let side = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let aForward = dot(pivotAcceleration, forward)
        let aSide = dot(pivotAcceleration, side)
        let arm = max(halfHeight, 0.05)
        let acceleration = SIMD2<Float>(
            (aForward * cos(swing.x) - gravity * sin(swing.x)) / arm - swingDamping * swingVelocity.x,
            (-aSide * cos(swing.y) - gravity * sin(swing.y)) / arm - swingDamping * swingVelocity.y
        )
        swingVelocity += acceleration * dt
        swing = simd_clamp(swing + swingVelocity * dt, SIMD2(repeating: -0.7), SIMD2(repeating: 0.7))
    }

    private var hangingRotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: swing.y, axis: [0, 0, 1])
            * simd_quatf(angle: swing.x, axis: [1, 0, 0])
    }

    /// Places the unit so its handle is at `pivot` and its body hangs below at the current swing.
    private func hang(from pivot: SIMD3<Float>) {
        let rotation = hangingRotation
        unit.setOrientation(rotation, relativeTo: nil)
        unit.setPosition(pivot - rotation.act(gripLocal), relativeTo: nil)
    }

    // MARK: Falling

    private func fall(dt: Float, status: (String) -> Void) {
        fallVelocity.y -= gravity * dt
        pivotAcceleration = .zero
        stepPendulum(dt: dt)
        let rotation = hangingRotation
        unit.setOrientation(rotation, relativeTo: nil)
        unit.setPosition(unit.position(relativeTo: nil) + fallVelocity * dt, relativeTo: nil)

        let lowest = unit.visualBounds(relativeTo: nil).min.y
        guard lowest <= floorY else { return }
        unit.setPosition(unit.position(relativeTo: nil) + [0, floorY - lowest, 0], relativeTo: nil)

        if fallVelocity.y < -1.5 {
            // Hard landing: a small bounce, then it comes down again.
            fallVelocity = [fallVelocity.x * 0.6, -fallVelocity.y * 0.2, fallVelocity.z * 0.6]
            return
        }
        // Settle upright on the floor.
        swing = .zero
        swingVelocity = .zero
        fallVelocity = .zero
        unit.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
        var p = unit.position(relativeTo: nil)
        p.y = floorY + halfHeight
        unit.setPosition(p, relativeTo: nil)
        state = .onFloor
        status("AED on the floor · close your hand around the top to pick it up")
    }

    // MARK: Hand helpers

    private func meanCurl(_ pose: HandPose) -> Float {
        let c = pose.curls
        guard c.count == 5 else { return 0 }
        return (c[1] + c[2] + c[3] + c[4]) / 4
    }

    /// World point where a handle bar would sit in this hand.
    private func handGrip(_ pose: HandPose) -> SIMD3<Float>? {
        guard let centre = pose.palmCenter, let rotation = pose.palmRotation else { return nil }
        return centre + rotation.act(gripInHand)
    }

    /// Heading of an upright entity: the angle of its +Z axis around Y.
    private static func yaw(of q: simd_quatf) -> Float {
        let f = q.act([0, 0, 1])
        return atan2(f.x, f.z)
    }

    /// Heading of the knuckle line (palm X), which is the axis a carried handle runs along.
    /// Nil when the hand is turned so that line is nearly vertical.
    private static func yaw(ofPalm q: simd_quatf) -> Float? {
        var x = q.act([1, 0, 0])
        x.y = 0
        guard length(x) > 0.3 else { return nil }
        return atan2(-x.z, x.x)
    }

    private static func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return a + d * t
    }
}
