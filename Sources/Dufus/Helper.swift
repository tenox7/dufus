import Foundation
import Security

/// Optional setuid-root disk helper (Sources/DufusHelper).
/// When installed, disks open without the admin password prompt.
enum Helper {
    static let installedPath = "/Library/PrivilegedHelperTools/com.github.tenox7.dufus.helper"

    static var isInstalled: Bool {
        var st = stat()
        return lstat(installedPath, &st) == 0 && st.st_uid == 0 && st.st_mode & S_ISUID != 0
    }

    /// Copies the helper from the app bundle and makes it setuid root. Returns an error message or nil.
    static func install() -> String? {
        guard let src = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("DufusHelper").path,
              FileManager.default.isExecutableFile(atPath: src) else {
            return "Helper is missing from the app"
        }
        guard let team = teamID() else { return "Helper needs a signed release build" }
        // As root: copy to a temp file, verify its signature, then make it setuid and move it in place.
        let script = """
            set -e
            tmp=$(/usr/bin/mktemp "$2.XXXXXX")
            trap '/bin/rm -f "$tmp"' EXIT
            /bin/cat "$1" > "$tmp"
            /usr/sbin/chown root:wheel "$tmp"
            /bin/chmod 755 "$tmp"
            /usr/bin/codesign --verify --strict -R "=identifier \\"com.github.tenox7.dufus.helper\\" and anchor apple generic and certificate leaf[subject.OU] = \\"$3\\"" "$tmp"
            /bin/chmod 4755 "$tmp"
            /bin/mv -f "$tmp" "$2"
            """
        return runAsAdmin(script, args: [src, installedPath, team],
                          prompt: "Dufus wants to install a disk helper, so writes no longer ask for a password.")
    }

    static func uninstall() -> String? {
        runAsAdmin("/bin/rm -f \"$1\"", args: [installedPath], prompt: "Dufus wants to remove its disk helper.")
    }

    private static func teamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Runs `script` with /bin/sh as root after the system admin prompt. `args` become $1, $2, …
    private static func runAsAdmin(_ script: String, args: [String], prompt: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [
            "-e", "on run argv",
            "-e", "set cmd to \"/bin/sh -c \" & quoted form of item 1 of argv & \" sh\"",
            "-e", "repeat with a in rest of argv",
            "-e", "set cmd to cmd & \" \" & quoted form of (a as text)",
            "-e", "end repeat",
            "-e", "do shell script cmd with prompt \"\(prompt)\" with administrator privileges",
            "-e", "end run",
            script,
        ] + args
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch { return error.localizedDescription }
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return nil }
        if err.contains("(-128)") { return "Cancelled" }
        return err.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
