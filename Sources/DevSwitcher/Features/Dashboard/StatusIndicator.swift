import DevSwitcherCore
import SwiftUI

/// 状態を表す点。色だけで伝えないよう、必ずテキストラベルと併せて使う。
/// 対象外だけは色を持たず、中空の丸で描く（DESIGN.md 4章）。
struct StatusDot: View {
    let phase: ServicePhase

    var body: some View {
        Group {
            if phase == .excluded {
                Circle()
                    .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(phase.label)
    }

    private var color: Color {
        switch phase {
        case .excluded: .clear
        case .stopped: .secondary
        // listen しただけの `.running` は遷移中の色。緑は `.healthy` だけ。
        case .starting, .running, .stopping: .accentColor
        case .healthy: .green
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

struct ProjectStatusDot: View {
    let phase: ProjectPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(phase.label)
    }

    private var color: Color {
        switch phase {
        case .stopped: .secondary
        case .starting, .stopping, .switching: .accentColor
        case .running: .green
        case .degraded, .residual: .orange
        case .failed: .red
        }
    }
}

struct ProjectStatusLabel: View {
    let phase: ProjectPhase

    var body: some View {
        HStack(spacing: 6) {
            ProjectStatusDot(phase: phase)
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
