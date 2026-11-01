import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import SwiftData

/// An SSH machine the user added: their Mac, a Linux box, a Raspberry Pi, reachable over the LAN or Tailscale.
@Model
final class SSHHostRecord {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var usesPassword: Bool = false
    /// SHA256 fingerprint of the host key the user chose to trust.
    var trustedFingerprint: String = ""
    var workingDirectory: String = "~"
    var shell: String = "zsh"
    /// Lets Claude Code / Codex edit files without asking (otherwise Claude runs in read-only plan mode).
    var allowRemoteEdits: Bool = false
    var createdAt: Date = Date.now
    var group: String = ""
    var tagsRaw: String = ""
    var isFavorite: Bool = false
    var notes: String = ""
    var keyIDString: String = ""
    var jumpHostIDString: String = ""
    var lastConnected: Date?
    var themeName: String = TerminalTheme.all[0].name

    init(name: String, host: String, username: String) {
        self.name = name
        self.host = host
        self.username = username
    }

    var keyAccount: String { "ssh.\(id.uuidString).key" }
    var passwordAccount: String { "ssh.\(id.uuidString).password" }
    var tags: [String] { tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    /// Where the private key lives: a shared key from the key manager, or a key made just for this machine.
    var activeKeyAccount: String { keyIDString.isEmpty ? keyAccount : "sshkey.\(keyIDString)" }

    var snapshot: SSHHostSnapshot { snapshot(jump: nil) }

    func snapshot(jump: SSHHostRecord?) -> SSHHostSnapshot {
        SSHHostSnapshot(id: id, name: name, host: host, port: port, username: username, usesPassword: usesPassword,
                        trustedFingerprint: trustedFingerprint, workingDirectory: workingDirectory, shell: shell,
                        allowRemoteEdits: allowRemoteEdits, keyAccount: activeKeyAccount, passwordAccount: passwordAccount,
                        jump: jump.map { [$0.snapshot] } ?? [])
    }
}

struct SSHHostSnapshot: Sendable {
    let id: UUID, name: String, host: String, port: Int, username: String, usesPassword: Bool
    let trustedFingerprint: String, workingDirectory: String, shell: String, allowRemoteEdits: Bool
    let keyAccount: String, passwordAccount: String
    /// Zero or one jump host (ProxyJump) to go through first.
    var jump: [SSHHostSnapshot] = []
}

enum SSHFailure: LocalizedError {
    case notTrusted, hostKeyChanged(String), noCredentials
    var errorDescription: String? {
        switch self {
        case .notTrusted: "This machine hasn't been trusted yet. Open it in Settings and tap “Check connection and trust”."
        case .hostKeyChanged(let fp): "The machine's identity changed (\(fp)). That can mean someone is intercepting the connection. Remove and re-add the machine if you expected this."
        case .noCredentials: "No key or password is saved for this machine."
        }
    }
}

enum SSHService {
    // MARK: Keys and fingerprints

    /// Makes a new Ed25519 key for this machine, stores it on this iPad only, and returns the line to put in ~/.ssh/authorized_keys.
    static func generateKey(account: String) -> String {
        let key = Curve25519.Signing.PrivateKey()
        guard Keychain.set(key.rawRepresentation.base64EncodedString(), for: account, synchronizable: false, requireUserPresence: UserDefaults.standard.object(forKey: Prefs.protectKeys) as? Bool ?? true) else { return "" }   // e.g. no passcode set
        return publicLine(for: key)
    }

