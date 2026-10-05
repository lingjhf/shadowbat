import Foundation
import Darwin

@MainActor
enum TerminalProxyChecks {
    static func shell(_ command: String, arguments: [String] = [], environment: [String: String] = [:], input: String? = nil) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = input == nil ? ["-fic", command, "shadowbat-check"] + arguments : ["-fi"]
        var clean = ProcessInfo.processInfo.environment
        for key in clean.keys where key.lowercased().hasSuffix("_proxy") || key.hasPrefix("_SHADOWBAT_") {
            clean.removeValue(forKey: key)
        }
        clean.merge(environment) { _, value in value }
        process.environment = clean
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        try process.run()
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try SmokeChecks.check(process.terminationStatus == 0,
                              "Terminal integration failed: \(String(decoding: data, as: UTF8.self).prefix(3000))")
    }

    static func run(directory: URL, resource: URL) throws -> TerminalProxyManager {
        let folder = directory.appendingPathComponent("terminal's checks with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rc = folder.appendingPathComponent(".zshrc")
        let original = "# keep my configuration\nexport CUSTOM_SETTING='unchanged'\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: rc.path)
        let manager = TerminalProxyManager(directory: folder, zshrc: rc, resource: resource)
        let backup = try manager.install()
        guard let backup else { throw ClientError.message("Missing shell backup") }
        let saved = try String(contentsOf: backup, encoding: .utf8)
        try SmokeChecks.check(saved == original, "Shell backup did not preserve content")
        let permissions = try FileManager.default.attributesOfItem(atPath: rc.path)[.posixPermissions] as? Int
        try SmokeChecks.check(permissions == 0o640, "Shell startup file permissions changed")
        let repeated = try manager.install()
        try SmokeChecks.check(repeated == nil && manager.isInstalled, "Repeated install changed startup file")
        try manager.enable(ports: LocalPorts(), corePID: getpid())
        let statePermissions = try FileManager.default.attributesOfItem(atPath: manager.stateFile.path)[.posixPermissions] as? Int
        try SmokeChecks.check(statePermissions == 0o600, "Terminal state permissions are unsafe")
        try manager.disable()
        // Input mode exercises actual interactive prompt/command hooks, not direct calls.
        try shell("", environment: ["SHADOWBAT_CHECK_SCRIPT": manager.script.path,
                                    "SHADOWBAT_CHECK_STATE": manager.stateFile.path,
                                    "NO_PROXY": "keep.example"], input: #"""
            PROMPT=''; RPROMPT=''
            source "$SHADOWBAT_CHECK_SCRIPT"
            printf '1\n%s\n%s\n1087\n1081\n' $$ $$ > "$SHADOWBAT_CHECK_STATE"
            [[ $https_proxy == http://127.0.0.1:1087 && $no_proxy == keep.example,localhost,127.0.0.1,::1 ]] || exit 1
            /bin/rm "$SHADOWBAT_CHECK_STATE"
            [[ ${+https_proxy} == 0 && ${+no_proxy} == 0 && $NO_PROXY == keep.example ]] || exit 1
            exit 0
            """# + "\n")
        try shell(#"""
            function eq { [[ "$1" == "$2" ]] || { print -u2 -- "Mismatch: $3 ($1 != $2)"; exit 1; }; }
            typeset http_proxy='original unexported value'
            export https_proxy='https://original.example:9'
            export HTTPS_PROXY=''
            export no_proxy='private.example'
            export NO_PROXY='upper.example'
            printf '1\n%s\n%s\n1087\n1081\n' $$ $$ > "$2"
            source "$1"
            eq "$http_proxy" http://127.0.0.1:1087 HTTP
            eq "$all_proxy" socks5h://127.0.0.1:1081 SOCKS
            eq "$no_proxy" 'private.example,localhost,127.0.0.1,::1' bypass
            eq "$NO_PROXY" 'upper.example,localhost,127.0.0.1,::1' uppercase-bypass
            # Re-sourcing must not duplicate hooks or replace the original snapshot.
            source "$1"
            eq "${#preexec_functions}" 1 preexec-count
            eq "${#precmd_functions}" 1 precmd-count
            # A nested shell inherits the original snapshot, not just the proxy URLs.
            /bin/zsh -fic 'source "$1"; /bin/rm "$2"; __shadowbat_sync; [[ $http_proxy == "original unexported value" && $https_proxy == https://original.example:9 && ${+ALL_PROXY} == 0 && ${+HTTPS_PROXY} == 1 && -z $HTTPS_PROXY ]]' child "$1" "$2" || exit 1
            __shadowbat_sync
            eq "$http_proxy" 'original unexported value' restore-local
            [[ ${parameters[http_proxy]} != *export* ]] || exit 1
            eq "$https_proxy" https://original.example:9 restore-export
            [[ ${parameters[https_proxy]} == *export* ]] || exit 1
            [[ ${+all_proxy} == 0 && ${+HTTP_PROXY} == 0 && ${+HTTPS_PROXY} == 1 && -z $HTTPS_PROXY ]] || exit 1
            eq "$no_proxy" private.example restore-bypass
            eq "$NO_PROXY" upper.example restore-uppercase-bypass
            # Hooks run before a command, and preserve later manual changes on disable.
            printf '1\n%s\n%s\n2087\n2081\n' $$ $$ > "$2"
            for hook in $preexec_functions; do "$hook"; done
            eq "$http_proxy" http://127.0.0.1:2087 changed-port
            export https_proxy='manual override'
            unset ALL_PROXY
            /bin/rm "$2"
            for hook in $precmd_functions; do "$hook"; done
            eq "$https_proxy" 'manual override' preserve-edit
            [[ ${+ALL_PROXY} == 0 && ${+_SHADOWBAT_SESSION} == 0 ]] || exit 1
            # Inherited snapshots must be restored even when starting after disable.
            printf '1\n%s\n%s\n1087\n1081\n' $$ $$ > "$2"
            __shadowbat_sync
            /bin/rm "$2"
            /bin/zsh -fic 'source "$1"; [[ $https_proxy == "manual override" && ${+ALL_PROXY} == 0 && ${+_SHADOWBAT_SESSION} == 0 ]]' child "$1" || exit 1
            __shadowbat_sync
            # Corrupt state is never executable; a dead process also restores variables.
            printf '1\n%s\n%s\n1087\n1081\n' $$ $$ > "$2"
            __shadowbat_sync
            printf '1\n99999999\n%s\n1087\n1081\n' $$ > "$2"
            __shadowbat_sync
            eq "$http_proxy" 'original unexported value' dead-process
            print -r -- '$(touch "$3")' > "$2"
            __shadowbat_sync
            [[ ! -e $3 && -z $__shadowbat_session ]] || exit 1
            # Exercise the generated .zshrc loader, including quotes in paths.
            source "$4"
            eq "$CUSTOM_SETTING" unchanged preserved-startup
            """#, arguments: [manager.script.path, manager.stateFile.path, folder.appendingPathComponent("must-not-exist").path, rc.path])
        try manager.disable()
        let malformed = original + "# >>> Shadowbat terminal proxy >>>\n"
        try malformed.write(to: rc, atomically: true, encoding: .utf8)
        try SmokeChecks.mustThrow("Malformed integration markers were overwritten") { try manager.install() }
        let afterFailure = try String(contentsOf: rc, encoding: .utf8)
        try SmokeChecks.check(afterFailure == malformed, "Malformed startup file was modified")
        try (try String(contentsOf: backup, encoding: .utf8)).write(to: rc, atomically: true, encoding: .utf8)
        try manager.install()
        print("PASS: terminal installation, backups, hooks, nested shells, environment restoration, manual edits, crash state")
        return manager
    }

    static func request(manager: TerminalProxyManager, corePID: Int32, ports: LocalPorts, url: String) throws {
        try manager.enable(ports: ports, corePID: corePID)
        defer { try? manager.disable() }
        // The hostname only resolves at the Shadowsocks server; curl has no explicit proxy flags.
        try shell(#"""
            source "$1"
            response=$(/usr/bin/curl --silent --show-error --fail --max-time 5 "$2") || exit 1
            [[ $response == shadowbat-test-response ]] || exit 1
            # Fall back to ALL_PROXY for SOCKS, still without curl proxy flags.
            unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
            response=$(/usr/bin/curl --silent --show-error --fail --max-time 5 "$2") || exit 1
            [[ $response == shadowbat-test-response ]] || exit 1
            """#, arguments: [manager.script.path, url])
        print("PASS: curl uses terminal HTTP and SOCKS environment through encrypted proxy")
    }
}
