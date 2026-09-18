// TEMPORARY: dumps the loaded cabinet hierarchy to the console. Remove after diagnosis.
import RealityKit
import SwiftUI

enum DebugDump {
    static var lines: [String] = []
    static func print(_ s: String) { lines.append(s); Swift.print(s) }
    static func run() async {
        guard let model = try? await Entity(named: "AEDCabinet") else { print("DUMP: load failed"); return }
        func fmt(_ v: SIMD3<Float>) -> String { String(format: "[%.3f, %.3f, %.3f]", v.x, v.y, v.z) }
        func walk(_ e: Entity, _ d: Int) {
            let q = e.transform.rotation
            print("DUMP: \(String(repeating: "  ", count: d))\(e.name.isEmpty ? "<unnamed>" : e.name) [\(type(of: e))] pos \(fmt(e.position)) rot \(String(format: "%.1f", q.angle * 180 / .pi))° axis \(fmt(q.axis)) anims \(e.availableAnimations.count)")
            for c in e.children { walk(c, d + 1) }
        }
        walk(model, 0)
        if let door = model.findEntity(named: "AED_Door"), let parent = door.parent {
            print("DUMP: door parent = \(parent.name)")
            print("DUMP: world up in parent = \(fmt(parent.convert(direction: [0, 1, 0], from: nil)))")
            print("DUMP: door local bounds = \(door.visualBounds(relativeTo: door))")
            print("DUMP: door bounds in parent = \(door.visualBounds(relativeTo: parent))")
            print("DUMP: cabinet bounds in parent = \(model.findEntity(named: "AED_Cabinet_Mesh")!.visualBounds(relativeTo: parent))")
            print("DUMP: model bounds = \(model.visualBounds(relativeTo: model))")
        }
        print("DUMP: END")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dump.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
