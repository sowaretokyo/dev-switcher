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
        case .dockerCompose: L10n.text("Compose の全コンテナが正常稼働していること（HTTP 応答は確認しません）")
        case .supabase:
            L10n.text("Dockerの実測でDBコンテナがhealthyになり、対象workdirの `supabase status` も成功すること")
        }
    }

    /// 実測ポートを取得できないとき、取得不能ではなく管理主体を示す。
    var portsManagedByText: String {
        switch type {
        case .supabase: L10n.text("Supabase CLI で管理")
        case .dockerCompose: L10n.text("Docker Compose で管理")
        }
    }

    /// 外部で起動されたスタックの注記。
    var externalStackNote: String {
        L10n.text("外部で起動された\(type.displayName)です。開発環境の起動時に引き継ぎを確認します。")
    }

    /// 引き継ぎで再適用しないものの注記。
    var adoptionLimitationNote: String? {
        switch type {
        case .dockerCompose: L10n.text("現在のスタックへ起動時の追加引数や profile の設定を再適用しません。引き継いだ後の停止は、同じプロジェクト名の全 profile が対象です。")
        case .supabase: L10n.text("現在のスタックへ起動コマンドの `--exclude` などは再適用しません。")
        }
    }

    /// 停止の範囲を示す注記。
    var stopScopeNote: String {
        switch type {
        case .dockerCompose: L10n.text("同じプロジェクト名の全 profile を停止します。設定した profile 以外も対象です。コンテナやボリュームは削除しません。")
        case .supabase:
            L10n.text("停止は \(type.identityLabel) を1件ずつ指定して実行します（`--all` と `--no-backup` は使いません）。")
        }
    }

    /// 設定を読み取れない場合も、その理由を詳細に表示する。
    static func detailRows(for service: LaunchUnit) -> [DetailRow] {
        guard let definition = service.managedStackDefinition else { return [] }
        switch definition.configuration {
        case let .dockerCompose(configuration):
            return [
                DetailRow(label: L10n.text("プロジェクト名の指定"), value: configuration.projectName ?? L10n.text("Compose ファイルの name: またはディレクトリ名から解決"), lineLimit: 2),
                DetailRow(label: L10n.text("Compose ファイル"), value: configuration.files?.joined(separator: "\n") ?? L10n.text("作業ディレクトリ直下の既定ファイル"), lineLimit: 6),
                DetailRow(label: L10n.text("起動 profile"), value: configuration.profiles?.joined(separator: ", ") ?? L10n.text("未指定"), lineLimit: 3),
                DetailRow(label: L10n.text("停止範囲"), value: L10n.text("同じプロジェクト名の全 profile（設定外の profile を含む）"), lineLimit: 3),
                DetailRow(label: L10n.text("起動追加引数"), value: configuration.upArguments.isEmpty ? L10n.text("なし") : configuration.upArguments.joined(separator: " "), lineLimit: 3),
            ]
        case let .supabase(configuration):
            guard let derived = configuration.derived(workingDirectory: service.workingDirectory) else {
                return [DetailRow(label: L10n.text("設定エラー"), value: configuration.structuralIssues(workingDirectory: service.workingDirectory).map(\.failureReason).joined(separator: "\n"), lineLimit: 6)]
            }
            return [DetailRow(label: L10n.text("状態確認"), value: derived.statusCommand.displayCommandLine, lineLimit: 3),
                DetailRow(label: L10n.text("設定ファイル"), value: derived.configFileURL.path, lineLimit: 2)]
        }
    }
}