    /// Imports an unencrypted or passphrase-protected OpenSSH Ed25519 private key.
    static func importKey(openSSH text: String, passphrase: String?, account: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) })
        guard Keychain.set(key.rawRepresentation.base64EncodedString(), for: account, synchronizable: false, requireUserPresence: UserDefaults.standard.object(forKey: Prefs.protectKeys) as? Bool ?? true) else { throw SSHFailure.noCredentials }
        return publicLine(for: key)
    }

    static func publicKeyLine(account: String) -> String? {
        guard Keychain.exists(account), let raw = Keychain.get(account), let data = Data(base64Encoded: raw), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return publicLine(for: key)
    }

    private static func publicLine(for key: Curve25519.Signing.PrivateKey) -> String {
        func field(_ bytes: [UInt8]) -> [UInt8] { withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) } + bytes }
        let blob = field(Array("ssh-ed25519".utf8)) + field(Array(key.publicKey.rawRepresentation))
        return "ssh-ed25519 \(Data(blob).base64EncodedString()) PanthAI"
    }

    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        let line = String(openSSHPublicKey: key)
        guard let b64 = line.split(separator: " ").dropFirst().first, let blob = Data(base64Encoded: String(b64)) else { return line }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
        let trusted: String
        /// Probe mode: record the key, then fail the handshake so no credentials are ever sent to an unverified machine.
        let abortAfterCapture: Bool
        private let lock = NSLock()
        private var _seen = ""
        var seen: String { lock.withLock { _seen } }
        init(trusted: String, abortAfterCapture: Bool = false) { self.trusted = trusted; self.abortAfterCapture = abortAfterCapture }
        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            let fp = SSHService.fingerprint(of: hostKey)
            lock.withLock { _seen = fp }
            if abortAfterCapture { validationCompletePromise.fail(SSHFailure.notTrusted); return }
            if trusted.isEmpty || trusted == fp { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(SSHFailure.hostKeyChanged(fp)) }
        }
    }

    // MARK: Connecting

    private static func authentication(_ host: SSHHostSnapshot) throws -> SSHAuthenticationMethod {
        if host.usesPassword {
            guard let password = Keychain.get(host.passwordAccount) else { throw SSHFailure.noCredentials }
            return .passwordBased(username: host.username, password: password)
        }
        guard let raw = Keychain.get(host.keyAccount), let data = Data(base64Encoded: raw),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { throw SSHFailure.noCredentials }
        return .ed25519(username: host.username, privateKey: key)
    }

    /// Reads the machine's host key fingerprint without logging in. The handshake is aborted as soon as the key is seen,
    /// so a machine that is impersonating the real one never receives a password or key signature.
    static func probe(_ host: SSHHostSnapshot) async throws -> String {
        let check = HostKeyCheck(trusted: "", abortAfterCapture: true)
        let placeholder = SSHAuthenticationMethod.passwordBased(username: host.username, password: "")   // never sent: the handshake stops first
        do {
            if let jump = host.jump.first {
                let jumpClient = try await connect(jump)
                nonisolated(unsafe) let method = placeholder
                _ = try await jumpClient.jump(to: SSHClientSettings(host: host.host, port: host.port, authenticationMethod: { method }, hostKeyValidator: .custom(check)))
            } else {
                _ = try await SSHClient.connect(host: host.host, port: host.port, authenticationMethod: placeholder, hostKeyValidator: .custom(check), reconnect: .never)
            }
        } catch {
            if !check.seen.isEmpty { return check.seen }
            throw error
        }
        return check.seen
    }

    static func connect(_ host: SSHHostSnapshot) async throws -> SSHClient {
        guard !host.trustedFingerprint.isEmpty else { throw SSHFailure.notTrusted }
        let validator = SSHHostKeyValidator.custom(HostKeyCheck(trusted: host.trustedFingerprint))
        if let jump = host.jump.first {
            let jumpClient = try await connect(jump)
            nonisolated(unsafe) let method = try authentication(host)
            return try await jumpClient.jump(to: SSHClientSettings(host: host.host, port: host.port, authenticationMethod: { method }, hostKeyValidator: validator))
        }
        return try await SSHClient.connect(host: host.host, port: host.port, authenticationMethod: try authentication(host), hostKeyValidator: validator, reconnect: .never)
    }

    // MARK: Running commands

    /// Citadel's client isn't Sendable; closing it from a detached task goes through this box.
    private final class ClientBox: @unchecked Sendable { let client: SSHClient; init(_ c: SSHClient) { client = c } }
    static func closeLater(_ client: SSHClient) { let box = ClientBox(client); Task { try? await box.client.close() } }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a command in a login shell (so PATH from the user's profile applies) and streams its output.
    static func stream(_ host: SSHHostSnapshot, command: String, directory: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await connect(host)
                    defer { closeLater(client) }
                    let dir = directory ?? host.workingDirectory
                    let cd = dir == "~" || dir.isEmpty ? "" : "cd \(quote(dir)) && "
                    let full = "\(host.shell) -lc \(quote(cd + command))"
                    for try await event in try await client.executeCommandStream(full) {
                        switch event {
                        case .stdout(let buffer): continuation.yield(String(buffer: buffer))
                        case .stderr(let buffer): continuation.yield(String(buffer: buffer))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func run(_ host: SSHHostSnapshot, command: String, limit: Int = 12_000) async throws -> String {
        var out = ""
        for try await piece in stream(host, command: command) { out += piece; if out.count > limit { out = String(out.prefix(limit)) + "\n… (output truncated)"; break } }
        return out.isEmpty ? "(no output)" : out
    }

    // MARK: SFTP

    struct RemoteItem: Identifiable, Sendable { let id = UUID(); let name: String; let isDirectory: Bool; let size: UInt64? }

    static func list(_ host: SSHHostSnapshot, path: String) async throws -> (resolved: String, items: [RemoteItem]) {
        let client = try await connect(host)
        defer { closeLater(client) }
        let sftp = try await client.openSFTP()
        let resolved = try await sftp.getRealPath(atPath: path.isEmpty ? "." : path)
        let names = try await sftp.listDirectory(atPath: resolved)
        let items = names.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }.map {
            RemoteItem(name: $0.filename, isDirectory: ($0.attributes.permissions ?? 0) & 0o170000 == 0o040000, size: $0.attributes.size)
        }
        return (resolved, items.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) })
    }

    static func read(_ host: SSHHostSnapshot, path: String, limit: Int = 400_000) async throws -> Data {
        let client = try await connect(host)
        defer { closeLater(client) }
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile(filePath: path, flags: .read)
        var buffer = try await file.read(from: 0, length: UInt32(limit))
        try? await file.close()
        return buffer.readData(length: buffer.readableBytes) ?? Data()
    }
}

