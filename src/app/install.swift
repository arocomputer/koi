import Darwin
import Foundation

/// User-triggered CLI installation. Wrappers pin the bundle binary without copying it;
/// development wrappers also pin Koid's state directory and never inherit a daily KOI_DIR.
struct CLIInstaller {
    enum Failure: LocalizedError {
        case missingBinary, unsafePath, foreignFile

        var errorDescription: String? {
            switch self {
            case .missingBinary: "The app's koi executable is missing or is not executable."
            case .unsafePath: "Installation requires private, user-owned directories and regular files."
            case .foreignFile: "The destination already exists or was edited. Koi will preserve it."
            }
        }
    }

    /// Call only after the user clicks Install CLI. The default home is never used by tests.
    @discardableResult static func install(bundle: Bundle = .main,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          development: Bool = Paths.isDev) throws -> URL {
        guard let binary = bundle.url(forResource: "koi", withExtension: nil) else { throw Failure.missingBinary }
        return try install(sourceBinary: binary, home: home, development: development)
    }

    /// Explicit binary/home injection supports private fixtures without any bundle dependency.
    @discardableResult static func install(sourceBinary: URL, home: URL, development: Bool) throws -> URL {
        guard sourceBinary.isFileURL,
              try sourceBinary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: sourceBinary.path) else { throw Failure.missingBinary }
        let home = home.standardizedFileURL
        let destination = home.appendingPathComponent(".local/bin/" + (development ? "koid-cli" : "koi"))
        try InstallationFiles.validateParents(of: destination, home: home)
        var script = "#!/bin/sh\n# Installed by Koi. Edited wrappers are never overwritten.\n"
        if development {
            script += "export KOI_DIR=" + quote(home.appendingPathComponent(".local/state/koid").path) + "\n"
        }
        script += "exec " + quote(sourceBinary.path) + " \"$@\"\n"
        let data = Data(script.utf8)
        if let existing = try InstallationFiles.contents(at: destination) {
            guard existing == data, FileManager.default.isExecutableFile(atPath: destination.path) else { throw Failure.foreignFile }
            return destination
        }
        try InstallationFiles.validateParents(of: destination, home: home, create: true)
        try InstallationFiles.create(data, at: destination, permissions: 0o755)
        return destination
    }

    /// POSIX single-quoted literals also protect spaces, newlines, dollars and backticks.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Shared filesystem checks for the CLI wrapper and opt-in shell snippet only. Directory
/// symlinks may lead into a dotfiles repo; owned leaf files must never be symlinks.
enum InstallationFiles {
    /// Validate the chosen home and each effective parent. Never chmod existing directories.
    /// Missing parents are created only during an explicit install, with private permissions.
    static func validateParents(of file: URL, home: URL, create: Bool = false) throws {
        guard home.isFileURL, file.isFileURL, home.path != "/", file.path.hasPrefix(home.path + "/") else {
            throw CLIInstaller.Failure.unsafePath
        }
        let fm = FileManager.default
        let relative = file.deletingLastPathComponent().path.dropFirst(home.path.count)
        var directory = home
        for component in [""] + relative.split(separator: "/").map(String.init) {
            if !component.isEmpty { directory.appendPathComponent(component) }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: directory.resolvingSymlinksInPath().path) }
            catch CocoaError.fileReadNoSuchFile {
                // A dangling directory symlink is a conflict, not a missing directory.
                let unresolved: [FileAttributeKey: Any]?
                do { unresolved = try fm.attributesOfItem(atPath: directory.path) }
                catch CocoaError.fileReadNoSuchFile { unresolved = nil }
                if unresolved?[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw CLIInstaller.Failure.unsafePath
                }
                guard create, directory.path != home.path else {
                    if directory.path == home.path { throw CLIInstaller.Failure.unsafePath }
                    return
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                attributes = try fm.attributesOfItem(atPath: directory.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else {
                throw CLIInstaller.Failure.unsafePath
            }
        }
    }

    /// Reads only regular, user-owned files. A .zshrc link may be followed explicitly;
    /// broken/cyclic links, directories and foreign dedicated files are errors.
    static func contents(at file: URL, followingDotfileLink: Bool = false) throws -> Data? {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: file.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink && !followingDotfileLink { throw CLIInstaller.Failure.foreignFile }
        let target = type == .typeSymbolicLink ? file.resolvingSymlinksInPath() : file
        let resolved = try fm.attributesOfItem(atPath: target.path)
        guard resolved[.type] as? FileAttributeType == .typeRegular,
              (resolved[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let mode = resolved[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else { throw CLIInstaller.Failure.unsafePath }
        return try Data(contentsOf: target)
    }

    /// Exclusivity preserves even dangling destination links; permissions apply only to new files.
    static func create(_ data: Data, at file: URL, permissions: Int) throws {
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }

    /// Update the existing inode so symlinks, hardlinks, permissions and dotfile repo tracking
    /// survive. Detect intervening edits before writing; all write/flush/close errors propagate.
    static func editDotfile(_ file: URL, original: Data?, replacement: Data) throws {
        guard original != replacement else { return }
        guard let original else {
            try create(replacement, at: file, permissions: 0o600)
            return
        }
        let handle = try FileHandle(forUpdating: file)
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { throw CLIInstaller.Failure.unsafePath }
        guard try (handle.readToEnd() ?? Data()) == original else { throw CLIInstaller.Failure.foreignFile }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.truncate(atOffset: UInt64(replacement.count))
        try handle.synchronize()
        try handle.close()
    }
}
