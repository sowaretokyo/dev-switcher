import Foundation
import Testing
@testable import DevSwitcherCore

/// 管理対象スタックの種類共通の型と、Supabase 設定の導出・構造不備の判定が、
/// 期待どおりの結果を返すことを確かめる。
@Suite("管理対象スタックのドメイン型")
struct ManagedStackDomainTests {
    // MARK: - 部品

    struct ConfigurationCase: CustomTestStringConvertible, Sendable {
        let name: String
        let executable: String
        let arguments: [String]
        let hasCustomStop: Bool
        /// 期待する構造不備。nil なら導出できる。
        let expectedIssue: SupabaseConfigurationIssue?

        var testDescription: String { name }
    }

    static let configurationCases: [ConfigurationCase] = [
        ConfigurationCase(
            name: "直接実行", executable: "supabase", arguments: ["start"],
            hasCustomStop: false, expectedIssue: nil
        ),
        ConfigurationCase(
            name: "pnpm exec とラッパー引数", executable: "pnpm",
            arguments: ["exec", "supabase@latest", "start", "--exclude", "studio"],
            hasCustomStop: false, expectedIssue: nil
        ),
        ConfigurationCase(
            name: "npx とサブコマンド前の相対 workdir", executable: "npx",
            arguments: ["supabase", "--debug", "--workdir", "sub", "start"],
            hasCustomStop: false, expectedIssue: nil
        ),
        ConfigurationCase(
            name: "pnpx と start 後ろの絶対 workdir", executable: "pnpx",
            arguments: ["supabase", "start", "--workdir=/tmp/devswitcher-target"],
            hasCustomStop: false, expectedIssue: nil
        ),
        ConfigurationCase(
            name: "対応していないラッパー", executable: "npm", arguments: ["run", "start"],
            hasCustomStop: false, expectedIssue: .commandUnsupported
        ),
        ConfigurationCase(
            name: "start サブコマンドが無い", executable: "supabase", arguments: ["status"],
            hasCustomStop: false, expectedIssue: .startSubcommandMissing
        ),
        ConfigurationCase(
            name: "--no-backup", executable: "supabase", arguments: ["start", "--no-backup"],
            hasCustomStop: false, expectedIssue: .forbiddenStopOption("--no-backup")
        ),
        ConfigurationCase(
            name: "--all と --no-backup", executable: "supabase",
            arguments: ["start", "--no-backup", "--all"],
            hasCustomStop: false, expectedIssue: .forbiddenStopOption("--all")
        ),
        ConfigurationCase(
            name: "workdir の値が欠けている", executable: "supabase", arguments: ["start", "--workdir"],
            hasCustomStop: false, expectedIssue: .workdirValueMissing
        ),
        ConfigurationCase(
            name: "カスタム停止コマンド", executable: "supabase", arguments: ["start"],
            hasCustomStop: true, expectedIssue: .customStopUnsupported
        ),
    ]

    private func service(_ input: ConfigurationCase, in directory: URL) -> LaunchUnit {
        makeService(
            name: "Supabase",
            kind: .supabase,
            executable: input.executable,
            arguments: input.arguments,
            workingDirectory: directory,
            stop: input.hasCustomStop
                ? CommandSpec(executable: "/usr/bin/true", arguments: [], workingDirectory: directory)
                : nil
        )
    }

    // MARK: - 設定の導出と構造不備

    @Test("構造不備と導出が対応し、不備がなければ導出結果が得られる", arguments: configurationCases)
    func structuralIssuesCorrespondToDerivation(_ input: ConfigurationCase) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(input, in: directory)
        let definition = try #require(service.managedStackDefinition)
        let workingDirectory = service.start.workingDirectory

        let issues = definition.configuration.structuralIssues(workingDirectory: workingDirectory)
        let derived = definition.configuration.derived(workingDirectory: workingDirectory)

