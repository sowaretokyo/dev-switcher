import DevSwitcherCore
import Foundation

/// 管理対象スタックの種類ごとの表示文言と詳細行（docs/ARCHITECTURE.md 8、10）。
///
/// 種類名と ID の呼び名は`ManagedStackType`から組み立てる。種類ごとに違う注記だけをここで持つ。
/// I/O はしない。View の body から呼んでもファイルを読まない。
struct ManagedStackTypePresentation: Equatable {
    let type: ManagedStackType

    init(_ type: ManagedStackType) {
        self.type = type
    }

    /// 詳細画面に並べる、設定から導出した行。
    struct DetailRow: Equatable {
        let label: String
        let value: String
        let lineLimit: Int
    }

    /// ID の欄ラベル。`identityLabel`はコード書式のバッククォート付きなので、画面では外す。
    var identityFieldLabel: String {
        type.identityLabel.replacingOccurrences(of: "`", with: "")
    }

    /// 起動成功の判断根拠。
    var startupObservationDescription: String {
        switch type {
        case .supabase:
            "Dockerの実測でDBコンテナがhealthyになり、対象workdirの `supabase status` も成功すること"
        }
    }

    /// 実測ポートを取得できないとき、取得不能ではなく管理主体を示す。
    var portsManagedByText: String {
        switch type {
        case .supabase: "Supabase CLI で管理"
        }
    }

    /// 外部で起動されたスタックの注記。
    var externalStackNote: String {
        "外部で起動された\(type.displayName)です。開発環境の起動時に引き継ぎを確認します。"
    }

    /// 引き継ぎで再適用しないものの注記。
    var adoptionLimitationNote: String? {
        switch type {
        case .supabase: "現在のスタックへ起動コマンドの `--exclude` などは再適用しません。"
        }
    }

    /// 停止の範囲を示す注記。
    var stopScopeNote: String {
        switch type {
        case .supabase:
            "停止は \(type.identityLabel) を1件ずつ指定して実行します（`--all` と `--no-backup` は使いません）。"
        }
    }

    /// 詳細画面の「状態確認」「設定ファイル」の行。設定が導出できなければ行を出さない。
    static func detailRows(for service: ServiceDefinition) -> [DetailRow] {
        guard let definition = service.managedStackDefinition,
              let derived = definition.configuration.derived(
                  workingDirectory: service.start.workingDirectory
              ) else {
            return []
        }
        switch derived {
        case let .supabase(configuration):
            return [
                DetailRow(
                    label: "状態確認",
                    value: configuration.statusCommand.displayCommandLine,
                    lineLimit: 3
                ),
                DetailRow(label: "設定ファイル", value: configuration.configFileURL.path, lineLimit: 2),
            ]
        }
    }
}
