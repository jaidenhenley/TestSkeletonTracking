//
//  AEDInsert.swift
//  TestSkeletonTracking
//
//  Loads the AED unit (LPAED.usdz) and seats it inside the cabinet body: standing upright on
//  the cabinet floor, pushed back against the rear wall, screen facing the door. It is scaled
//  down only if it would not fit through the door opening.
//

import RealityKit

enum AEDInsert {
    static let resourceName = "LPAED"

    /// The unit's own axes, as RealityKit loads the file. LPAED.usdz is a Blender Z-up export:
    /// the screen sits on the -Y face and the top of the unit is +Z. Change these if you swap the model.
    static let modelFront: SIMD3<Float> = [0, -1, 0]
    static let modelUp: SIMD3<Float> = [0, 0, 1]

    /// Wall thickness assumed for the cabinet's back panel, and breathing room around the unit.
    private static let backWall: Float = 0.015
    private static let margin: Float = 0.01

    /// Adds the AED under `model` (the loaded cabinet) as a sibling of the door, so it stays put
    /// when the door swings. Call with the door in its closed pose. Returns the `AED_Unit` entity:
    /// origin at the unit's centre, X across, Y up, Z toward the screen, with the model inside it.
    @MainActor
    @discardableResult
    static func place(in model: Entity, door: Entity) async throws -> Entity {
        seat(try await Entity(named: resourceName), in: model, door: door)
    }

    /// Orients, scales and positions an already-loaded AED inside the cabinet body. Returns the holder.
    @MainActor
    @discardableResult
    static func seat(_ aed: Entity, in model: Entity, door: Entity) -> Entity {
        let holder = Entity()
        holder.name = "AED_Unit"
        holder.addChild(aed)
        model.addChild(holder)

        aed.orientation = uprightRotation()

        // The door opening tells us the usable width/height; the body depth minus the back wall
        // and door thickness tells us how deep the shelf is. (Cabinet front is +Z in model space.)
        let body = model.findEntity(named: "AED_Cabinet_Mesh")?.visualBounds(relativeTo: model)
            ?? model.visualBounds(relativeTo: model)
        let opening = door.visualBounds(relativeTo: model)
        let roomW = opening.extents.x - 2 * margin
        let roomH = opening.extents.y - 2 * margin
        let roomD = body.extents.z - backWall - opening.extents.z - margin

        var bounds = aed.visualBounds(relativeTo: holder)
        let fit = min(1, roomW / bounds.extents.x, roomH / bounds.extents.y, roomD / bounds.extents.z)
        aed.scale = SIMD3(repeating: fit)
        bounds = aed.visualBounds(relativeTo: holder)

        // Holder origin sits at the unit's centre; then drop it onto the floor, centred on the
        // opening, with its back just off the rear wall.
        aed.position -= bounds.center
        holder.position = [
            opening.center.x,
            opening.min.y + margin + bounds.extents.y / 2,
            body.min.z + backWall + bounds.extents.z / 2,
        ]
        return holder
    }

    /// Rotation taking the unit's own front/up axes onto the cabinet's (+Z front, +Y up).
    private static func uprightRotation() -> simd_quatf {
        let front = normalize(modelFront), up = normalize(modelUp)
        let fromModel = simd_float3x3(cross(up, front), up, front)
        let toCabinet = simd_float3x3([1, 0, 0], [0, 1, 0], [0, 0, 1])
        return simd_quatf(toCabinet * fromModel.transpose)
    }
}
