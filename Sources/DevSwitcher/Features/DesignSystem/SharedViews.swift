import SwiftUI

/// セクション見出し。方針は `docs/SPEC.md` 16.3、数値は DesignTokens.swift が正。
struct SectionLabel: View {
    let text: String
    var tint: HierarchicalShapeStyle

    init(_ text: String, tint: HierarchicalShapeStyle = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(Typography.sectionLabel)
            .kerning(Typography.sectionLabelKerning)
            .foregroundStyle(tint)
    }
}

/// ラベル付きの値。値は選択・コピーできる。
///
/// 長い値でウィンドウを押し広げないよう、折り返しの上限を決めて全文は `help` に逃がす。
struct LabeledValue: View {
    let label: String
    let value: String
    var lineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            SectionLabel(label, tint: .tertiary)
            Text(value)
                .font(Typography.mono)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
    }
}

/// 状態や理由を伝える1行〜数行の注記。
///
/// 起動できない理由や失敗の内容は貼り付けて調べられる必要があるので、常に選択可能にする。
/// 幅で切らず折り返すのも同じ理由で、原因の末尾が消えると調べようがない。
struct NoteText: View {
    let text: String
    var tint: Color
    /// チェックボックスなどの左端に合わせたいときのインデント。
    var indent: CGFloat = 0

    init(_ text: String, tint: Color, indent: CGFloat = 0) {
        self.text = text
        self.tint = tint
        self.indent = indent
    }

    var body: some View {
        Text(text)
            .font(Typography.support)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.leading, indent)
    }
}

/// 横に並べ、入り切らなければ折り返す行。
///
/// 実測ポートのように長さが実行時に決まる値を固定の `HStack` へ入れると、
/// 詳細ペインが狭いときに黙って切れる。切らずに折り返す。
struct FlowRow: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = Spacing.l, verticalSpacing: CGFloat = Spacing.m) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                // 測ったときと同じ大きさで置く。別の提案で置くと、折り返しの判断と
                // 実際の描画がずれて、行末の要素だけが切れる。
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var current = Line()
        for index in subviews.indices {
            // 容器の幅を提案して測る。`.unspecified` で測ると折り返さない前提の幅が
            // 返り、長い値の1項目だけで行が容器を超える。折り返しても直らない。
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let item = Item(index: index, size: size)
            let extended = current.items.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width
            if !current.items.isEmpty, extended > maxWidth {
                result.append(current)
                current = Line(items: [item], width: size.width, height: size.height)
            } else {
                current.items.append(item)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { result.append(current) }
        return result
    }
}

/// 編集シートの入力行。
///
/// `LabeledContent` はコンテナごとにラベル列の幅を計算するため、シート直下の欄と
/// サービスカードの中の欄でラベルの右端が揃わない。幅を固定して1つの列に見せる。
struct FormRow<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let content: () -> Content

    init(_ label: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.note = note
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(label)
                .font(Typography.support)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.formLabelWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                content()
                if let note {
                    Text(note)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// カード背景の種類。値は見た目の濃さの違いだけを表す。
enum CardBackgroundStyle {
    /// 独立したカード・囲み。
    case standard
    /// 標準カードを内側に並べる外枠。内側のカードより薄くして入れ子を区別する。
    case group

    fileprivate var opacity: Double {
        switch self {
        case .standard: 0.35
        case .group: 0.2
        }
    }
}

extension View {
    /// カードの背景。個別に `.quaternary.opacity(...)` を書かず、これを使う。
    func cardBackground(_ style: CardBackgroundStyle = .standard) -> some View {
        background(
            .quaternary.opacity(style.opacity),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }
}
