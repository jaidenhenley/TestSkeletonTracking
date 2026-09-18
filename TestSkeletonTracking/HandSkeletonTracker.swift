//
//  HandSkeletonTracker.swift
//  TestSkeletonTracking
//
//  Drives every ARKit provider and renders the hand skeletons with native RealityKit entities.
//

import ARKit
import QuartzCore
import RealityKit
import UIKit

@MainActor
final class HandSkeletonTracker {
    let root = Entity()

    private let appModel: AppModel
    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private let sceneReconstruction = SceneReconstructionProvider(modes: [])

    private var hands: [HandAnchor.Chirality: HandVisual] = [:]
    private var detectors: [HandAnchor.Chirality: GestureDetector] = [.left: .init(), .right: .init()]
    private var grabs: [HandAnchor.Chirality: Grab] = [:]
    private var spawned: [ModelEntity] = []
    private var sceneMeshes: [UUID: Entity] = [:]

    private let measureBar: ModelEntity
    private let measureLabel: Entity?
    private let handLabels: [HandAnchor.Chirality: Entity]

    private var handDistance: Float?
    private var wasClapReady = false
    private var lastClapTime: TimeInterval = 0
    private var lastStatsPush: TimeInterval = 0
    private var frameCount = 0
    private var lastClearRequest = 0

    private var stretch: Stretch?
    private var heldMotion: [ObjectIdentifier: (last: SIMD3<Float>, velocity: SIMD3<Float>)] = [:]
    private var highlighted: Set<ObjectIdentifier> = []
    private var lastDropRequest = 0
    private var palmHolds: [HandAnchor.Chirality: PalmHold] = [:]
    private var palmMotion: [HandAnchor.Chirality: (last: SIMD3<Float>, velocity: SIMD3<Float>)] = [:]
    /// Objects that just left a palm can't be re-caught instantly (otherwise they'd never fall off).
    private var palmCooldown: [ObjectIdentifier: TimeInterval] = [:]
    private var pendingHighlights: Set<ObjectIdentifier> = []

    /// An object resting in an upturned palm, stored in the palm's own frame so it rides along as you move.
    private struct PalmHold {
        let entity: ModelEntity
        let restHeight: Float
        let localRotation: simd_quatf
        var lastSeen: TimeInterval
        var tiltStart: TimeInterval?
    }
    private var palmArrows: [HandAnchor.Chirality: ModelEntity] = [:]

    /// One hand holding an object. Captures the hand→object offset at grab time so the object
    /// keeps its relative position and turns with your wrist instead of snapping to your fingers.
    private struct Grab {
        let entity: ModelEntity
        var pinch0: SIMD3<Float>
        var handRotation0: simd_quatf
        var position0: SIMD3<Float>
        var rotation0: simd_quatf
    }

    /// Both hands pinching the same object: distance between hands drives scale along one local axis.
    private struct Stretch {
        let entity: ModelEntity
        let midpoint0: SIMD3<Float>
        let direction0: SIMD3<Float>
        let distance0: Float
        let position0: SIMD3<Float>
        let rotation0: simd_quatf
        let scale0: SIMD3<Float>
        let axis: Int
    }

    init(appModel: AppModel, leftLabel: Entity?, rightLabel: Entity?, measureLabel: Entity?) {
        self.appModel = appModel
        self.measureLabel = measureLabel
        var labels: [HandAnchor.Chirality: Entity] = [:]
        labels[.left] = leftLabel
        labels[.right] = rightLabel
        self.handLabels = labels

        hands[.left] = HandVisual(chirality: .left)
        hands[.right] = HandVisual(chirality: .right)
        for hand in hands.values { root.addChild(hand.root) }
        for label in labels.values { root.addChild(label) }
        if let measureLabel { root.addChild(measureLabel) }

        measureBar = ModelEntity(
            mesh: .generateCylinder(height: 1, radius: 0.0015),
            materials: [UnlitMaterial(color: .white.withAlphaComponent(0.8))]
        )
        root.addChild(measureBar)

        for chirality in [HandAnchor.Chirality.left, .right] {
            let arrow = ModelEntity(mesh: .generateCylinder(height: 0.08, radius: 0.002),
                                    materials: [UnlitMaterial(color: .systemYellow)])
            let tip = ModelEntity(mesh: .generateCone(height: 0.015, radius: 0.006),
                                  materials: [UnlitMaterial(color: .systemYellow)])
            tip.position = [0, 0.045, 0]
            arrow.addChild(tip)
            arrow.isEnabled = false
            root.addChild(arrow)
            palmArrows[chirality] = arrow
        }

        addFallbackFloor()
    }