        if let expectedIssue = input.expectedIssue {
            #expect(issues == [.supabase(expectedIssue)])
            #expect(derived == nil)
            #expect(issues.first?.failureReason == expectedIssue.failureReason)

            // 対応する検証エラー。ValidationError の文言と一致することを確かめる。
            let expectedError = ValidationError.managedStackConfigurationInvalid(
                stack: "Supabase",
                issue: .supabase(expectedIssue)
            )
            #expect(issues.first?.validationMessage(stackName: "Supabase") == expectedError.description)
            let errors = ProjectValidator.validate(
                makeProject(directory: directory, services: [service])
            )
            #expect(errors.contains(expectedError))
            return
        }

        #expect(issues.isEmpty)
        let wrapped = try #require(derived)
        guard case let .supabase(configuration) = wrapped else {
            Issue.record("Supabase の導出結果ではありません。")
            return
        }
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))

        for command in [configuration.statusCommand, configuration.stopCommand(projectID: projectID)] {
            #expect(!command.arguments.contains("--all"))
            #expect(!command.arguments.contains("--no-backup"))
        }
    }

    struct LiteralDerivationCase: CustomTestStringConvertible, Sendable {
        let name: String
        let startArguments: [String]
        let configDirectory: String
        let statusArguments: [String]
        let stopArguments: [String]

        var testDescription: String { name }
    }

    /// 期待値は Phase A 以前の `LaunchUnit.supabaseConfiguration` の規則から導いたリテラル。
    /// start の workingDirectory は `/work/app`（実在しなくてよい）。
    static let literalDerivationCases: [LiteralDerivationCase] = [
        LiteralDerivationCase(
            name: "サブコマンド前の相対 --workdir は start の workingDirectory 基準で解決する",
            startArguments: ["--workdir", "./db", "start"],
            configDirectory: "/work/app/db",
            statusArguments: ["status", "--workdir", "/work/app/db", "--output", "json"],
            stopArguments: ["stop", "--workdir", "/work/app/db", "--project-id", "bell"]
        ),
        LiteralDerivationCase(
            name: "--workdir=./db 形式",
            startArguments: ["--workdir=./db", "start"],
            configDirectory: "/work/app/db",
            statusArguments: ["status", "--workdir", "/work/app/db", "--output", "json"],
            stopArguments: ["stop", "--workdir", "/work/app/db", "--project-id", "bell"]
        ),
        LiteralDerivationCase(
            name: "--debug は引き継ぎ、--output / -o / --workdir は落とす",
            startArguments: ["--debug", "--output", "json", "-o", "json", "--workdir", "/work/other", "start"],
            configDirectory: "/work/other",
            statusArguments: ["--debug", "status", "--workdir", "/work/other", "--output", "json"],
            stopArguments: ["--debug", "stop", "--workdir", "/work/other", "--project-id", "bell"]
        ),
    ]

    @Test("導出結果をリテラルで固定する", arguments: literalDerivationCases)
    func derivationMatchesLiteralExpectation(_ input: LiteralDerivationCase) throws {
        let workingDirectory = URL(fileURLWithPath: "/work/app")
        let start = CommandSpec(
            executable: "supabase",
            arguments: input.startArguments,
            workingDirectory: workingDirectory
        )
        let wrapped = try #require(
            SupabaseStackConfiguration(start: start).derived(workingDirectory: workingDirectory)
        )
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
        let configDirectory = URL(fileURLWithPath: input.configDirectory)

        #expect(wrapped.configDirectory.path == input.configDirectory)
        #expect(wrapped.configFileURL.path == input.configDirectory + "/supabase/config.toml")

        #expect(wrapped.statusCommand.executable == "supabase")
        #expect(wrapped.statusCommand.arguments == input.statusArguments)
        #expect(wrapped.statusCommand.workingDirectory.path == input.configDirectory)

        let stop = wrapped.stopCommand(projectID: projectID)
        #expect(stop.executable == "supabase")
        #expect(stop.arguments == input.stopArguments)
        #expect(stop.workingDirectory.path == input.configDirectory)

        let fingerprint = wrapped.fingerprint
        #expect(fingerprint.executable == "supabase")
        #expect(fingerprint.startArguments == input.startArguments)
        #expect(fingerprint.startWorkingDirectory.path == "/work/app")
        #expect(fingerprint.configDirectory.path == input.configDirectory)
        #expect(fingerprint == SupabaseLifecycleFingerprint(start: start, configDirectory: configDirectory))
    }

    @Test("pnpm exec の導出結果が既存テストと同じ status / stop を作る")
    func derivedCommandsMatchExistingExpectation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SupabaseStackConfiguration(
            start: CommandSpec(
                executable: "pnpm",
                arguments: ["exec", "supabase@latest", "start", "--exclude", "studio"],
                workingDirectory: directory
            )
        )
        let derived = try #require(configuration.derived(workingDirectory: directory))
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))

        #expect(derived.configDirectory == directory.standardizedFileURL)
        #expect(derived.statusCommand.executable == "pnpm")
        #expect(derived.statusCommand.arguments == [
            "exec", "supabase@latest", "status",
            "--workdir", directory.standardizedFileURL.path,
            "--output", "json",
        ])
        #expect(derived.stopCommand(projectID: projectID).arguments == [
            "exec", "supabase@latest", "stop",
            "--workdir", directory.standardizedFileURL.path,
            "--project-id", "bell",
        ])
    }

    @Test("resolve は設定ファイルの project_id から ID と構成同一性を確定する")
    func resolveReadsProjectID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let service = makeSupabaseService(workingDirectory: directory)
        let definition = try #require(service.managedStackDefinition)
        let derived = try #require(
            definition.configuration.derived(workingDirectory: directory)
        )
        guard case let .supabase(compatible) = derived else {
            Issue.record("Supabase の導出結果ではありません。")
            return
        }

        let resolved = try definition.configuration.resolve(workingDirectory: directory)

        #expect(resolved.type == .supabase)
        #expect(resolved.identity == (try makeSupabaseIdentity("bell")))
        #expect(resolved.fingerprint == .supabase(compatible.fingerprint))

        let environmentID = UUID()
        let stack = try ResolvedManagedStack(
            environmentID: environmentID,
            definition: definition,
            workingDirectory: directory
        )
        #expect(stack.environmentID == environmentID)
        #expect(stack.stackID == service.id)
        #expect(stack.stackName == "Supabase")
        #expect(stack.configuration == resolved)
        #expect(stack.sourceConfiguration == definition.configuration)
    }

    @Test("resolve は設定ファイルの読み取りエラーをラップせずに throw する")
    func resolveRethrowsConfigErrorUnwrapped() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeSupabaseService(workingDirectory: directory)
        let definition = try #require(service.managedStackDefinition)
        let configFile = SupabaseConfigFile.configFileURL(inConfigDirectory: directory)

        #expect(throws: SupabaseConfigError.fileMissing(configFile)) {
            try definition.configuration.resolve(workingDirectory: directory)
        }
    }

    @Test("resolve は構造不備を failureReason と同じ文言のエラーで throw する")
    func resolveThrowsStructuralIssue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 設定ファイルがあっても、構造不備なら読みに行かずに止める。
        try writeSupabaseConfig(projectID: "bell", in: directory)
        let service = makeSupabaseService(
            workingDirectory: directory,
            arguments: ["start", "--no-backup"]
        )
        let definition = try #require(service.managedStackDefinition)

        do {
            _ = try definition.configuration.resolve(workingDirectory: directory)
            Issue.record("構造不備なのに resolve が成功しました。")
        } catch let error as ManagedStackConfigurationError {
            #expect(error == .invalid(.supabase(.forbiddenStopOption("--no-backup"))))
            #expect(error.description == SupabaseConfigurationIssue.forbiddenStopOption("--no-backup").failureReason)
        }
    }

    // MARK: - アダプタ

    @Test("アダプタは kind が supabase のときだけ、設定の妥当性にかかわらず定義を返す")
    func adapterReturnsDefinitionOnlyForSupabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in ServiceKind.allCases where kind != .supabase {
            let service = makeService(kind: kind, workingDirectory: directory)
            #expect(service.managedStackDefinition == nil, "\(kind)")
            #expect(service.usesProcessGroupStop, "\(kind)")
        }

        let invalid = makeSupabaseService(workingDirectory: directory, arguments: ["status"])
        let definition = try #require(invalid.managedStackDefinition)
        #expect(definition.id == invalid.id)
        #expect(definition.name == invalid.name)
        #expect(definition.type == .supabase)
        #expect(definition.ports == invalid.ports)
        #expect(definition.enabledByDefault == invalid.enabledByDefault)
        #expect(definition.failurePolicy == invalid.failurePolicy)
        #expect(definition.configuration == .supabase(
            SupabaseStackConfiguration(start: invalid.start, stop: nil)
        ))
        #expect(!invalid.usesProcessGroupStop)

        let customStop = makeService(
            kind: .web,
            workingDirectory: directory,
            stop: CommandSpec(executable: "/usr/bin/true", arguments: [], workingDirectory: directory)
        )
        #expect(!customStop.usesProcessGroupStop)
    }

    // MARK: - 種類と ID

    @Test("種類の表示名・ID の呼び名・policy")
    func typeMetadata() {
        #expect(ManagedStackType.allCases == [.supabase, .dockerCompose])
        #expect(ManagedStackType.supabase.rawValue == "supabase")
        #expect(ManagedStackType.supabase.displayName == "Supabase")
        #expect(ManagedStackType.supabase.identityLabel == "`project_id`")
        #expect(ManagedStackType.supabase.policy == ManagedStackPolicy(
            maximumPerEnvironment: 1,
            conflictScope: .allOfType,
            supportsAdoption: true
        ))
    }

    @Test("ID は project_id の規則で検証し、正規化で値が変わるものを拒否する")
    func identityValidation() throws {
        let valid = try makeSupabaseIdentity("bell_1.a-b")
        #expect(valid.type == .supabase)
        #expect(valid.value == "bell_1.a-b")
        #expect(valid.description == "bell_1.a-b")

        for value in ["", " bell", "bell ", "-bell", "bell/x", String(repeating: "a", count: 129)] {
            #expect(throws: ManagedStackIdentityError.invalidValue(type: .supabase, value: value)) {
                try ManagedStackIdentity(type: .supabase, value: value)
            }
        }
    }

    @Test("SupabaseProjectID と ID の相互変換")
    func projectIDConversion() throws {
        let projectID = try #require(SupabaseProjectID(rawValue: "bell"))
        let converted = ManagedStackIdentity(projectID)
        #expect(converted == (try makeSupabaseIdentity("bell")))
        #expect(try SupabaseProjectID(identity: converted) == projectID)

        // 検証を経ずに作られた不正な値は、変換時に拒否する。
        let unchecked = ManagedStackIdentity(validatedType: .supabase, value: " bell")
        #expect(throws: ManagedStackIdentityError.invalidValue(type: .supabase, value: " bell")) {
            try SupabaseProjectID(identity: unchecked)
        }
    }

    @Test("ID は (種類, 値) の昇順に並ぶ")
    func identityOrdering() throws {
        let ids = try ["b", "a", "c"].map(makeSupabaseIdentity)
        #expect(ids.sorted().map(\.value) == ["a", "b", "c"])
    }

    @Test("ID の JSON は type と value で往復する")
    func identityJSONRoundTrip() throws {
        let original = try makeSupabaseIdentity("bell")
        let data = try JSONEncoder().encode(original)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(object == ["type": "supabase", "value": "bell"])
        #expect(try JSONDecoder().decode(ManagedStackIdentity.self, from: data) == original)
    }

    @Test(
        "不正な ID の JSON は decode に失敗する",
        arguments: [
            #"{"type":"supabase","value":" bell"}"#,
            #"{"type":"supabase","value":"-bell"}"#,
            #"{"type":"supabase","value":""}"#,
            #"{"type":"unknown","value":"bell"}"#,
            #"{"type":"supabase"}"#,
            #"{"value":"bell"}"#,
        ]
    )
    func identityJSONRejectsInvalidValues(_ json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ManagedStackIdentity.self, from: Data(json.utf8))
        }
    }

    @Test("構成同一性の JSON は type と種類名のキーで往復する")
    func fingerprintJSONRoundTrip() throws {
        let original = ManagedStackFingerprint.supabase(makeSupabaseFingerprint())
        let data = try JSONEncoder().encode(original)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == ["type", "supabase"])
        #expect(object["type"] as? String == "supabase")

        // 中身は既存の SupabaseLifecycleFingerprint と同じキーで書く。
        let inner = try #require(object["supabase"] as? [String: Any])
        let legacy = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSupabaseFingerprint()))
                as? [String: Any]
        )
        #expect(Set(inner.keys) == Set(legacy.keys))
        #expect(try JSONDecoder().decode(ManagedStackFingerprint.self, from: data) == original)
    }

    @Test("種類と中身が合わない構成同一性の JSON は decode に失敗する")
    func fingerprintJSONRejectsMismatch() throws {
        let inner = String(decoding: try JSONEncoder().encode(makeSupabaseFingerprint()), as: UTF8.self)
        for json in [
            #"{"type":"dockerCompose","supabase":\#(inner)}"#,
            #"{"type":"supabase","dockerCompose":\#(inner)}"#,
            #"{"supabase":\#(inner)}"#,
            #"{"type":"supabase","supabase":{}}"#,
        ] {
            #expect(throws: DecodingError.self, "\(json)") {
                try JSONDecoder().decode(ManagedStackFingerprint.self, from: Data(json.utf8))
            }
        }
    }

    // MARK: - 状態と snapshot

    @Test("状態と管理関係のラベルは従来の文言と同じ")
    func stateAndRelationshipLabels() {
        #expect(ManagedStackState.notRunning.label == "停止中")
        #expect(ManagedStackState.running.label == "稼働中")
        #expect(ManagedStackState.degraded.label == "一部だけ稼働")
        #expect(ManagedStackState.unknown.label == "判定不能")
        #expect(ManagedStackRelationship.launched.label == "今回起動")
        #expect(ManagedStackRelationship.adopted.label == "引き継ぎ")
        #expect(ManagedStackRelationship.restored.label == "再検証済み")
    }

    @Test("観測の等価は ID と状態だけで判定する")
    func observationEqualityIgnoresDetail() throws {
        let a = ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .unknown, detail: "x")
        let b = ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .unknown, detail: "y")
        let c = ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running, detail: "x")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("観測済みの種類で未列挙の ID は停止中、unknown は理由つきで数える")
    func observedSnapshotSemantics() throws {
        let snapshot = ManagedStackSnapshot(
            type: .supabase,
            observations: [
                ManagedStackObservation(identity: try makeSupabaseIdentity("cat"), state: .unknown, detail: "壊れた"),
                ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running),
                ManagedStackObservation(identity: try makeSupabaseIdentity("dog"), state: .unknown),
            ]
        )

        #expect(snapshot.observations.map(\.identity.value) == ["bell", "cat", "dog"])
        #expect(snapshot.state(of: try makeSupabaseIdentity("bell")) == .running)
        #expect(snapshot.state(of: try makeSupabaseIdentity("zzz")) == .notRunning)
        #expect(snapshot.observation(of: try makeSupabaseIdentity("zzz")).detail == nil)
        #expect(snapshot.hasUnknown)
        #expect(snapshot.failureDetails == ["cat: 壊れた", "dog: 理由を取得できませんでした。"])
        #expect(snapshot.hasResult(for: .supabase))
        #expect(snapshot.failure(of: .supabase) == nil)
    }

    @Test("観測全体が失敗した種類の ID は判定不能で、理由を返す")
    func failedSnapshotSemantics() throws {
        let snapshot = ManagedStackSnapshot(type: .supabase, unobservable: "docker が応答しません。")
        let observation = snapshot.observation(of: try makeSupabaseIdentity("bell"))

        #expect(observation.state == .unknown)
        #expect(observation.detail == "docker が応答しません。")
        #expect(snapshot.hasUnknown)
        #expect(snapshot.failureDetails == ["docker が応答しません。"])
        #expect(snapshot.observations.isEmpty)
        #expect(snapshot.failure(of: .supabase) == "docker が応答しません。")
    }

    @Test("未観測の種類の ID は判定不能だが、hasUnknown と failureDetails に含めない")
    func unobservedSnapshotSemantics() throws {
        let snapshot = ManagedStackSnapshot()
        let observation = snapshot.observation(of: try makeSupabaseIdentity("bell"))

        #expect(observation.state == .unknown)
        #expect(observation.detail == "Supabaseの状態をまだ観測できていません。")
        #expect(!snapshot.hasUnknown)
        #expect(snapshot.failureDetails.isEmpty)
        #expect(snapshot.observations.isEmpty)
        #expect(!snapshot.hasResult(for: .supabase))
    }

    @Test("typesWithUnknown は観測失敗または unknown を含む種類だけを返し、未観測は含めない")
    func typesWithUnknownSemantics() throws {
        let allRunning = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running),
        ])
        let withUnknown = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running),
            ManagedStackObservation(identity: try makeSupabaseIdentity("cat"), state: .unknown),
        ])
        let failed = ManagedStackSnapshot(type: .supabase, unobservable: "docker が応答しません。")

        #expect(allRunning.typesWithUnknown.isEmpty)
        #expect(withUnknown.typesWithUnknown == [.supabase])
        #expect(failed.typesWithUnknown == [.supabase])
        #expect(ManagedStackSnapshot().typesWithUnknown.isEmpty)
    }

    @Test("snapshot の等価は観測の ID と状態、観測失敗の理由で判定する")
    func snapshotEquality() throws {
        let a = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .unknown, detail: "x"),
        ])
        let b = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .unknown, detail: "y"),
        ])
        let c = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running),
        ])
        #expect(a == b)
        #expect(a != c)
        #expect(
            ManagedStackSnapshot(type: .supabase, unobservable: "x")
                != ManagedStackSnapshot(type: .supabase, unobservable: "y")
        )
        #expect(ManagedStackSnapshot() != ManagedStackSnapshot(type: .supabase, observations: []))
        #expect(ManagedStackSnapshot().merging(c) == c)
    }

    // MARK: - 確認 plan と承認

    @Test("確認行の id は種類と ID から作り、action のラベルは現行と同じ")
    func confirmationTargetIDAndLabels() throws {
        let target = ManagedStackConfirmationTarget(
            stackID: nil,
            identity: try makeSupabaseIdentity("bell"),
            state: .running,
            action: .stop,
            registration: nil
        )
        #expect(target.id == "supabase:bell")
        #expect(target.registrationLabel == "未登録")

        let labels: [(ManagedStackConfirmationTarget.Action, String)] = [
            (.adopt, "引き継ぐ"), (.restart, "停止して起動し直す"), (.stop, "停止する"), (.start, "起動する"),
        ]
        for (action, label) in labels {
            #expect(action.label == label, "\(action)")
        }

        let registered = ManagedStackConfirmationTarget(
            stackID: UUID(),
            identity: try makeSupabaseIdentity("bell"),
            state: .running,
            action: .adopt,
            registration: .init(
                environmentName: "Bell",
                stackName: "Supabase",
                directory: URL(fileURLWithPath: "/tmp/bell")
            )
        )
        #expect(registered.registrationLabel == "Bell / Supabase")
    }

    @Test("新規起動だけの plan は確認不要で、それ以外の action があれば確認が要る")
    func planRequiresConfirmation() throws {
        let stackID = UUID()
        let start = ManagedStackConfirmationTarget(
            stackID: stackID, identity: try makeSupabaseIdentity("bell"), state: .notRunning,
            action: .start,
            registration: .init(
                environmentName: "Bell", stackName: "Supabase", directory: URL(fileURLWithPath: "/tmp/bell")
            )
        )
        let stop = ManagedStackConfirmationTarget(
            stackID: nil, identity: try makeSupabaseIdentity("cat"), state: .running,
            action: .stop, registration: nil
        )
        let fingerprints = [stackID: ManagedStackFingerprint.supabase(makeSupabaseFingerprint())]

        let startOnly = ManagedStackConfirmationPlan(
            environmentName: "Bell", entries: [start],
            snapshot: ManagedStackSnapshot(type: .supabase, observations: []),
            fingerprints: fingerprints
        )
        #expect(!startOnly.requiresConfirmation)

        let withStop = ManagedStackConfirmationPlan(
            environmentName: "Bell", entries: [start, stop],
            snapshot: ManagedStackSnapshot(type: .supabase, observations: []),
            fingerprints: fingerprints
        )
        #expect(withStop.requiresConfirmation)
        #expect(withStop.approval.entries == [
            ManagedStackApproval.Entry(stackID: stackID, identity: try makeSupabaseIdentity("bell"), action: .start),
            ManagedStackApproval.Entry(stackID: nil, identity: try makeSupabaseIdentity("cat"), action: .stop),
        ])
        #expect(withStop.approval.fingerprints == fingerprints)
        #expect(withStop.approval.snapshot == withStop.snapshot)
    }

    @Test("登録情報が変わっても承認内容は変わらない")
    func approvalIgnoresRegistration() throws {
        let stackID = UUID()
        let snapshot = ManagedStackSnapshot(type: .supabase, observations: [
            ManagedStackObservation(identity: try makeSupabaseIdentity("bell"), state: .running),
        ])
        func plan(environmentName: String, stackName: String, directory: String) throws
            -> ManagedStackConfirmationPlan {
            ManagedStackConfirmationPlan(
                environmentName: environmentName,
                entries: [
                    ManagedStackConfirmationTarget(
                        stackID: stackID,
                        identity: try makeSupabaseIdentity("bell"),
                        state: .running,
                        action: .adopt,
                        registration: .init(
                            environmentName: environmentName,
                            stackName: stackName,
                            directory: URL(fileURLWithPath: directory)
                        )
                    ),
                ],
                snapshot: snapshot,
                fingerprints: [stackID: .supabase(makeSupabaseFingerprint())]
            )
        }

        let before = try plan(environmentName: "Bell", stackName: "Supabase", directory: "/tmp/a")
        let after = try plan(environmentName: "Cat", stackName: "DB", directory: "/tmp/b")
        #expect(before != after)
        #expect(before.approval == after.approval)
    }

    @Test("primaryStackName は先頭行の registration の stackName を返す")
    func primaryStackNameComesFromPrimaryEntry() throws {
        let stackID = UUID()
        func entry(_ value: String, _ id: UUID?, _ stackName: String) throws -> ManagedStackConfirmationTarget {
            ManagedStackConfirmationTarget(
                stackID: id, identity: try makeSupabaseIdentity(value), state: .running, action: id == nil ? .stop : .adopt,
                registration: .init(
                    environmentName: "Bell", stackName: stackName, directory: URL(fileURLWithPath: "/tmp/bell")
                )
            )
        }
        let plan = ManagedStackConfirmationPlan(
            environmentName: "Bell",
            entries: [try entry("bell", stackID, "Primary"), try entry("cat", nil, "Other")],
            snapshot: ManagedStackSnapshot(type: .supabase, observations: []),
            fingerprints: [stackID: .supabase(makeSupabaseFingerprint())]
        )
        #expect(plan.primaryStackName == "Primary")
    }
}
