import Foundation
import Testing
@testable import DevSwitcherCore

/// 手掛かりファイル schema v7（種類共通の`ManagedStackHint`）の読み書きと、旧形式からの変換を固定する。
@Suite("手掛かりファイル v7")
struct RuntimeHintV7Tests {
    private let environmentID = "11111111-1111-4111-8111-111111111111"
    private let stackID = "22222222-2222-4222-8222-222222222222"
    private let otherEnvironmentID = "33333333-3333-4333-8333-333333333333"
    private let otherStackID = "44444444-4444-4444-8444-444444444444"

    private let supabaseFingerprintJSON = """
        {
          "executable": "supabase",
          "startArguments": ["start"],
          "startWorkingDirectory": "file:///tmp/dev-switcher-v7/demo/",
          "configDirectory": "file:///tmp/dev-switcher-v7/demo/"
        }
        """

    /// v7 の launched 1 件と未検証 1 件。
    private var v7Literal: String {
        """
        {
          "schemaVersion": 7,
          "hints": [],
          "legacyHints": [],
          "managedHints": [
            {
              "projectID": "\(environmentID)",
              "stackID": "\(stackID)",
              "stackName": "Supabase",
              "type": "supabase",
              "identity": { "type": "supabase", "value": "demo" },
              "fingerprint": { "type": "supabase", "supabase": \(supabaseFingerprintJSON) },
              "relationship": "launched"
            },
            {
              "projectID": "\(otherEnvironmentID)",
              "stackID": "\(otherStackID)",
              "stackName": "Sample DB",
              "type": "supabase",
              "identity": null,
              "fingerprint": null,
              "relationship": null
            }
          ]
        }
        """
    }

    private func store(writing json: String, in directory: URL) throws -> RuntimeHintStore {
        let store = RuntimeHintStore(directory: directory)
        try Data(json.utf8).write(to: store.fileURL)
        return store
    }

    private func store(writing object: [String: Any], in directory: URL) throws -> RuntimeHintStore {
        let store = RuntimeHintStore(directory: directory)
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        return store
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func supabaseFingerprint(_ hint: ManagedStackHint) throws -> SupabaseLifecycleFingerprint {
        switch try #require(hint.fingerprint) {
        case let .supabase(fingerprint): fingerprint
        case .dockerCompose: preconditionFailure("Supabase fixture ではありません。")
        }
    }

    // MARK: - v6 からの変換

    @Test("v6 の手掛かりを、種類・ID・構成同一性を持つ v7 の手掛かりへ変換する")
    func convertsV6HintToV7() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(
            writing: """
                {
                  "schemaVersion": 6,
                  "hints": [],
                  "legacyHints": [],
                  "managedHints": [{
                    "projectID": "\(environmentID)",
                    "serviceID": "\(stackID)",
                    "serviceName": "Supabase",
                    "supabaseProjectID": "demo",
                    "configDirectory": "file:///tmp/dev-switcher-v7/demo/",
                    "fingerprint": \(supabaseFingerprintJSON),
                    "relationship": "adopted"
                  }]
                }
                """,
            in: directory
        )

        let hint = try #require(try store.load().managed.first)

