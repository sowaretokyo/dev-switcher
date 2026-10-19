import Foundation
import Testing
@testable import DevSwitcherCore

/// 手掛かりファイル schema v6 を、現行形式の文字列リテラルから読めることを固定する。
///
/// 後続のリファクタで内部の型や名前が変わっても、保存済みファイルとの互換が崩れないかを見る。
/// 読んだ値の取り出しは `extract` だけを通すので、型を差し替えるときはこの関数だけを書き換える。
@Suite("手掛かりファイル v6 の互換")
struct RuntimeHintV6CompatibilityTests {
    /// 読み込んだ管理対象の手掛かりから、互換の判断に使う値だけを取り出したもの。
    private struct ExtractedManagedHint: Equatable {
        let environmentID: UUID
        let stackID: UUID
        let name: String
        let kind: String
        let identifier: String
        let relationship: String
        let executable: String
        let startArguments: [String]
        let startWorkingDirectory: String
        let configDirectory: String
    }

    private func extract(_ hint: ManagedStackHint) throws -> ExtractedManagedHint {
        let identity = try #require(hint.identity)
        let relationship = try #require(hint.relationship)
        let fingerprint = switch try #require(hint.fingerprint) {
        case let .supabase(supabaseFingerprint): supabaseFingerprint
        }
        return ExtractedManagedHint(
            environmentID: hint.projectID,
            stackID: hint.stackID,
            name: hint.stackName,
            kind: hint.type.rawValue,
            identifier: identity.value,
            relationship: relationship.rawValue,
            executable: fingerprint.executable,
            startArguments: fingerprint.startArguments,
            startWorkingDirectory: fingerprint.startWorkingDirectory.path,
            configDirectory: fingerprint.configDirectory.path
        )
    }

    private let launchedEnvironmentID = "11111111-1111-4111-8111-111111111111"
    private let launchedStackID = "22222222-2222-4222-8222-222222222222"
    private let adoptedEnvironmentID = "33333333-3333-4333-8333-333333333333"
    private let adoptedStackID = "44444444-4444-4444-8444-444444444444"
    private let workerEnvironmentID = "55555555-5555-4555-8555-555555555555"
    private let workerServiceID = "66666666-6666-4666-8666-666666666666"

    private var v6Literal: String {
        """
        {
          "schemaVersion": 6,
          "hints": [
            {
              "projectID": "\(workerEnvironmentID)",
              "serviceID": "\(workerServiceID)",
              "serviceName": "Worker",
              "processGroupID": 4242,
              "leader": { "pid": 4242, "startAbstime": 1000 },
              "groupEvidence": {
                "bootSessionID": "BOOT-A",
                "anchors": [ { "pid": 4242, "startAbstime": 1000 } ]
              },
              "executablePath": "/bin/sleep",
              "workingDirectory": "file:///tmp/dev-switcher-compat/worker/",
              "observedPorts": { "unavailable": {} }
            }
          ],
          "legacyHints": [],
          "managedHints": [
            {
              "projectID": "\(launchedEnvironmentID)",
              "serviceID": "\(launchedStackID)",
              "serviceName": "Supabase",
              "supabaseProjectID": "bell",
              "configDirectory": "file:///tmp/dev-switcher-compat/bell/",
              "fingerprint": {
                "executable": "supabase",
                "startArguments": ["start"],
                "startWorkingDirectory": "file:///tmp/dev-switcher-compat/bell/",
                "configDirectory": "file:///tmp/dev-switcher-compat/bell/"
              },
              "relationship": "launched"
            },
            {
              "projectID": "\(adoptedEnvironmentID)",
              "serviceID": "\(adoptedStackID)",
              "serviceName": "Penta DB",
              "supabaseProjectID": "penta-db",
              "configDirectory": "file:///tmp/dev-switcher-compat/penta/backend/",
              "fingerprint": {
                "executable": "pnpm",
                "startArguments": ["exec", "supabase", "start", "--workdir", "backend"],
                "startWorkingDirectory": "file:///tmp/dev-switcher-compat/penta/",
                "configDirectory": "file:///tmp/dev-switcher-compat/penta/backend/"
              },
              "relationship": "adopted"
            }
          ]
        }
        """
    }

    private func writeLiteral(to directory: URL) throws -> RuntimeHintStore {
        let store = RuntimeHintStore(directory: directory)
        try Data(v6Literal.utf8).write(to: store.fileURL)
        return store
    }

    @Test("v6 のリテラルから、launched と adopted の管理対象と通常hintを読める")
    func readsV6Literal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try writeLiteral(to: directory)

        let loaded = try store.load()

        #expect(loaded.hints.count == 1)
        #expect(loaded.hints.first?.serviceName == "Worker")
        #expect(loaded.hints.first?.serviceID.uuidString == workerServiceID.uppercased())
        #expect(loaded.hints.first?.processGroupID == 4242)
        #expect(loaded.hints.first?.observedPorts == .unavailable)
        #expect(loaded.legacy.isEmpty)

        let extracted = try loaded.managed.map(extract)
        #expect(
            extracted == [
                ExtractedManagedHint(
                    environmentID: try #require(UUID(uuidString: launchedEnvironmentID)),
                    stackID: try #require(UUID(uuidString: launchedStackID)),
                    name: "Supabase",
                    kind: "supabase",
                    identifier: "bell",
                    relationship: "launched",
                    executable: "supabase",
                    startArguments: ["start"],
                    startWorkingDirectory: "/tmp/dev-switcher-compat/bell",
                    configDirectory: "/tmp/dev-switcher-compat/bell"
                ),
                ExtractedManagedHint(
                    environmentID: try #require(UUID(uuidString: adoptedEnvironmentID)),
                    stackID: try #require(UUID(uuidString: adoptedStackID)),
                    name: "Penta DB",
                    kind: "supabase",
                    identifier: "penta-db",
                    relationship: "adopted",
                    executable: "pnpm",
                    startArguments: ["exec", "supabase", "start", "--workdir", "backend"],
                    startWorkingDirectory: "/tmp/dev-switcher-compat/penta",
                    configDirectory: "/tmp/dev-switcher-compat/penta/backend"
                ),
            ]
        )
    }

    @Test("読んだ v6 を保存し直して読み直しても、取り出した値が変わらない")
    func roundTripKeepsExtractedValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try writeLiteral(to: directory)
        let loaded = try store.load()
        let before = try loaded.managed.map(extract)

        try store.save(loaded.hints, legacy: loaded.legacy, managed: loaded.managed)
        let reloaded = try store.load()

        #expect(try reloaded.managed.map(extract) == before)
        #expect(reloaded.hints == loaded.hints)
        #expect(reloaded.legacy == loaded.legacy)
    }

    @Test("v6 のリテラルは、管理対象の4キーのどれかが欠けると読み込みを失敗させる")
    func v6RequiresAllManagedKeys() throws {
        for missing in ["supabaseProjectID", "configDirectory", "fingerprint", "relationship"] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = RuntimeHintStore(directory: directory)
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(v6Literal.utf8)) as? [String: Any]
            )
            var managed = try #require(object["managedHints"] as? [[String: Any]])
            managed[0].removeValue(forKey: missing)
            object["managedHints"] = managed
            try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

            #expect(throws: RuntimeHintStoreError.self, "\(missing)") { try store.load() }
        }
    }
}
