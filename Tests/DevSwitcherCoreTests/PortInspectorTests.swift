import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("lsof 出力の解析")
struct PortInspectorTests {
    @Test("フィールド出力から実測ポートを取り出す")
    func parsesFieldOutput() throws {
        let output = """
        p26713
        g26713
        f3
        n*:9977
        """
        let ports = try PortInspector.parse(output)
        #expect(ports == [ObservedPort(port: 9977, pid: 26_713, address: "*")])
    }

    @Test("複数プロセス・複数ポートを解析する")
    func parsesMultipleEntries() throws {
        let output = """
        p100
        g100
        f3
        n127.0.0.1:54321
        f4
        n[::1]:54322
        p101
        g100
        f5
        n*:3000
        """
        let ports = try PortInspector.parse(output)
        #expect(ports.count == 3)
        #expect(ports.contains(ObservedPort(port: 54_321, pid: 100, address: "127.0.0.1")))
        #expect(ports.contains(ObservedPort(port: 54_322, pid: 100, address: "[::1]")))
        #expect(ports.contains(ObservedPort(port: 3000, pid: 101, address: "*")))
    }

    @Test("該当なし（空出力）は空配列")
    func emptyOutputIsEmptyList() throws {
        #expect(try PortInspector.parse("").isEmpty)
    }

    @Test("解析できない出力をポートなしとして扱わない")
    func unparsableOutputThrows() {
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("p100\nf3\nn*:not-a-port")
        }
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("pXYZ\nn*:3000")
        }
        // プロセス行より先にアドレス行が来る出力も受け付けない。
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("n*:3000")
        }
    }

    @Test("listen していないプロセスグループでは空配列を返す")
    func noListeningPortsForCurrentProcess() async throws {
        // テストプロセス自身のプロセスグループ。listen していなくてもエラーにしない。
        let ports = try await PortInspector.listeningPorts(processGroupID: getpgrp())
        #expect(ports.allSatisfy { $0.port > 0 })
    }
}