        #expect(hint.projectID == UUID(uuidString: environmentID))
        #expect(hint.stackID == UUID(uuidString: stackID))
        #expect(hint.stackName == "Supabase")
        #expect(hint.type == .supabase)
        #expect(hint.identity == (try ManagedStackIdentity(type: .supabase, value: "demo")))
        #expect(hint.relationship == .adopted)
        let fingerprint = try supabaseFingerprint(hint)
        #expect(fingerprint.executable == "supabase")
        #expect(fingerprint.startArguments == ["start"])
        #expect(fingerprint.startWorkingDirectory.path == "/tmp/dev-switcher-v7/demo")
        #expect(fingerprint.configDirectory.path == "/tmp/dev-switcher-v7/demo")
    }

    @Test("v6 で設定ディレクトリと構成同一性が食い違う手掛かりは未検証にし、同じファイルの他の手掛かりは読める")
    func v6ConfigDirectoryMismatchBecomesUnverified() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(
            writing: """
                {
                  "schemaVersion": 6,
                  "hints": [],
                  "legacyHints": [],
                  "managedHints": [
                    {
                      "projectID": "\(environmentID)",
                      "serviceID": "\(stackID)",
                      "serviceName": "Supabase",
                      "supabaseProjectID": "demo",
                      "configDirectory": "file:///tmp/dev-switcher-v7/elsewhere/",
                      "fingerprint": \(supabaseFingerprintJSON),
                      "relationship": "launched"
                    },
                    {
                      "projectID": "\(otherEnvironmentID)",
                      "serviceID": "\(otherStackID)",
                      "serviceName": "Sample DB",
                      "supabaseProjectID": "sample",
                      "configDirectory": "file:///tmp/dev-switcher-v7/demo/",
                      "fingerprint": \(supabaseFingerprintJSON),
                      "relationship": "launched"
                    }
                  ]
                }
                """,
            in: directory
        )

        let managed = try store.load().managed

        #expect(managed.count == 2)
        let mismatched = try #require(managed.first { $0.stackID == UUID(uuidString: stackID) })
        #expect(mismatched.type == .supabase)
        #expect(mismatched.stackName == "Supabase")
        #expect(mismatched.projectID == UUID(uuidString: environmentID))
        #expect(mismatched.identity == nil)
        #expect(mismatched.fingerprint == nil)
        #expect(mismatched.relationship == nil)
        let intact = try #require(managed.first { $0.stackID == UUID(uuidString: otherStackID) })
        #expect(intact.identity?.value == "sample")
        #expect(intact.relationship == .launched)
        #expect(intact.fingerprint != nil)
    }

    @Test(
        "v6 で identity 系 4 項目の一部だけが null の手掛かりは未検証にし、同じファイルの他の手掛かりは読める",
        arguments: ["supabaseProjectID", "configDirectory", "fingerprint", "relationship"]
    )
    func v6PartiallyNullIdentityBecomesUnverified(nullKey: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values: [String: String] = [
            "supabaseProjectID": "\"demo\"",
            "configDirectory": "\"file:///tmp/dev-switcher-v7/demo/\"",
            "fingerprint": supabaseFingerprintJSON,
            "relationship": "\"launched\"",
        ]
        func field(_ key: String) -> String {
            "\"\(key)\": \(key == nullKey ? "null" : values[key] ?? "null")"
        }
        let store = try store(
            writing: """
                {
                  "schemaVersion": 6,
                  "hints": [],
                  "legacyHints": [],
                  "managedHints": [
                    {
                      "projectID": "\(environmentID)",
                      "serviceID": "\(stackID)",
                      "serviceName": "Supabase",
                      \(field("supabaseProjectID")),
                      \(field("configDirectory")),
                      \(field("fingerprint")),
                      \(field("relationship"))
                    },
                    {
                      "projectID": "\(otherEnvironmentID)",
                      "serviceID": "\(otherStackID)",
                      "serviceName": "Sample DB",
                      "supabaseProjectID": "sample",
                      "configDirectory": "file:///tmp/dev-switcher-v7/demo/",
                      "fingerprint": \(supabaseFingerprintJSON),
                      "relationship": "launched"
                    }
                  ]
                }
                """,
            in: directory
        )

        let managed = try store.load().managed

        #expect(managed.count == 2)
        let partial = try #require(managed.first { $0.stackID == UUID(uuidString: stackID) })
        #expect(partial.type == .supabase)
        #expect(partial.stackName == "Supabase")
        #expect(partial.projectID == UUID(uuidString: environmentID))
        #expect(partial.identity == nil)
        #expect(partial.fingerprint == nil)
        #expect(partial.relationship == nil)
        let intact = try #require(managed.first { $0.stackID == UUID(uuidString: otherStackID) })
        #expect(intact.identity?.value == "sample")
        #expect(intact.relationship == .launched)
        #expect(intact.fingerprint != nil)
    }

    // MARK: - v4・v5 からの変換

    @Test("v4・v5 の手掛かりは、種類を supabase とした未検証の手掛かりになる", arguments: [4, 5])
    func legacyManagedHintsBecomeUnverifiedSupabase(schemaVersion: Int) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(
            writing: """
                {
                  "schemaVersion": \(schemaVersion),
                  "hints": [],
                  "legacyHints": [],
                  "managedHints": [{
                    "projectID": "\(environmentID)",
                    "serviceID": "\(stackID)",
                    "serviceName": "Supabase"
                  }]
                }
                """,
            in: directory
        )

        let hint = try #require(try store.load().managed.first)

        #expect(hint.projectID == UUID(uuidString: environmentID))
        #expect(hint.stackID == UUID(uuidString: stackID))
        #expect(hint.stackName == "Supabase")
        #expect(hint.type == .supabase)
        #expect(hint.identity == nil)
        #expect(hint.fingerprint == nil)
        #expect(hint.relationship == nil)
    }

    // MARK: - v7 の読み書き

    @Test("v7 の launched と未検証の手掛かりを読み、保存し直しても同じ値に戻る")
    func roundTripsV7() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(writing: v7Literal, in: directory)

        let loaded = try store.load()
        #expect(loaded.managed.count == 2)
        let launched = try #require(loaded.managed.first)
        #expect(launched.identity?.value == "demo")
        #expect(launched.relationship == .launched)
        #expect(try supabaseFingerprint(launched).configDirectory.path == "/tmp/dev-switcher-v7/demo")
        let unverified = try #require(loaded.managed.last)
        #expect(unverified.identity == nil)
        #expect(unverified.fingerprint == nil)
        #expect(unverified.relationship == nil)

        try store.save(loaded.hints, legacy: loaded.legacy, managed: loaded.managed)
        let savedJSON = try String(contentsOf: store.fileURL, encoding: .utf8)
        // 未検証の手掛かりの null もキーごと書き出す。
        #expect(savedJSON.contains("\"identity\" : null"))
        #expect(savedJSON.contains("\"fingerprint\" : null"))
        #expect(savedJSON.contains("\"relationship\" : null"))
        #expect(try store.load() == loaded)
    }

    @Test("ResolvedManagedStack から作った手掛かりを保存すると v7 で書き出し、読み戻せる")
    func savesAsV7() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeSupabaseService(workingDirectory: directory)
        let supabaseProjectID = try #require(SupabaseProjectID(rawValue: "demo"))
        let hint = try makeManagedStackHint(
                projectID: UUID(),
                service: service,
                supabaseProjectID: supabaseProjectID,
                relationship: .restored
            )
        let store = RuntimeHintStore(directory: directory)

        try store.save([], legacy: [], managed: [hint])

        let saved = try jsonObject(String(contentsOf: store.fileURL, encoding: .utf8))
        #expect(saved["schemaVersion"] as? Int == 7)
        #expect(RuntimeHintsDocument.currentSchemaVersion == 7)
        let managed = try #require(saved["managedHints"] as? [[String: Any]])
        let firstKeys = Set(try #require(managed.first).keys)
        #expect(firstKeys == [
            "projectID", "stackID", "stackName", "type", "identity", "fingerprint", "relationship",
        ])
        #expect(try store.load().managed == [hint])
    }

    @Test("v7 の手掛かりは、どのキーが欠けても読み込みを失敗させる")
    func v7RequiresAllKeys() throws {
        let keys = ["projectID", "stackID", "stackName", "type", "identity", "fingerprint", "relationship"]
        for index in [0, 1] {
            for missing in keys {
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                var object = try jsonObject(v7Literal)
                var managed = try #require(object["managedHints"] as? [[String: Any]])
                managed[index].removeValue(forKey: missing)
                object["managedHints"] = managed
                let store = try store(writing: object, in: directory)

                #expect(throws: RuntimeHintStoreError.self, "\(index): \(missing)") { try store.load() }
            }
        }
    }

    @Test("v7 で managedHints のキーが欠けていれば読み込みを失敗させる")
    func v7RequiresManagedHintsKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try jsonObject(v7Literal)
        object.removeValue(forKey: "managedHints")
        let store = try store(writing: object, in: directory)

        #expect(throws: RuntimeHintStoreError.self) { try store.load() }
    }

    @Test("identity・fingerprint・relationship の一部だけが null なら読み込みを失敗させる")
    func v7RejectsPartiallyNullHint() throws {
        for nulled in ["identity", "fingerprint", "relationship"] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var object = try jsonObject(v7Literal)
            var managed = try #require(object["managedHints"] as? [[String: Any]])
            managed[0][nulled] = NSNull()
            object["managedHints"] = managed
            let store = try store(writing: object, in: directory)

            #expect(throws: RuntimeHintStoreError.self, "\(nulled)") { try store.load() }
        }
    }

    // 現在の種類は supabase だけなので、別の種類の値は種類の decode で失敗する。
    // 種類が増えたら、hint.type と identity / fingerprint の種類の照合で失敗する。
    @Test("identity や fingerprint の種類が type と食い違えば読み込みを失敗させる")
    func v7RejectsTypeMismatch() throws {
        let mismatches: [(key: String, value: Any)] = [
            ("identity", ["type": "dockerCompose", "value": "demo"]),
            ("fingerprint", ["type": "dockerCompose", "supabase": try jsonObject(supabaseFingerprintJSON)]),
            ("type", "dockerCompose"),
        ]
        for mismatch in mismatches {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var object = try jsonObject(v7Literal)
            var managed = try #require(object["managedHints"] as? [[String: Any]])
            managed[0][mismatch.key] = mismatch.value
            object["managedHints"] = managed
            let store = try store(writing: object, in: directory)

            #expect(throws: RuntimeHintStoreError.self, "\(mismatch.key)") { try store.load() }
        }
    }

    // MARK: - 重複

    @Test("管理対象の stackID と通常の手掛かりの serviceID の重複を、保存時と読み込み時に拒否する")
    func rejectsStackIDCollidingWithServiceID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeSupabaseService(workingDirectory: directory)
        let supabaseProjectID = try #require(SupabaseProjectID(rawValue: "demo"))
        let managed = try makeManagedStackHint(
                projectID: UUID(),
                service: service,
                supabaseProjectID: supabaseProjectID,
                relationship: .launched
            )
        let process = RuntimeHint(
            projectID: UUID(),
            serviceID: managed.stackID,
            serviceName: "Web",
            processGroupID: 5252,
            leader: ProcessAnchor(pid: 5252, startAbstime: 6_000),
            groupEvidence: ProcessGroupEvidence(
                bootSessionID: "BOOT-SESSION-A",
                anchors: [ProcessAnchor(pid: 5252, startAbstime: 6_000)]
            ),
            executablePath: "/bin/sleep",
            workingDirectory: directory,
            observedPorts: .observed([])
        )
        let store = RuntimeHintStore(directory: directory)

        #expect(throws: RuntimeHintStoreError.self) {
            try store.save([process], legacy: [], managed: [managed])
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        try JSONEncoder().encode(
            RuntimeHintsDocument(hints: [process], managedHints: [managed])
        ).write(to: store.fileURL)
        #expect(throws: RuntimeHintStoreError.self) { try store.load() }
    }
}
