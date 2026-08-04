import Darwin
import Foundation

/// UIが復旧手段を選べるよう、起動・停止の失敗理由を型で保持する。
public enum RuntimeError: Error, Sendable, CustomStringConvertible {
    case operationInProgress
    case otherProjectRunning(running: String, requested: String)
    case alreadyRunning(service: String)
    case notRunning(service: String)
    case identityMismatch(service: String, pid: pid_t)
    case identityUnavailable(service: String, pid: pid_t, residualProcessGroupID: pid_t?)
    case invalidHandoff(service: String, reason: String)
    case ownershipLost(service: String)
    case residualProcessesRemain(service: String, processGroupID: pid_t)
    case projectDirectoryMissing(URL)
    case stopCommandUnsupported(service: String)

    public var description: String {
        switch self {
        case .operationInProgress:
            "ほかの起動・停止処理が実行中です。完了してから操作してください。"
        case let .otherProjectRunning(running, requested):
            "プロジェクト「\(running)」が稼働中です。同時に稼働できるプロジェクトは1つだけのため、「\(requested)」は起動できません。先に「\(running)」を停止してください。"
        case let .alreadyRunning(service):
            "サービス「\(service)」は既に起動しています。"
        case let .notRunning(service):
            "サービス「\(service)」は起動していません。"
        case let .identityMismatch(service, pid):
            "PID \(pid) は起動時に記録したプロセスと一致しません。別プロセスを終了させないため、サービス「\(service)」の停止を中止しました。"
        case let .identityUnavailable(service, pid, residualProcessGroupID):
            if let residualProcessGroupID {
                "サービス「\(service)」の起動直後にプロセス情報（PID \(pid)）を取得できませんでした。安全に管理できないため中止しましたが、プロセスグループ \(residualProcessGroupID) にプロセスが残っています。"
            } else {
                "サービス「\(service)」の起動直後にプロセス情報（PID \(pid)）を取得できませんでした。安全に管理できないため中止しました。"
            }
        case let .invalidHandoff(service, reason):
            "サービス「\(service)」の引き継ぎ候補を登録直前に再検証できませんでした。"
                + "別プロセスを管理対象にしないため、引き継ぎを中止しました。\n\(reason)"
        case let .ownershipLost(service):
            "サービス「\(service)」のプロセスグループ所有権を失いました。"
                + "再利用された可能性のあるPGIDへ送らないため、停止結果を判定できません。"
        case let .residualProcessesRemain(service, processGroupID):
            "サービス「\(service)」の前回のプロセスが残っています（プロセスグループ \(processGroupID)）。残りを停止してから起動してください。"
        case let .projectDirectoryMissing(url):
            "プロジェクトのディレクトリが存在しません（\(url.path)）。"
        case let .stopCommandUnsupported(service):
            "サービス「\(service)」には終了コマンドが設定されています。終了コマンドで管理するサービス（managed command）の実行は Milestone 3 で対応します。プロセスグループの停止で代用すると停止できたか確認できないため、起動を中止しました。"
        }
    }
}
