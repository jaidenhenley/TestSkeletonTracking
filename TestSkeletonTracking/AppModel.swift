//
//  AppModel.swift
//  TestSkeletonTracking
//
//  Created by Jaiden Henley on 9/17/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // MARK: Visualization toggles
    var showJoints = true
    var showBones = true
    var showJointAxes = false
    var showFingertipTrails = true
    var showLabels = true
    var hideRealHands = false
    var physicsEnabled = true
    var usePredictedAnchors = true
    var grabStyle = GrabStyle.palm
    var spawnOnEmptyPinch = true
    var uniformStretch = false

    // MARK: Live tracking data (throttled, written by HandSkeletonTracker)
    var status = "Idle"
    var left = HandStats()
    var right = HandStats()
    var handDistance: Float?
    var claps = 0
    var spawnedObjects = 0
    var sceneMeshCount = 0
    var updateRate: Double = 0
    var lastPalmEvent = "—"

    /// Bumped to ask the tracker to remove all spawned objects.
    var clearRequest = 0
    /// Bumped to drop a batch of objects onto the floor.
    var dropRequest = 0

    // MARK: AED cabinet simulation
    let aedSpaceID = "AEDSpace"
    var aedStatus = "Idle"
    /// When on, the cabinet snaps to the nearest detected wall instead of floating in front of you.
    var aedAttachToWall = false
    /// Bumped to re-mount the cabinet on the wall you're currently looking at.
    var aedPlaceRequest = 0
    /// Extra space between the detected wall and the cabinet's back, in metres. ARKit's wall
    /// estimate often sits a little behind the real surface, so a small gap keeps it from sinking in.
    var aedWallGap: Float = 0.01
    var aedCabinetDepth: Float = 0
    /// Turns the cabinet 180° for models exported facing the other way.
    var aedFlipCabinet = false
}

enum GrabStyle: String, CaseIterable, Identifiable {
    case palm = "Palm"
    case pinch = "Pinch"
    case both = "Both"
    var id: Self { self }
}

struct HandStats: Equatable {
    var isTracked = false
    var trackedJoints = 0
    var gesture = Gesture.none
    var pinchDistance: Float = 0
    /// 1 = palm straight up, -1 = straight down.
    var palmFacingUp: Float = 0
    var isHoldingInPalm = false
    /// Curl in degrees for thumb, index, middle, ring, little.
    var curls: [Float] = Array(repeating: 0, count: 5)
}
