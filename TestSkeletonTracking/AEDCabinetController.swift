//
//  AEDCabinetController.swift
//  TestSkeletonTracking
//
//  Runs the AED cabinet in an immersive space: loads the model, tracks hands, lets you
//  push the door with your fingertips or pull it by pinching the handle, and optionally
//  snaps the cabinet onto a real wall.
//

import ARKit
import CoreGraphics
import QuartzCore
import RealityKit
import UIKit

@MainActor
final class AEDCabinetController {
    let root = Entity()

    private let appModel: AppModel
    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private let planeDetection = PlaneDetectionProvider(alignments: [.vertical])
    private let worldTracking = WorldTrackingProvider()

    /// Carries the cabinet's world pose (floating or on a wall). The model sits inside it.
    private let holder = Entity()
    private var door: Entity?
    private var closed = Transform()
    /// Picking the AED up by its handle, carrying it and dropping it. Nil if the unit failed to load.
    private var carry: AEDCarry?

    // Door geometry, measured once from the loaded model (all in the door's parent space).
    private var hinge: SIMD3<Float> = .zero
    private var up: SIMD3<Float> = [0, 1, 0]
    private var closedDir: SIMD3<Float> = [1, 0, 0]   // hinge → handle when closed
    private var width: Float = 0.4
    private var heightRange: ClosedRange<Float> = 0...0.36
    private var thickness: Float = 0.02
    private var handleLocal: SIMD3<Float> = .zero      // in the door's own space

    /// +110° opens outward. Flip the sign if the door swings into the cabinet (risk 4).
    let openAngle: Float = 110 * .pi / 180

    // Door motion state. `angle` is signed like `openAngle`.
    private(set) var angle: Float = 0
    private var angularVelocity: Float = 0
    private var grabbingHand: HandAnchor.Chirality?
    private var walls: [UUID: PlaneAnchor] = [:]
    private var placedOnWall = false
    private var lastAttachSetting = false
    private var lastPlaceRequest = 0
    private var lastWallGap: Float = 0
    private var lastFlip = false
    private var model: Entity?
    /// Wall the cabinet is mounted on, plus where on it (world XZ + height) so it can re-seat as ARKit refines the plane.
    private var mountedWallID: UUID?
    private var mountPoint: SIMD3<Float> = .zero
    /// Where you stood when it was mounted — decides which side of the wall is "the room".
    private var mountViewer: SIMD3<Float> = [0, 1.5, 0]
    /// Soft dark patch on the wall behind the cabinet — fakes the contact shadow a real cabinet would have.
    private let wallShadow = ModelEntity()
    /// Standard AED cabinet mounting height (centre), keeping the handle within ADA reach.
    private let mountHeight: Float = 1.3

    private let fingerRadius: Float = 0.012
    private let grabRadius: Float = 0.07

    init(appModel: AppModel) {
        self.appModel = appModel
        root.addChild(holder)
    }

    // MARK: - Loading

    func load() async {
        do {
            let model = try await Entity(named: "AEDCabinet")
            holder.addChild(model)

            guard let d = model.findEntity(named: "AED_Door"), let parent = d.parent else {
                appModel.aedStatus = "Model loaded, but no entity named AED_Door."
                return
            }

            // Seat the AED unit inside before collision shapes and shadows so it gets both too.
            var aedNote = ""
            do {
                let unit = try await AEDInsert.place(in: model, door: d)
                carry = AEDCarry(unit: unit, world: root)
            } catch {
                aedNote = " · AED unit missing: \(error.localizedDescription)"
            }

            model.generateCollisionShapes(recursive: true)
            model.components.set(InputTargetComponent())
            Self.enableGroundingShadows(on: model)
            self.model = model
            lastFlip = appModel.aedFlipCabinet
            let depth = orient(model: model, flipped: lastFlip)
            let b = model.visualBounds(relativeTo: holder)
            await makeWallShadow(width: b.extents.x, height: b.extents.y)
            appModel.aedCabinetDepth = depth
            door = d
            closed = d.transform
            measureDoor(d, parent: parent)
            placeFloating()
            appModel.aedStatus = "Cabinet loaded" + aedNote
        } catch {
            appModel.aedStatus = "Couldn't load AEDCabinet.usdz: \(error.localizedDescription)"
        }
    }

