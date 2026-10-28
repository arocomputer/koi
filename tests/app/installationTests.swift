import Foundation
import Testing
@testable import Koi

/// All persistent writes and shell invocations use a private fixture home and fake binary.
@Suite struct InstallationTests {
    /// The bundled zsh startup files run the user's own files with their
    /// ZDOTDIR restored, leave it restored afterwards, and add Koi's hooks
    /// only inside Koi; a script reads nothing but the user's .zshenv.
    @Test func bundledZshStartupRunsUserFilesAndAddsHooksOnlyInsideKoi() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let shells = try #require(Paths.repoRoot).appendingPathComponent("src/app/resources/shell/zsh")
        try Data("export USER_SETTING=1\n".utf8).write(to: fixture.home.appendingPathComponent(".zshenv"))
        try Data("precmd_functions=(fixture_prompt)\nexport RC_DIR=$ZDOTDIR\nPROMPT=fixture\n".utf8).write(to: fixture.home.appendingPathComponent(".zshrc"))
        let environment = ["ZDOTDIR": shells.path, "KOI_ZDOTDIR": fixture.home.path, "TERM_PROGRAM": "Koi"]
        let report = #"print -r -- "$USER_SETTING ${#precmd_functions} ${#preexec_functions} $RC_DIR $ZDOTDIR""#
        let inside = try fixture.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-i", "-c", report], environment: environment)
        #expect(inside.code == 0)
        #expect(inside.output == "1 2 1 \(fixture.home.path) \(fixture.home.path)\n", "user files ran with their own ZDOTDIR, and it stays")
        let outside = try fixture.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-i", "-c", report],
                                      environment: environment.merging(["TERM_PROGRAM": "Other"]) { _, b in b })
        #expect(outside.output == "1 1 0 \(fixture.home.path) \(fixture.home.path)\n", "no hooks outside Koi")
        let script = try fixture.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", #"print -r -- "$USER_SETTING ${ZDOTDIR-unset}""#], environment: environment)
        #expect(script.output == "1 \(fixture.home.path)\n", "a script sees only the user's environment")
        let markers = try fixture.run(URL(fileURLWithPath: "/bin/zsh"),
                                      arguments: ["-i", "-c", #"false; _koi_precmd; _koi_preexec 'sudo CC=clang ./tools/make -j4'; print -rn -- "$PROMPT""#],
                                      environment: environment)
        #expect(markers.code == 0)
        // preexec names the command past wrappers and assignments, without its path.
        #expect(markers.output == "\u{1B}]133;D;1\u{07}\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}\u{1B}]7502;cmd=make\u{07}fixture%{\u{1B}]133;B\u{07}%}")
    }

    @Test(arguments: [false, true]) func cliWrappersQuotePathsAndArgumentsAndPinDevelopmentState(development: Bool) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let wrapper = try CLIInstaller.install(sourceBinary: fixture.binary, home: fixture.home, development: development)
        #expect(wrapper.lastPathComponent == (development ? "koid-cli" : "koi"))
        let content = try Data(contentsOf: wrapper)
        let before = try metadata(wrapper)
        #expect(try CLIInstaller.install(sourceBinary: fixture.binary, home: fixture.home, development: development) == wrapper)
        #expect(try Data(contentsOf: wrapper) == content)
        #expect(try metadata(wrapper).inode == before.inode)
        let arguments = ["space argument", "'\"$HOME", "$(touch ARG_UNEXPECTED)", "line\nbreak", ""]
        let result = try fixture.run(wrapper, arguments: arguments, environment: ["KOI_DIR": "fixture-daily-state"])
        let expectedState = development ? fixture.home.appendingPathComponent(".local/state/koid").path : "fixture-daily-state"
        #expect(result.code == 0)
        #expect(result.output == expectedState + "\n" + arguments.map { "<" + $0 + ">" }.joined())
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("UNEXPECTED").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ARG_UNEXPECTED").path))
    }

    @Test(arguments: ["file", "symlink", "dangling"])
    func cliPreservesForeignFilesAndEveryExistingSymlink(kind: String) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let destination = fixture.home.appendingPathComponent(".local/bin/koi")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = fixture.root.appendingPathComponent("other-cli")
        if kind == "file" {
            try Data("my CLI".utf8).write(to: destination)
        } else {
            if kind == "symlink" {
                let otherHome = fixture.root.appendingPathComponent("another-home")
                try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let identical = try CLIInstaller.install(sourceBinary: fixture.binary, home: otherHome, development: false)
                try Data(contentsOf: identical).write(to: other)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)
        }
        let originalTarget = kind == "symlink" ? try Data(contentsOf: other) : nil
        #expect(throws: (any Error).self) {
            try CLIInstaller.install(sourceBinary: fixture.binary, home: fixture.home, development: false)
        }
        if kind == "file" {
            #expect(try String(contentsOf: destination, encoding: .utf8) == "my CLI")
        } else {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == other.path)
            if let originalTarget { #expect(try Data(contentsOf: other) == originalTarget) }
        }
    }

    @Test func unsafeRootsAndMissingExecutablesAreRejectedBeforePersistentWrites() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.home.path)
        #expect(throws: (any Error).self) { try AgentIntegrations(root: fixture.home).installFromUserAction(.codex) }
        #expect(throws: (any Error).self) {
            try CLIInstaller.install(sourceBinary: fixture.binary, home: fixture.home, development: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.home.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.binary.path)
        #expect(throws: (any Error).self) {
            try CLIInstaller.install(sourceBinary: fixture.binary, home: fixture.home, development: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
    }

    /// Inodes and permissions protect behavior that an atomic rewrite would accidentally break.
    private func metadata(_ url: URL) throws -> (inode: UInt64, mode: UInt16) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                try #require(attributes[.posixPermissions] as? NSNumber).uint16Value)
    }
}

/// No app binary is executed. Even malicious-looking fixture paths can only create private
/// marker files if quoting regresses; the fake CLI merely prints its environment/arguments.
private struct InstallationFixture {
    let root: URL
    let home: URL
    let binary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("koi-install-\(UUID().uuidString)")
        home = root.appendingPathComponent("home's $(touch UNEXPECTED) `touch UNEXPECTED`")
        binary = root.appendingPathComponent("koi's $(touch UNEXPECTED) `touch UNEXPECTED`\ncli")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fake = "#!/bin/sh\nprintf '%s\\n' \"${KOI_DIR-unset}\"\nprintf '<%s>' \"$@\"\n"
        try Data(fake.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// zsh -f plus private HOME/ZDOTDIR prevents loading user startup files. stderr is captured.
    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"]
            .merging(environment) { _, replacement in replacement }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