    // MARK: - Session

    func run() async {
        guard HandTrackingProvider.isSupported else {
            appModel.status = "Hand tracking isn't supported here — run on a Vision Pro device."
            return
        }

        let auth = await session.requestAuthorization(for: [.handTracking, .worldSensing])
        var providers: [any DataProvider] = []
        if auth[.handTracking] == .allowed { providers.append(handTracking) }
        if auth[.worldSensing] == .allowed, SceneReconstructionProvider.isSupported {
            providers.append(sceneReconstruction)
        }
        guard !providers.isEmpty else {
            appModel.status = "Hand tracking permission denied."
            return
        }

        do {
            try await session.run(providers)
            appModel.status = providers.count > 1 ? "Tracking hands + scene mesh" : "Tracking hands"
        } catch {
            appModel.status = "ARKit failed: \(error.localizedDescription)"
            return
        }

        if providers.count > 1 { await consumeSceneMeshes() }
    }

    func stop() { session.stop() }

    /// Real-world surfaces become static colliders so thrown objects land on your actual table/floor.
    private func consumeSceneMeshes() async {
        for await update in sceneReconstruction.anchorUpdates {
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                guard let shape = try? await ShapeResource.generateStaticMesh(from: anchor) else { continue }
                let entity = sceneMeshes[anchor.id] ?? {
                    let e = Entity()
                    root.addChild(e)
                    sceneMeshes[anchor.id] = e
                    return e
                }()
                entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
                entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                entity.components.set(PhysicsBodyComponent(mode: .static))
            case .removed:
                sceneMeshes.removeValue(forKey: anchor.id)?.removeFromParent()
            @unknown default:
                break
            }
            appModel.sceneMeshCount = sceneMeshes.count
        }
    }

    // MARK: - Per-frame update

    func update(deltaTime: TimeInterval) {
        frameCount += 1
        if appModel.clearRequest != lastClearRequest {
            lastClearRequest = appModel.clearRequest
            clearSpawned()
        }
        if appModel.dropRequest != lastDropRequest {
            lastDropRequest = appModel.dropRequest
            dropObjects()
        }
        guard handTracking.state == .running else { return }

        let (left, right): (HandAnchor?, HandAnchor?) = {
            if appModel.usePredictedAnchors {
                // Predicts joint poses for the moment this frame hits the display → lower perceived latency.
                let predicted = handTracking.handAnchors(at: CACurrentMediaTime())
                return (predicted.leftHand, predicted.rightHand)
            }
            return (handTracking.latestAnchors.leftHand, handTracking.latestAnchors.rightHand)
        }()

        var poses: [HandAnchor.Chirality: HandPose] = [:]
        var stats: [HandAnchor.Chirality: HandStats] = [:]

        for (chirality, anchor) in [(HandAnchor.Chirality.left, left), (.right, right)] {
            guard let visual = hands[chirality] else { continue }
            let pose = anchor.flatMap(HandPose.init(anchor:))
            // An upturned palm's collider would shove objects away before you could scoop them.
            let palmUp = appModel.grabStyle != .pinch && (pose?.palmNormal.map { simd_dot($0, [0, 1, 0]) > 0.3 } ?? false)
            visual.apply(anchor: anchor, model: appModel, deltaTime: Float(deltaTime), palmColliderEnabled: !palmUp)

            var s = HandStats()
            if let anchor, let pose {
                poses[chirality] = pose
                let gesture = detectors[chirality]!.classify(pose)
                s.isTracked = true
                s.trackedJoints = anchor.handSkeleton?.allJoints.filter(\.isTracked).count ?? 0
                s.gesture = gesture
                s.pinchDistance = pose.pinchDistance ?? 0
                s.curls = pose.curls
                s.palmFacingUp = pose.palmNormal.map { simd_dot($0, [0, 1, 0]) } ?? 0
                updatePalmArrow(chirality: chirality, pose: pose)
                updateLabel(chirality: chirality, pose: pose)
            } else {
                handLabels[chirality]?.isEnabled = false
                palmArrows[chirality]?.isEnabled = false
            }
            stats[chirality] = s
        }

        updateGrabs(poses: poses, stats: stats, deltaTime: Float(deltaTime))
        updatePalms(poses: poses, stats: stats, deltaTime: Float(deltaTime))
        updateHighlights(pendingHighlights)
        for chirality in [HandAnchor.Chirality.left, .right] { stats[chirality]?.isHoldingInPalm = palmHolds[chirality] != nil }

        updateTwoHanded(poses)
        pushStats(stats)
    }

    // MARK: - Interactions

    private func updateGrabs(poses: [HandAnchor.Chirality: HandPose], stats: [HandAnchor.Chirality: HandStats], deltaTime: Float) {
        let chiralities: [HandAnchor.Chirality] = [.left, .right]
        guard appModel.physicsEnabled else {
            chiralities.forEach { releaseGrab(chirality: $0, poses: poses) }
            pendingHighlights = []
            return
        }

        var hovered: Set<ObjectIdentifier> = []
        for chirality in chiralities {
            guard let pose = poses[chirality], let point = pose.pinchPoint,
                  stats[chirality]?.gesture == .pinch else {
                releaseGrab(chirality: chirality, poses: poses)
                if let point = poses[chirality]?.pinchPoint, let near = nearestObject(to: point, within: 0.05) {
                    hovered.insert(ObjectIdentifier(near))
                }
                continue
            }
            guard grabs[chirality] == nil else { continue }

            let target = nearestObject(to: point, within: 0.04)
            if appModel.grabStyle == .palm {
                // Palm mode: a pinch only does something when both hands pinch the same object (stretch).
                let other: HandAnchor.Chirality = chirality == .left ? .right : .left
                guard let target else { continue }
                let otherTarget = grabs[other]?.entity ?? {
                    guard stats[other]?.gesture == .pinch, let p = poses[other]?.pinchPoint else { return nil }
                    return nearestObject(to: p, within: 0.04)
                }()
                if otherTarget === target { beginGrab(chirality: chirality, entity: target, pose: pose) }
            } else if let target {
                beginGrab(chirality: chirality, entity: target, pose: pose)
            } else if appModel.spawnOnEmptyPinch {
                let entity = makeThrowable()
                entity.position = point
                addSpawned(entity)
                beginGrab(chirality: chirality, entity: entity, pose: pose)
            }
        }

        // Both hands on the same object → stretch. Otherwise each hand moves its own object.
        if let l = grabs[.left], let r = grabs[.right], l.entity === r.entity,
           let lp = poses[.left]?.pinchPoint, let rp = poses[.right]?.pinchPoint {
            if stretch?.entity !== l.entity { beginStretch(entity: l.entity, left: lp, right: rp) }
            applyStretch(left: lp, right: rp)
        } else {
            stretch = nil
            for chirality in chiralities {
                guard let grab = grabs[chirality], let pose = poses[chirality],
                      let point = pose.pinchPoint, let rotation = pose.handRotation else { continue }
                let delta = rotation * grab.handRotation0.inverse
                grab.entity.position = point + delta.act(grab.position0 - grab.pinch0)
                grab.entity.orientation = delta * grab.rotation0
            }
        }

        // Track held-object velocity so releasing throws it.
        for grab in grabs.values {
            let id = ObjectIdentifier(grab.entity)
            let p = grab.entity.position
            if let motion = heldMotion[id], deltaTime > 0 {
                let v = (p - motion.last) / deltaTime
                heldMotion[id] = (p, simd_mix(motion.velocity, v, SIMD3(repeating: 0.5)))
            } else {
                heldMotion[id] = (p, .zero)
            }
            hovered.insert(id)
        }
        pendingHighlights = hovered
    }

    private func beginGrab(chirality: HandAnchor.Chirality, entity: ModelEntity, pose: HandPose) {
        guard let point = pose.pinchPoint, let rotation = pose.handRotation else { return }
        entity.physicsBody?.mode = .kinematic
        entity.components.remove(PhysicsMotionComponent.self)
        palmHolds = palmHolds.filter { $0.value.entity !== entity } // pinching takes it out of your palm
        grabs[chirality] = Grab(entity: entity, pinch0: point, handRotation0: rotation,
                                position0: entity.position, rotation0: entity.orientation)
    }

    private func releaseGrab(chirality: HandAnchor.Chirality, poses: [HandAnchor.Chirality: HandPose]) {
        guard let grab = grabs.removeValue(forKey: chirality) else { return }
        let other: HandAnchor.Chirality = chirality == .left ? .right : .left

        if grabs[other]?.entity === grab.entity, appModel.grabStyle == .palm {
            // In palm mode pinching is only for stretching, so letting go with either hand drops it.
            grabs.removeValue(forKey: other)
            stretch = nil
        } else if grabs[other]?.entity === grab.entity {
            // Still held by the other hand: re-anchor to it so the object doesn't jump.
            stretch = nil
            if let pose = poses[other] { beginGrab(chirality: other, entity: grab.entity, pose: pose) }
            return
        }

        let id = ObjectIdentifier(grab.entity)
        let velocity = heldMotion.removeValue(forKey: id)?.velocity ?? .zero
        grab.entity.physicsBody?.mode = .dynamic
        grab.entity.components.set(PhysicsMotionComponent(linearVelocity: velocity * 1.2))
    }

    // MARK: Palm holding

    private func updatePalms(poses: [HandAnchor.Chirality: HandPose], stats: [HandAnchor.Chirality: HandStats], deltaTime: Float) {
        let now = CACurrentMediaTime()
        palmCooldown = palmCooldown.filter { now - $0.value < 0.15 }

        guard appModel.physicsEnabled, appModel.grabStyle != .pinch else {
            for chirality in Array(palmHolds.keys) { dropFromPalm(chirality, velocity: .zero, reason: nil) }
            return
        }

        for chirality in [HandAnchor.Chirality.left, .right] {
            guard let pose = poses[chirality], let center = pose.palmCenter,
                  let normal = pose.palmNormal, let rotation = pose.palmRotation else {
                palmMotion[chirality] = nil
                // Ride out brief tracking dropouts instead of dropping the object immediately.
                if let hold = palmHolds[chirality], now - hold.lastSeen > 0.35 {
                    dropFromPalm(chirality, velocity: .zero, reason: "hand tracking lost")
                }
                continue
            }

            let velocity: SIMD3<Float> = {
                guard let m = palmMotion[chirality], deltaTime > 0 else { return .zero }
                return simd_mix(m.velocity, (center - m.last) / deltaTime, SIMD3(repeating: 0.25))
            }()
            palmMotion[chirality] = (center, velocity)
            let facingUp = simd_dot(normal, [0, 1, 0])

            if var hold = palmHolds[chirality] {
                hold.lastSeen = now
                let gripping = stats[chirality]?.gesture == .fist

                if velocity.y > 1.8 {
                    dropFromPalm(chirality, velocity: velocity * 1.3, reason: "tossed")
                    continue
                }
                // Must stay tipped over briefly, so one jittery frame doesn't pour it out.
                if !gripping && facingUp < 0.1 {
                    hold.tiltStart = hold.tiltStart ?? now
                    if now - hold.tiltStart! > 0.1 {
                        dropFromPalm(chirality, velocity: velocity, reason: "hand tipped over")
                        continue
                    }
                } else {
                    hold.tiltStart = nil
                }

                let target = center + rotation.act([0, hold.restHeight, 0])
                hold.entity.position = simd_mix(hold.entity.position, target, SIMD3(repeating: 0.6))
                hold.entity.orientation = simd_slerp(hold.entity.orientation, rotation * hold.localRotation, 0.6)
                palmHolds[chirality] = hold
                pendingHighlights.insert(ObjectIdentifier(hold.entity))
                continue
            }

            guard facingUp > 0.45, stats[chirality]?.gesture != .pinch else { continue }
            // Generous catch zone above the palm so falling or tossed objects get caught, not passed through.
            let probe = center + normal * 0.04
            if let entity = nearestObject(to: probe, within: 0.07, excludingHeld: true) {
                let id = ObjectIdentifier(entity)
                guard palmCooldown[id] == nil else { continue }
                let bounds = entity.visualBounds(relativeTo: nil)
                let halfThickness = simd_dot(bounds.extents / 2, simd_abs(normal))
                entity.physicsBody?.mode = .kinematic
                entity.components.remove(PhysicsMotionComponent.self)
                palmHolds[chirality] = PalmHold(entity: entity, restHeight: halfThickness + 0.015,
                                                localRotation: rotation.inverse * entity.orientation,
                                                lastSeen: now)
                appModel.lastPalmEvent = "\(chirality == .left ? "Left" : "Right") palm caught an object"
            } else if let near = nearestObject(to: probe, within: 0.12, excludingHeld: true) {
                pendingHighlights.insert(ObjectIdentifier(near))
            }
        }
    }

    private func dropFromPalm(_ chirality: HandAnchor.Chirality, velocity: SIMD3<Float>, reason: String?) {
        guard let hold = palmHolds.removeValue(forKey: chirality) else { return }
        palmCooldown[ObjectIdentifier(hold.entity)] = CACurrentMediaTime()
        hold.entity.physicsBody?.mode = .dynamic
        hold.entity.components.set(PhysicsMotionComponent(linearVelocity: velocity))
        if let reason {
            appModel.lastPalmEvent = "\(chirality == .left ? "Left" : "Right") palm dropped it: \(reason)"
        }
    }

    /// Yellow arrow out of the palm (shown with joint axes) — lets you verify palm-up detection in the headset.
    private func updatePalmArrow(chirality: HandAnchor.Chirality, pose: HandPose) {
        guard let arrow = palmArrows[chirality] else { return }
        arrow.isEnabled = appModel.showJointAxes
        guard appModel.showJointAxes, let center = pose.palmCenter, let normal = pose.palmNormal else { return }
        arrow.position = center + normal * 0.04
        arrow.orientation = simd_quatf(from: [0, 1, 0], to: normal)
    }

    private func isHeld(_ entity: ModelEntity) -> Bool {
        grabs.values.contains { $0.entity === entity } || palmHolds.values.contains { $0.entity === entity }
    }

    private func beginStretch(entity: ModelEntity, left: SIMD3<Float>, right: SIMD3<Float>) {
        let d = right - left
        let distance = max(simd_length(d), 1e-3)
        let direction = d / distance
        // Stretch along whichever of the object's own axes best lines up with your hands.
        let axes: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { entity.orientation.act($0) }
        let axis = axes.indices.max { abs(simd_dot(axes[$0], direction)) < abs(simd_dot(axes[$1], direction)) }!
        stretch = Stretch(entity: entity, midpoint0: (left + right) / 2, direction0: direction,
                          distance0: distance, position0: entity.position, rotation0: entity.orientation,
                          scale0: entity.scale, axis: axis)
    }

    private func applyStretch(left: SIMD3<Float>, right: SIMD3<Float>) {
        guard let st = stretch else { return }
        let d = right - left
        let distance = max(simd_length(d), 1e-3)
        let ratio = distance / st.distance0
        let turn = simd_quatf(from: st.direction0, to: d / distance)
        let mid = (left + right) / 2

        var scale = st.scale0
        if appModel.uniformStretch {
            scale = st.scale0 * ratio
        } else {
            scale[st.axis] = st.scale0[st.axis] * ratio
        }
        st.entity.scale = simd_clamp(scale, SIMD3(repeating: 0.2), SIMD3(repeating: 15))
        st.entity.orientation = turn * st.rotation0
        st.entity.position = mid + turn.act(st.position0 - st.midpoint0)
    }

    /// Closest spawned object whose (possibly stretched) bounds are within `radius` of `point`.
    private func nearestObject(to point: SIMD3<Float>, within radius: Float, excludingHeld: Bool = false) -> ModelEntity? {
        var best: (ModelEntity, Float)?
        for entity in spawned where !(excludingHeld && isHeld(entity)) {
            let bounds = entity.visualBounds(relativeTo: nil)
            let closest = simd_clamp(point, bounds.min, bounds.max)
            let distance = simd_distance(point, closest)
            if distance <= radius, distance < best?.1 ?? .infinity { best = (entity, distance) }
        }
        return best?.0
    }

    /// Objects glow brighter when a hand is close enough to grab them, or is holding them.
    private func updateHighlights(_ ids: Set<ObjectIdentifier>) {
        guard ids != highlighted else { return }
        for entity in spawned {
            let id = ObjectIdentifier(entity)
            let on = ids.contains(id)
            guard on != highlighted.contains(id),
                  var material = entity.model?.materials.first as? PhysicallyBasedMaterial else { continue }
            material.emissiveIntensity = on ? 2.5 : 0.4
            entity.model?.materials = [material]
        }
        highlighted = ids
    }

    private func addSpawned(_ entity: ModelEntity) {
        root.addChild(entity)
        spawned.append(entity)
        appModel.spawnedObjects += 1
        if spawned.count > 60 {
            let old = spawned.removeFirst()
            grabs = grabs.filter { $0.value.entity !== old }
            palmHolds = palmHolds.filter { $0.value.entity !== old }
            old.removeFromParent()
        }
    }

    /// Rains a handful of objects onto the floor in front of where the space opened.
    private func dropObjects() {
        for _ in 0..<8 {
            let entity = makeThrowable()
            entity.physicsBody?.mode = .dynamic
            entity.position = [.random(in: -0.5...0.5), .random(in: 1.2...1.6), .random(in: -1.2 ... -0.5)]
            entity.orientation = simd_quatf(angle: .random(in: 0...(2 * .pi)), axis: simd_normalize(SIMD3<Float>.random(in: -1...1)))
            addSpawned(entity)
        }
    }

    private func makeThrowable() -> ModelEntity {
        let color = UIColor(hue: .random(in: 0...1), saturation: 0.8, brightness: 1, alpha: 1)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.2
        material.metallic = 0.6
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.4

        let entity: ModelEntity
        switch Int.random(in: 0..<3) {
        case 0:
            entity = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [material])
            entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.025)]))
        case 1:
            entity = ModelEntity(mesh: .generateBox(size: 0.045, cornerRadius: 0.006), materials: [material])
            entity.components.set(CollisionComponent(shapes: [.generateBox(size: [0.045, 0.045, 0.045])]))
        default:
            entity = ModelEntity(mesh: .generateCone(height: 0.05, radius: 0.025), materials: [material])
            entity.components.set(CollisionComponent(shapes: [.generateConvex(from: entity.model!.mesh)]))
        }
        entity.components.set(PhysicsBodyComponent(
            massProperties: .init(mass: 0.1),
            material: .generate(staticFriction: 0.6, dynamicFriction: 0.5, restitution: 0.5),
            mode: .kinematic
        ))
        return entity
    }

    private func clearSpawned() {
        grabs.removeAll()
        stretch = nil
        palmHolds.removeAll()
        heldMotion.removeAll()
        highlighted.removeAll()
        spawned.forEach { $0.removeFromParent() }
        spawned.removeAll()
    }

    private func updateLabel(chirality: HandAnchor.Chirality, pose: HandPose) {
        guard let label = handLabels[chirality] else { return }
        label.isEnabled = appModel.showLabels
        guard appModel.showLabels, let wrist = pose[.wrist] else { return }
        label.position = wrist + [0, 0.12, 0]
    }

    /// Distance ruler between index tips, and clap detection with a particle burst.
    private func updateTwoHanded(_ poses: [HandAnchor.Chirality: HandPose]) {
        guard let l = poses[.left], let r = poses[.right],
              let li = l[.indexFingerTip], let ri = r[.indexFingerTip] else {
            measureBar.isEnabled = false
            measureLabel?.isEnabled = false
            handDistance = nil
            wasClapReady = false
            return
        }

        let delta = ri - li
        let length = simd_length(delta)
        handDistance = length
        measureBar.isEnabled = appModel.showLabels
        measureLabel?.isEnabled = appModel.showLabels
        measureBar.position = (li + ri) / 2
        measureBar.scale = [1, length, 1]
        if length > 1e-4 {
            measureBar.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
        }
        measureLabel?.position = (li + ri) / 2 + [0, 0.04, 0]

        if let lp = l.palmCenter, let rp = r.palmCenter {
            let palms = simd_distance(lp, rp)
            if palms > 0.2 { wasClapReady = true }
            let now = CACurrentMediaTime()
            if wasClapReady, palms < 0.07, now - lastClapTime > 0.3 {
                wasClapReady = false
                lastClapTime = now
                appModel.claps += 1
                spawnBurst(at: (lp + rp) / 2)
            }
        }
    }

    private func spawnBurst(at position: SIMD3<Float>) {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.02, 0.02, 0.02]
        emitter.birthDirection = .normal
        emitter.speed = 0.8
        emitter.isEmitting = false
        emitter.burstCount = 400
        emitter.mainEmitter.lifeSpan = 1.2
        emitter.mainEmitter.size = 0.006
        emitter.mainEmitter.acceleration = [0, -1.5, 0]
        emitter.mainEmitter.color = .evolving(
            start: .single(.systemYellow),
            end: .single(.systemPink.withAlphaComponent(0))
        )
        emitter.mainEmitter.blendMode = .additive
        emitter.burst()

        let entity = Entity()
        entity.position = position
        entity.components.set(emitter)
        root.addChild(entity)
        Task {
            try? await Task.sleep(for: .seconds(2))
            entity.removeFromParent()
        }
    }

    /// Catches objects at floor height when scene reconstruction isn't available (e.g. no permission).
    private func addFallbackFloor() {
        let floor = Entity()
        floor.position = [0, -0.05, 0]
        floor.components.set(CollisionComponent(shapes: [.generateBox(size: [20, 0.1, 20])], isStatic: true))
        floor.components.set(PhysicsBodyComponent(mode: .static))
        root.addChild(floor)
    }

    private func pushStats(_ stats: [HandAnchor.Chirality: HandStats]) {
        let now = CACurrentMediaTime()
        guard now - lastStatsPush > 0.1 else { return }
        appModel.updateRate = Double(frameCount) / (now - lastStatsPush)
        frameCount = 0
        lastStatsPush = now

        let left = stats[.left] ?? HandStats()
        let right = stats[.right] ?? HandStats()
        if appModel.left != left { appModel.left = left }
        if appModel.right != right { appModel.right = right }
        appModel.handDistance = handDistance
    }
}

