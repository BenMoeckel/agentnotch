import SwiftUI

/// Shared by the compact notch and the expanded agent list.
struct AgentIcon: View {
    let kind: String
    let color: Color
    let size: CGFloat

    static func assetName(for kind: String) -> String {
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = [
            "claude-code": "claude", "claude code": "claude",
            "codex-cli": "codex", "gemini-cli": "gemini",
            "github-copilot": "copilot", "github copilot": "copilot",
            "qoder": "qodercli", "kilo-code": "kilo",
            "kimi-cli": "kimi", "qwen-code": "qwen"
        ]
        return "agent-\(aliases[normalized] ?? normalized)"
    }

    var body: some View {
        Group {
            if let image = NSImage(named: Self.assetName(for: kind)) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityLabel(kind.isEmpty ? "Unknown agent" : kind)
    }
}
