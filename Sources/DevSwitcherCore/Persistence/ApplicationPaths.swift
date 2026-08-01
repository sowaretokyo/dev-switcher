import Foundation

/// 保存先を作れない場合は代替場所へ黙って切り替えず、起動元へエラーを返す。
public enum ApplicationPaths {
    public static let directoryName = "DevSwitcher"

    public static func applicationSupportDirectory() throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw ProjectStoreError.applicationSupportUnavailable(reason: error.localizedDescription)
        }
    }

    public static func logDirectory() throws -> URL {
        let directory = try applicationSupportDirectory()
            .appendingPathComponent("logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.applicationSupportUnavailable(reason: error.localizedDescription)
        }
        return directory
    }
}