// MARK: - Per-hand visuals

@MainActor
private final class HandVisual {
    let root = Entity()
    private var joints: [HandSkeleton.JointName: Entity] = [:]
    private var spheres: [HandSkeleton.JointName: ModelEntity] = [:]
    private var axes: [HandSkeleton.JointName: Entity] = [:]
    private var bones: [HandSkeleton.JointName: ModelEntity] = [:]
    private var colliders: [HandSkeleton.JointName: Entity] = [:]
    private var lastColliderPositions: [HandSkeleton.JointName: SIMD3<Float>] = [:]
    private var trails: [HandSkeleton.JointName: Entity] = [:]
    private var jointTracked: [HandSkeleton.JointName: Bool] = [:]

    private static let tips: [HandSkeleton.JointName] = [.thumbTip, .indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip]

    init(chirality: HandAnchor.Chirality) {
        let axisX = UnlitMaterial(color: .red), axisY = UnlitMaterial(color: .green), axisZ = UnlitMaterial(color: .blue)

        for name in HandSkeleton.JointName.allCases {
            let color = Self.color(for: name)
            let isTip = Self.tips.contains(name)

            let joint = Entity()
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: isTip ? 0.007 : 0.005),
                materials: [UnlitMaterial(color: color)]
            )
            joint.addChild(sphere)
            root.addChild(joint)
            joints[name] = joint
            spheres[name] = sphere