    /// Faces the model's +Z (its front, per the export) into the room, optionally flipped 180°,
    /// then slides it so the centre of its back face sits at the holder's origin. Returns the depth.
    @discardableResult
    private func orient(model: Entity, flipped: Bool) -> Float {
        model.orientation = simd_quatf(angle: flipped ? .pi : 0, axis: [0, 1, 0])
        model.position = .zero
        let b = model.visualBounds(relativeTo: holder)
        model.position = [-b.center.x, -b.center.y, -b.min.z]
        return b.extents.z
    }

    /// Works out hinge, swing plane and slab size from the door's bounds, in the parent's space.
    private func measureDoor(_ door: Entity, parent: Entity) {
        up = HingeMath.worldUp(in: parent)
        hinge = closed.translation

        let local = door.visualBounds(relativeTo: door)
        let localUp = normalize(door.convert(direction: [0, 1, 0], from: nil))

        // The door's width runs along the horizontal local axis with the largest extent;
        // its thickness is the other one. The handle sits at the far end of the width axis.
        var widthAxis = 0, thickAxis = 2, best: Float = -1
        for i in 0..<3 where abs(localUp[i]) < 0.5 {
            if local.extents[i] > best { best = local.extents[i]; widthAxis = i }
        }
        for i in 0..<3 where i != widthAxis && abs(localUp[i]) < 0.5 { thickAxis = i }
        thickness = local.extents[thickAxis]

        handleLocal = local.center
        handleLocal[widthAxis] = abs(local.max[widthAxis]) > abs(local.min[widthAxis]) ? local.max[widthAxis] : local.min[widthAxis]

        let handleParent = closed.matrix * SIMD4(handleLocal, 1)
        let toHandle = HingeMath.flatten(SIMD3(handleParent.x, handleParent.y, handleParent.z) - hinge, along: up)
        width = length(toHandle)
        closedDir = normalize(toHandle)

        // Height range of the slab: transform the bounds corners and read off the vertical component.
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for corner in local.corners {
            let p = closed.matrix * SIMD4(corner, 1)
            let h = dot(SIMD3(p.x, p.y, p.z) - hinge, up)
            lo = min(lo, h); hi = max(hi, h)
        }
        heightRange = lo...hi
    }

    // MARK: - Session

    func run() async {
        guard HandTrackingProvider.isSupported else {
            appModel.aedStatus = "Hand tracking needs a Vision Pro. Tap the cabinet to open it instead."
            return
        }
        let auth = await session.requestAuthorization(for: [.handTracking, .worldSensing])
        var providers: [any DataProvider] = []
        if auth[.handTracking] == .allowed { providers.append(handTracking) }
        if auth[.worldSensing] == .allowed, PlaneDetectionProvider.isSupported { providers.append(planeDetection) }
        if WorldTrackingProvider.isSupported { providers.append(worldTracking) }
        guard !providers.isEmpty else {
            appModel.aedStatus = "Hand tracking permission denied."
            return
        }
        do {
            try await session.run(providers)
            appModel.aedStatus = "Tracking hands"
        } catch {
            appModel.aedStatus = "ARKit failed: \(error.localizedDescription)"
            return
        }
        if providers.contains(where: { $0 === planeDetection }) { await consumeWalls() }
    }

    func stop() { session.stop() }

    private func consumeWalls() async {
        for await update in planeDetection.anchorUpdates {
            switch update.event {
            case .added, .updated: walls[update.anchor.id] = update.anchor
            case .removed: walls.removeValue(forKey: update.anchor.id)
            }
            guard appModel.aedAttachToWall else { continue }
            if !placedOnWall {
                tryPlaceOnWall()
            } else if update.anchor.id == mountedWallID, update.event == .updated {
                // ARKit keeps refining the wall; re-seat so the cabinet stays flush instead of floating or sinking.
                seat(on: update.anchor, at: mountPoint, animated: false)
            }
        }
    }

    // MARK: - Placement

    private func placeFloating() {
        // Immersive-space origin is at your feet, facing -Z. Front of the cabinet faces +Z, i.e. you.
        holder.transform = Transform(rotation: simd_quatf(angle: .pi, axis: [0, 1, 0]), translation: [0, 1.3, -1.2])
        placedOnWall = false
        mountedWallID = nil
        wallShadow.isEnabled = false
    }

