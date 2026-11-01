import SwiftUI

struct AgentRowView: View {
    let agent: AgentInfo
    var completed = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(kind: agent.kind, color: agent.state.color, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title ?? agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Image(systemName: completed ? "checkmark.circle.fill"
                          : agent.state == .blocked ? "exclamationmark.circle.fill" : "circle.fill")
                        .font(.system(size: 9))
                    Text(completed ? "New result" : agent.state.label)
                        .font(.system(size: 10))
                }
                .foregroundStyle(completed ? Color.green : agent.state.color)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, completed ? 44 : 16)
        .help("\(agent.title ?? agent.name) · \(agent.id) · \(completed ? "New result" : agent.state.label)")
    }
}