            // Local orientation gizmo: shows the full 6DoF transform of each joint.
            let gizmo = Entity()
            for (material, offset, size) in [
                (axisX, SIMD3<Float>(0.0125, 0, 0), SIMD3<Float>(0.025, 0.0015, 0.0015)),
                (axisY, SIMD3<Float>(0, 0.0125, 0), SIMD3<Float>(0.0015, 0.025, 0.0015)),
                (axisZ, SIMD3<Float>(0, 0, 0.0125), SIMD3<Float>(0.0015, 0.0015, 0.025)),
            ] {
                let bar = ModelEntity(mesh: .generateBox(size: size), materials: [material])
                bar.position = offset
                gizmo.addChild(bar)
            }
            joint.addChild(gizmo)
            axes[name] = gizmo

            let bone = ModelEntity(
                mesh: .generateCylinder(height: 1, radius: 0.0025),
                materials: [UnlitMaterial(color: color.withAlphaComponent(0.7))]
            )
            root.addChild(bone)
            bones[name] = bone

            if isTip || name == .middleFingerMetacarpal {
                let radius: Float = name == .middleFingerMetacarpal ? 0.035 : 0.009
                let collider = Entity()
                collider.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
                collider.components.set(PhysicsBodyComponent(mode: .kinematic))
                root.addChild(collider)
                colliders[name] = collider
            }

