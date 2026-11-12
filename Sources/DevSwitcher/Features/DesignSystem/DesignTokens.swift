import SwiftUI

/// `docs/SPEC.md` 16.3 のデザイントークン。
///
/// サイズ・余白・角丸の生数値をここだけに置く。ビュー側で数値を直接書くと、
/// 同じ役割の文字が画面ごとに違うサイズになり、見た目が揃わなくなる。
enum Typography {
    /// 13.5 / 600。ツールバーのプロジェクト名、シートの見出し。
    static let title = Font.system(size: 13.5, weight: .semibold)
    /// 12.5 / 600。詳細の見出し、サービス名。
    static let heading = Font.system(size: 12.5, weight: .semibold)
    /// 12.5 / 400。サイドバーの行、本文。
    static let row = Font.system(size: 12.5)
    /// 11.5 / 400。状態・補助・注記。色は呼び出し側が付ける。
    static let support = Font.system(size: 11.5)
    /// 10.5 / 400。種別など、補助よりさらに弱い注記。
    static let caption = Font.system(size: 10.5)
    /// 11 / SF Mono。パス・ポート・PID。
    static let mono = Font.system(size: 11, design: .monospaced)
    /// 10.5 / SF Mono。ログ、狭い場所に置く数値。
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    /// 9.5 / 700。セクション見出しと値ラベル。字送りは `SectionLabel` が付ける。
    static let sectionLabel = Font.system(size: 9.5, weight: .bold)
    /// セクション見出しの字送り。方針は docs/SPEC.md 16.3、数値はここが正。
    static let sectionLabelKerning: CGFloat = 0.7
}

/// 4pt グリッド（docs/SPEC.md 16.3）。グリッド外の値を新しく足さない。
enum Spacing {
    /// 記号と値の行間。`mock.html` が密な縦積みに使う 2〜5px に対応する、
    /// グリッドの例外。ラベルと値のように「1つの塊」に見せたい箇所だけで使う。
    static let hairline: CGFloat = 2
    static let xs: CGFloat = 4
    /// 記号と語の間（状態の点とラベルなど）。`mock.html:352,401` の `gap:6px`。
    /// 4pt では点と語がくっつき、8pt では別の要素に見える。意図したグリッドの例外。
    static let tight: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    /// サイドバーのサービス行のインデント。
    static let indent: CGFloat = 24
}

/// 角丸 10 / 7 / 6（docs/SPEC.md 16.3）。
enum Radius {
    /// カード・ゲート。
    static let card: CGFloat = 7
    /// 行・ボタン・入力欄。
    static let control: CGFloat = 6
    /// プロジェクトチップ。状態の丸と混ざらないよう角丸四角で描く。
    static let chip: CGFloat = 4
}

/// 寸法。役割ごとに名前を付け、同じ数値でも意味が違うものは分ける。
enum Metrics {
    /// ウィンドウ既定。サイドバー＋ログが同時に成立する最小（docs/SPEC.md 16.1）。
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 544
    static let windowMinWidth: CGFloat = 720
    static let windowMinHeight: CGFloat = 460

    /// 複数の起動時警告が出ても、詳細ペインの操作領域を残す。
    static let bannerAreaMaxHeight: CGFloat = 200

    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 214
    static let sidebarMaxWidth: CGFloat = 300
    static let projectRowHeight: CGFloat = 27
    static let serviceRowHeight: CGFloat = 25

    /// 長い環境名が操作を押し出さないよう、ツールバー内では末尾を省略する。
    static let toolbarProjectNameMaxWidth: CGFloat = 200
    /// スピナーと4文字の状態ラベルを確保し、状態遷移で幅を変えない。
    static let toolbarStatusWidth: CGFloat = 76

    /// 通常のシート幅。
    static let sheetWidth: CGFloat = 452
    /// プロジェクト追加・編集シート。
    static let editorSheetWidth: CGFloat = 600
    static let editorSheetHeight: CGFloat = 620
    /// 編集シートの入力欄のラベル列。ここを固定しないとカードの内と外で右端がずれる。
    static let formLabelWidth: CGFloat = 124
    /// 引き継ぎ候補の一覧。件数が多くてもシートがウィンドウを超えないようにする上限。
    static let handoffListMaxHeight: CGFloat = 260
    /// 保存できない理由の一覧が伸び続けないようにする上限。
    static let formErrorMaxHeight: CGFloat = 100
    /// 引数の入力欄。1行1引数で3行程度を見せる。
    static let argumentsEditorHeight: CGFloat = 52

    /// 定義からの追加候補。名前とコマンドの列を揃える。
    static let discoveryNameWidth: CGFloat = 120
    static let discoveryDetailsWidth: CGFloat = 300

    /// チェックボックスの幅ぶんのインデント。補助情報をラベルの真下へ揃える。
    static let checkboxIndent: CGFloat = 20
    /// 状態を表す点。
    static let statusDot: CGFloat = 7
    /// プロジェクトチップ。
    static let chip: CGFloat = 16
    /// チップの中の頭文字。16pt の中に収めるための値で、本文の階調ではない。
    static let chipInitial: CGFloat = 9
    /// サイドバーの開閉アイコン。
    static let disclosureIcon: CGFloat = 9
    /// ステージ行のアイコン。
    static let stageIcon: CGFloat = 11
    /// ログ本文（SF Mono）。方針は docs/SPEC.md 16.3、数値はここが正。`NSFont` へ渡すので数値で持つ。
    static let logFontSize: CGFloat = 10.5
    /// 空状態のアイコン。
    static let emptyStateIcon: CGFloat = 34
    /// 空状態の説明文が1行に伸び切らないようにする幅。
    static let emptyStateTextWidth: CGFloat = 380

    static let portLabelFieldWidth: CGFloat = 84
    static let portNumberFieldWidth: CGFloat = 66
}
