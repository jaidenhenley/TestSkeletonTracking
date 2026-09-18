//
//  GestureDetector.swift
//  TestSkeletonTracking
//

import ARKit
import simd

enum Gesture: String {
    case none = "—"
    case pinch = "Pinch 🤏"
    case fist = "Fist ✊"
    case openPalm = "Open Palm 🖐️"
    case point = "Point 👉"
    case peace = "Peace ✌️"
    case thumbsUp = "Thumbs Up 👍"
    case rock = "Rock 🤘"
    case gun = "Finger Gun 🔫"
}

/// World-space joint positions for one hand, sampled once per frame.
/// Includes joints ARKit marks untracked: those positions are inferred but stable, whereas dropping
/// them makes palm/pinch data blink out for single frames.
struct HandPose {
    let chirality: HandAnchor.Chirality
    /// World orientation of the hand (wrist frame).
    let handRotation: simd_quatf?
    private let positions: [HandSkeleton.JointName: SIMD3<Float>]

    init?(anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        var positions: [HandSkeleton.JointName: SIMD3<Float>] = [:]
        for joint in skeleton.allJoints {
            let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            positions[joint.name] = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        self.chirality = anchor.chirality
        self.handRotation = simd_quatf(anchor.originFromAnchorTransform).normalized
        self.positions = positions
    }

    subscript(_ name: HandSkeleton.JointName) -> SIMD3<Float>? { positions[name] }

    var pinchDistance: Float? {
        guard let t = self[.thumbTip], let i = self[.indexFingerTip] else { return nil }
        return simd_distance(t, i)
    }

    var pinchPoint: SIMD3<Float>? {
        guard let t = self[.thumbTip], let i = self[.indexFingerTip] else { return nil }
        return (t + i) / 2
    }

    var palmCenter: SIMD3<Float>? { self[.middleFingerMetacarpal] }

    /// Unit vector pointing out of the palm (the side you'd hold something on).
    var palmNormal: SIMD3<Float>? {
        guard let wrist = self[.wrist], let index = self[.indexFingerKnuckle], let little = self[.littleFingerKnuckle] else { return nil }
        let n = simd_cross(index - wrist, little - wrist)
        guard simd_length(n) > 1e-6 else { return nil }
        return simd_normalize(chirality == .right ? n : -n)
    }

    /// Palm frame: +Y out of the palm, +Z from fingers back toward the wrist.
    var palmRotation: simd_quatf? {
        guard let y = palmNormal, let wrist = self[.wrist], let knuckle = self[.middleFingerKnuckle] else { return nil }
        let back = wrist - knuckle
        let z = back - simd_dot(back, y) * y
        guard simd_length(z) > 1e-6 else { return nil }
        let zn = simd_normalize(z)
        return simd_quatf(simd_float3x3(simd_cross(y, zn), y, zn))
    }

    /// Bend angle in degrees between the first and last segment of each finger (0 = straight).
    var curls: [Float] {
        let chains: [[HandSkeleton.JointName]] = [
            [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
            [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
        ]
        return chains.map { chain in
            // Accumulate the bend at every inner joint of the chain.
            var total: Float = 0
            for k in 1..<(chain.count - 1) {
                guard let a = self[chain[k - 1]], let b = self[chain[k]], let c = self[chain[k + 1]] else { return 0 }
                let d1 = simd_normalize(b - a), d2 = simd_normalize(c - b)
                total += acos(simd_clamp(simd_dot(d1, d2), -1, 1)) * 180 / .pi
            }
            return total
        }
    }
}

struct GestureDetector {
    private(set) var isPinching = false

    /// Pinch uses hysteresis so it doesn't flicker at the threshold.
    mutating func classify(_ pose: HandPose) -> Gesture {
        if let d = pose.pinchDistance {
            isPinching = isPinching ? d < 0.035 : d < 0.018
        } else {
            isPinching = false
        }

        let curls = pose.curls
        let extended = curls.map { $0 < 60 }
        let curled = curls.map { $0 > 110 }
        let thumbOut: Bool = {
            guard let tip = pose[.thumbTip], let base = pose[.indexFingerKnuckle] else { return false }
            return simd_distance(tip, base) > 0.06
        }()

        if isPinching { return .pinch }

        let (i, m, r, l) = (extended[1], extended[2], extended[3], extended[4])
        let (ci, cm, cr, cl) = (curled[1], curled[2], curled[3], curled[4])

        if i && m && r && l && thumbOut { return .openPalm }
        if ci && cm && cr && cl {
            if thumbOut, let tip = pose[.thumbTip], let wrist = pose[.wrist], tip.y - wrist.y > 0.06 {
                return .thumbsUp
            }
            return .fist
        }
        if i && m && cr && cl { return .peace }
        if i && l && cm && cr { return .rock }
        if i && cm && cr && cl { return thumbOut ? .gun : .point }
        return .none
    }
}
