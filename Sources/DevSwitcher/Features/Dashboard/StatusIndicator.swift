import DevSwitcherCore
import SwiftUI

/// 状態を表す点。色だけで伝えないよう、必ずテキストラベルと併せて使う。
struct StatusDot: View {
    let phase: ServicePhase
    var isEnabled: Bool = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(phase.label)
    }

    private var color: Color {
        switch phase {
        case .stopped: .secondary
        case .starting, .stopping: .accentColor
        case .running: .green
        case .residual: .orange
        case .failed: .red
        }
    }
}

struct StatusLabel: View {
    let phase: ServicePhase

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(phase: phase)
            Text(phase.label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// プロジェクトの識別チップ。状態の色と混ざらないよう角丸四角で描く。
struct ProjectChip: View {
    let project: ProjectDefinition

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(project.color.swiftUIColor)
            .frame(width: 16, height: 16)
            .overlay {
                Text(project.initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

extension ProjectColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        }
    }
}