            if isTip {
                let trail = Entity()
                var emitter = ParticleEmitterComponent()
                emitter.emitterShape = .point
                emitter.speed = 0
                emitter.particlesInheritTransform = false
                emitter.mainEmitter.birthRate = name == .indexFingerTip ? 400 : 120
                emitter.mainEmitter.lifeSpan = 0.5
                emitter.mainEmitter.size = 0.003
                emitter.mainEmitter.blendMode = .additive
                emitter.mainEmitter.color = .evolving(
                    start: .single(color),
                    end: .single(color.withAlphaComponent(0))
                )
                trail.components.set(emitter)
                joint.addChild(trail)
                trails[name] = trail
            }
        }
    }

    func apply(anchor: HandAnchor?, model: AppModel, deltaTime: Float, palmColliderEnabled: Bool) {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            root.isEnabled = false
            lastColliderPositions.removeAll()
            return
        }
        root.isEnabled = true

        var world: [HandSkeleton.JointName: simd_float4x4] = [:]
        for joint in skeleton.allJoints {
            world[joint.name] = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        }

        for joint in skeleton.allJoints {
            let name = joint.name
            guard let entity = joints[name], let m = world[name] else { continue }
            entity.setTransformMatrix(m, relativeTo: nil)
            spheres[name]?.isEnabled = model.showJoints
            axes[name]?.isEnabled = model.showJointAxes
            trails[name]?.isEnabled = model.showFingertipTrails

            // Dim joints the system is only inferring (e.g. occluded behind the palm).
            if jointTracked[name] != joint.isTracked {
                jointTracked[name] = joint.isTracked
                spheres[name]?.components.set(OpacityComponent(opacity: joint.isTracked ? 1 : 0.25))
            }

            if let bone = bones[name] {
                if model.showBones, let parent = joint.parentJoint, let pm = world[parent.name] {
                    let a = SIMD3(pm.columns.3.x, pm.columns.3.y, pm.columns.3.z)
                    let b = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    let d = b - a, len = simd_length(d)
                    bone.isEnabled = len > 1e-4
                    if len > 1e-4 {
                        bone.position = (a + b) / 2
                        bone.scale = [1, len, 1]
                        bone.orientation = simd_quatf(from: [0, 1, 0], to: d / len)
                    }
                } else {
                    bone.isEnabled = false
                }
            }

            if let collider = colliders[name] {
                let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                collider.isEnabled = model.physicsEnabled && (name != .middleFingerMetacarpal || palmColliderEnabled)
                collider.position = p
                // Give kinematic colliders real velocity so they shove dynamic objects instead of teleporting.
                if let last = lastColliderPositions[name], deltaTime > 0 {
                    collider.components.set(PhysicsMotionComponent(linearVelocity: (p - last) / deltaTime))
                }
                lastColliderPositions[name] = p
            }
        }

    }

    static func color(for name: HandSkeleton.JointName) -> UIColor {
        switch name {
        case .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip:
            return .systemOrange
        case .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip:
            return .systemCyan
        case .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip:
            return .systemGreen
        case .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip:
            return .systemPurple
        case .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip:
            return .systemPink
        default:
            return .white
        }
    }
}