    /// Mounts on the wall you're looking at; falls back to the wall nearest you.
    private func tryPlaceOnWall() {
        let candidates = walls.values.filter { $0.geometry.extent.width * $0.geometry.extent.height > 0.3 }
        guard !candidates.isEmpty else {
            appModel.aedStatus = "Looking for a wall… look around the room"
            return
        }

        let device = worldTracking.state == .running
            ? worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) : nil
        let eye: SIMD3<Float> = device.map { SIMD3($0.originFromAnchorTransform.columns.3.x, $0.originFromAnchorTransform.columns.3.y, $0.originFromAnchorTransform.columns.3.z) } ?? [0, 1.5, 0]

        // Gaze ray (device -Z) against every wall; take the closest hit that lands on the wall's extent.
        var best: (wall: PlaneAnchor, point: SIMD3<Float>, t: Float)?
        if let device {
            let c2 = device.originFromAnchorTransform.columns.2
            let forward = -simd_normalize(SIMD3(c2.x, c2.y, c2.z))
            for wall in candidates {
                let (c, n) = (center(of: wall), normal(of: wall, facing: eye))
                let denom = dot(forward, n)
                guard abs(denom) > 0.1 else { continue }
                let t = dot(c - eye, n) / denom
                guard t > 0.2, t < 8 else { continue }
                let hit = eye + forward * t
                guard isOnWall(hit, wall), t < best?.t ?? .infinity else { continue }
                best = (wall, hit, t)
            }
        }
        if best == nil, let nearest = candidates.min(by: { distance(center(of: $0), eye) < distance(center(of: $1), eye) }) {
            // Nothing under your gaze: use the point on the nearest wall straight across from you.
            let c = center(of: nearest), n = normal(of: nearest, facing: eye)
            best = (nearest, eye - dot(eye - c, n) * n, 0)
        }
        guard let best else { return }

