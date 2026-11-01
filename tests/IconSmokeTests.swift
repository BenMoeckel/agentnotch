import AppKit
import SwiftUI

@main
struct IconSmokeTests {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
        let sets = try FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "imageset" }
        precondition(sets.count == 24)
        for set in sets {
            let name = set.deletingPathExtension().lastPathComponent
            guard let image = bundle.image(forResource: name),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fatalError("Cannot render \(name)")
            }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            var visible = false
            var expectedColorFound = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let pixel = bitmap.colorAt(x: x, y: y),
                       pixel.alphaComponent > 0.95 {
                        let expected: [CGFloat]? = name == "agent-pi" ? [233, 233, 240]
                            : name == "agent-claude" ? [217, 119, 87] : nil
                        if let expected,
                           abs(pixel.redComponent * 255 - expected[0]) < 3,
                           abs(pixel.greenComponent * 255 - expected[1]) < 3,
                           abs(pixel.blueComponent * 255 - expected[2]) < 3 {
                            expectedColorFound = true
                        }
                    }
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        visible = true
                    }
                }
            }
            precondition(visible, "Empty icon: \(name)")
            if name == "agent-pi" || name == "agent-claude" {
                precondition(expectedColorFound, "Incorrect original color: \(name)")
            }
        }
        precondition(AgentIcon.assetName(for: " Claude-Code \n") == "agent-claude")
        precondition(AgentIcon.assetName(for: "CODEX") == "agent-codex")
        precondition(AgentIcon.assetName(for: "unknown") == "agent-unknown")
        let decoder = JSONDecoder()
        let harness = try decoder.decode(AgentInfo.self, from: Data(#"{"pane_id":"1","kind":" ","harness":"codex","state":"working"}"#.utf8))
        precondition(harness.kind == "codex")
        let kind = try decoder.decode(AgentInfo.self, from: Data(#"{"pane_id":"2","kind":"claude","harness":"codex"}"#.utf8))
        precondition(kind.kind == "claude")
        // Actual agent.list shape: no kind or harness fields.
        for agentName in ["claude", "pi"] {
            let data = try JSONSerialization.data(withJSONObject: ["pane_id": "3", "agent": agentName])
            let agent = try decoder.decode(AgentInfo.self, from: data)
            precondition(agent.kind == agentName)
            precondition(bundle.image(forResource: AgentIcon.assetName(for: agent.kind)) != nil)
        }
        let blankTypes = try decoder.decode(AgentInfo.self, from: Data(#"{"pane_id":"4","agent":"claude","kind":" ","harness":" "}"#.utf8))
        precondition(blankTypes.kind == "claude")
        let missing = try decoder.decode(AgentInfo.self, from: Data(#"{"pane_id":"claude"}"#.utf8))
        precondition(missing.kind.isEmpty, "Pane IDs must not be interpreted as agent types")
        print("PASS: all 24 assets render; aliases, type precedence and agent-only payloads resolve correctly.")
    }
}