extension SSHService {
    static func write(_ host: SSHHostSnapshot, path: String, data: Data) async throws {
        let client = try await connect(host)
        defer { closeLater(client) }
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        try await file.write(ByteBuffer(data: data), at: 0)
        try? await file.close()
    }

    static func rename(_ host: SSHHostSnapshot, from: String, to: String) async throws {
        let client = try await connect(host)
        defer { closeLater(client) }
        try await client.openSFTP().rename(at: from, to: to)
    }

    static func remove(_ host: SSHHostSnapshot, path: String, isDirectory: Bool) async throws {
        let client = try await connect(host)
        defer { closeLater(client) }
        let sftp = try await client.openSFTP()
        if isDirectory { try await sftp.rmdir(at: path) } else { try await sftp.remove(at: path) }
    }

    static func makeDirectory(_ host: SSHHostSnapshot, path: String) async throws {
        let client = try await connect(host)
        defer { closeLater(client) }
        try await client.openSFTP().createDirectory(atPath: path)
    }
}

/// Commands that would damage the machine are refused even if the user approves, because a model chose them.
enum RemoteCommandGuard {
    static func problem(with command: String) -> String? {
        let lower = command.lowercased()
        let banned = ["rm -rf /", "rm -rf ~", "rm -rf *", "mkfs", "dd if=", "dd of=/dev", ":(){", "shutdown", "reboot", "halt", "poweroff", "> /dev/sd", "chmod -r 777 /", "chown -r", "diskutil erase", "format "]
        if let hit = banned.first(where: { lower.contains($0) }) { return "Refused: “\(hit)” could damage the machine. Run it yourself from the Terminal if you really mean it." }
        return nil
    }
}