        mountedWallID = best.wall.id
        mountPoint = [best.point.x, mountHeight, best.point.z]
        mountViewer = eye
        seat(on: best.wall, at: mountPoint, animated: true)
        placedOnWall = true
        appModel.aedStatus = String(format: "Mounted on wall · cabinet is %.0f cm deep", appModel.aedCabinetDepth * 100)
    }

    /// Places the cabinet's back flat on `wall`, at `point` projected onto the plane, upright.
    private func seat(on wall: PlaneAnchor, at point: SIMD3<Float>, animated: Bool) {
        let n = normal(of: wall, facing: mountViewer)
        let c = center(of: wall)
        // Keep the normal horizontal so the cabinet is never tilted by a slightly-off plane estimate.
        let flatN = simd_normalize(SIMD3(n.x, 0, n.z))
        let onPlane = point - dot(point - c, flatN) * flatN
        let rotation = simd_quatf(simd_float3x3(simd_normalize(cross([0, 1, 0], flatN)), [0, 1, 0], flatN))
        let target = Transform(rotation: rotation, translation: onPlane + flatN * appModel.aedWallGap)

        if animated {
            holder.move(to: target, relativeTo: nil, duration: 0.5, timingFunction: .easeOut)
        } else {
            holder.transform = target
        }
        wallShadow.isEnabled = true
    }

    private func normal(of plane: PlaneAnchor, facing viewer: SIMD3<Float>) -> SIMD3<Float> {
        let m = plane.originFromAnchorTransform * plane.geometry.extent.anchorFromExtentTransform
        // A plane's extent lies in its X-Y plane (RealityKit's generatePlane(width:height:) convention),
        // so the surface normal is the Z column. Reading Y here points ALONG the wall, which turns
        // the cabinet sideways and makes the wall gap slide it deeper in.
        var n = simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        // The normal should point into the room; if it points away from the viewer, flip it.
        if dot(n, viewer - center(of: plane)) < 0 { n = -n }
        return n
    }

    /// Whether a point on the plane lies within its detected extent (with a little slack).
    private func isOnWall(_ p: SIMD3<Float>, _ plane: PlaneAnchor) -> Bool {
        let m = plane.originFromAnchorTransform * plane.geometry.extent.anchorFromExtentTransform
        let local = m.inverse * SIMD4(p, 1)
        let e = plane.geometry.extent
        return abs(local.x) <= e.width / 2 + 0.3 && abs(local.y) <= e.height / 2 + 0.3
    }

    // MARK: - Realism

    private static func enableGroundingShadows(on entity: Entity) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        entity.children.forEach(enableGroundingShadows(on:))
    }

    /// Builds a blurred dark rectangle, slightly larger than the cabinet and dropped a little
    /// (light usually comes from above), sitting just in front of the wall behind the cabinet.
    private func makeWallShadow(width: Float, height: Float) async {
        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Nested rounded rects with rising brightness approximate a gaussian falloff at the edges.
        let steps = 40
        for k in 0..<steps {
            let inset = CGFloat(k) * CGFloat(size) * 0.2 / CGFloat(steps)
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
            ctx.setFillColor(gray: CGFloat(k + 1) / CGFloat(steps), alpha: 1)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil))
            ctx.fillPath()
        }
        guard let image = ctx.makeImage(),
              let texture = try? await TextureResource(image: image, options: .init(semantic: .raw)) else { return }

        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: .init(scale: 0.55, texture: .init(texture)))
        wallShadow.model = ModelComponent(
            mesh: .generatePlane(width: width * 1.35, height: height * 1.4, cornerRadius: 0),
            materials: [material]
        )
        wallShadow.position = [0, -0.02, 0.001]
        wallShadow.isEnabled = false
        holder.addChild(wallShadow)
    }

    private func center(of plane: PlaneAnchor) -> SIMD3<Float> {
        let m = plane.originFromAnchorTransform * plane.geometry.extent.anchorFromExtentTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    // MARK: - Per-frame update

    func update(deltaTime: TimeInterval) {
        guard let door, let parent = door.parent else { return }
        let dt = Float(min(deltaTime, 1.0 / 30))

        if appModel.aedAttachToWall != lastAttachSetting {
            lastAttachSetting = appModel.aedAttachToWall
            if appModel.aedAttachToWall { placedOnWall = false; tryPlaceOnWall() } else { placeFloating() }
        }
        if appModel.aedFlipCabinet != lastFlip, let model {
            lastFlip = appModel.aedFlipCabinet
            orient(model: model, flipped: lastFlip)
        }
        if placedOnWall, appModel.aedWallGap != lastWallGap, let id = mountedWallID, let wall = walls[id] {
            lastWallGap = appModel.aedWallGap
            seat(on: wall, at: mountPoint, animated: false)
        }
        if appModel.aedPlaceRequest != lastPlaceRequest {
            lastPlaceRequest = appModel.aedPlaceRequest
            if appModel.aedAttachToWall { tryPlaceOnWall() }
        }

        let anchors = handTracking.latestAnchors
        let allPoses = [anchors.leftHand, anchors.rightHand].compactMap { $0 }.compactMap(HandPose.init(anchor:))

        // The AED: grab it by the handle once the door is open, carry it, drop it or put it back.
        carry?.update(poses: allPoses, doorAngle: angle, dt: dt) { appModel.aedStatus = $0 }
        // The hand carrying the AED is busy; it neither pulls nor pushes the door.
        let poses = allPoses.filter { $0.chirality != carry?.carryingHand }

        var target = angle
        var driven = false

        // 1. Pull: pinch near the handle and the door follows your pinch around the hinge.
        if let grab = resolveGrab(poses: poses, parent: parent) {
            target = grab
            driven = true
        }

        // 2. Push: any fingertip inside the slab shoves the door out of the way.
        if !driven {
            for pose in poses {
                for joint in Self.fingertips {
                    guard let p = pose[joint] else { continue }
                    if let pushed = push(from: parent.convert(position: p, from: nil), current: target) {
                        target = pushed
                        driven = true
                    }
                }
            }
        }

        // 3. Free swing with damping when nothing is touching it.
        if driven {
            angularVelocity = (target - angle) / dt
            angle = target
        } else {
            angle += angularVelocity * dt
            angularVelocity *= pow(0.02, dt)   // ~98% gone after one second
        }

        // Clamp to the hinge's range, in "open is positive" terms.
        let s: Float = openAngle > 0 ? 1 : -1
        let clamped = min(max(angle * s, 0), abs(openAngle)) * s
        if clamped != angle { angularVelocity = 0; angle = clamped }
        if abs(angle) < 0.02, abs(angularVelocity) < 0.05 { angle = 0; angularVelocity = 0 }

        var t = closed
        t.rotation = simd_quatf(angle: angle, axis: up) * closed.rotation
        door.transform = t
    }

    /// Tap fallback (works in the simulator): animate to the opposite end.
    func toggle() {
        guard let door, let parent = door.parent else { return }
        let s: Float = openAngle > 0 ? 1 : -1
        angle = angle * s < abs(openAngle) / 2 ? openAngle : 0
        angularVelocity = 0
        var t = closed
        t.rotation = simd_quatf(angle: angle, axis: up) * closed.rotation
        door.move(to: t, relativeTo: parent, duration: 1.2, timingFunction: .easeInOut)
    }

    // MARK: - Touch model

    private static let fingertips: [HandSkeleton.JointName] = [
        .thumbTip, .indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip,
    ]

    /// Angle around the hinge (signed like `openAngle` convention), distance from hinge, height.
    private func polar(_ p: SIMD3<Float>) -> (theta: Float, r: Float, h: Float) {
        let v = p - hinge
        let flat = HingeMath.flatten(v, along: up)
        return (HingeMath.signedAngle(from: closedDir, to: flat, around: up), length(flat), dot(v, up))
    }

    private var handleWorld: SIMD3<Float>? {
        door?.convert(position: handleLocal, to: nil)
    }

    private func resolveGrab(poses: [HandPose], parent: Entity) -> Float? {
        guard let handle = handleWorld else { return nil }

        // Keep an existing grab while that hand is still pinching.
        if let hand = grabbingHand {
            if let pose = poses.first(where: { $0.chirality == hand }),
               let d = pose.pinchDistance, d < 0.035, let pinch = pose.pinchPoint {
                return angleFor(pinch: parent.convert(position: pinch, from: nil))
            }
            grabbingHand = nil
            return nil
        }

        // Start a grab: pinch closed within reach of the handle.
        for pose in poses {
            if let d = pose.pinchDistance, d < 0.02, let pinch = pose.pinchPoint, distance(pinch, handle) < grabRadius {
                grabbingHand = pose.chirality
                return angleFor(pinch: parent.convert(position: pinch, from: nil))
            }
        }
        return nil
    }

    private func angleFor(pinch: SIMD3<Float>) -> Float? {
        let (theta, r, _) = polar(pinch)
        return r > 0.03 ? theta : nil
    }

    /// If `p` (parent space) is inside the door slab at `current`, returns the angle that moves the slab just clear of it.
    private func push(from p: SIMD3<Float>, current: Float) -> Float? {
        let (theta, r, h) = polar(p)
        guard r > 0.03, r < width + fingerRadius, heightRange.contains(h) else { return nil }

        let halfSlab = thickness / 2 + fingerRadius
        let gap = (theta - current) * r          // signed distance from the slab plane, + = outer side
        guard abs(gap) < halfSlab else { return nil }

        // Push the door away from the finger, along whichever side it's on.
        return gap >= 0 ? theta - halfSlab / r : theta + halfSlab / r
    }
}

// MARK: - Shared hinge maths

enum HingeMath {
    static func worldUp(in parent: Entity) -> SIMD3<Float> {
        normalize(parent.convert(direction: [0, 1, 0], from: nil))
    }

    /// Removes the component of `v` that lies along `axis`, leaving the part in the hinge plane.
    static func flatten(_ v: SIMD3<Float>, along axis: SIMD3<Float>) -> SIMD3<Float> {
        v - dot(v, axis) * axis
    }

    /// Angle to rotate `a` onto `b` around `axis`. Positive = counter-clockwise looking down the axis.
    static func signedAngle(from a: SIMD3<Float>, to b: SIMD3<Float>, around axis: SIMD3<Float>) -> Float {
        atan2(dot(cross(a, b), axis), dot(a, b))
    }
}

private extension BoundingBox {
    var corners: [SIMD3<Float>] {
        [min.x, max.x].flatMap { x in [min.y, max.y].flatMap { y in [min.z, max.z].map { z in SIMD3(x, y, z) } } }
    }
}
