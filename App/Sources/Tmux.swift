import AppKit
import Foundation

/// tmux holds an agent's session in a server of its own, so the agent outlives this app:
/// quit, rebuild, come back, and the same session is there to attach to.
///
/// The person should never see tmux. It runs on a socket of its own so it never meets
/// their own sessions, with a config of ours so their `.tmux.conf` does not apply, and
/// that config turns off everything that would give it away: no status bar, no prefix
/// key. Titles and BEL still reach the outer terminal, so the factory can put the
/// agent's title on its card and ring when it wants a look. What is left is a
/// terminal that happens to survive.
/// (Alex, 12 Sep 2026: zmux first, which wedged; tmux instead.)
enum Tmux {
    /// Our own server. Nothing here shares a socket with the person's own tmux.
    static let server = "softwarefactory"

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(NSHomeDirectory())/.local/bin"]

    static var binary: String? {
        searchPaths.lazy.map { "\($0)/tmux" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binary != nil }

    /// Installed and asked for.
    static var isOn: Bool {
        // Unset means on, the same as the switch in Settings reads it.
        isInstalled && (UserDefaults.standard.object(forKey: AppModel.usesTmuxKey) as? Bool ?? true)
    }

    /// Everything that would tell the person they are in tmux, turned off.
    static let config = """
    # Written by Taktu: Software Factory. The person is meant to see a terminal, not tmux.
    set -g status off
    set -g prefix None
    unbind-key -a
    set -g mouse off
    set -g escape-time 0
    set -g history-limit 100000
    setw -g automatic-rename off
    setw -g allow-rename on
    set -g set-titles on
    set -g set-titles-string '#T'
    set -g visual-bell off
    set -g visual-activity off
    set -g monitor-activity off
    set -g monitor-bell on
    set -g bell-action current
    set -g destroy-unattached off
    set -g exit-empty off
    # The pane stays after its agent exits, so its last words are still readable and the
    # window is still there to pick back up. (T-session, 13 Sep 2026.)
    set -g remain-on-exit on
    set -g default-terminal "xterm-256color"
    set -ga terminal-overrides ",xterm-256color:Tc"
    setw -g aggressive-resize on
    """

    /// Where that config lives, written fresh each launch so a change here reaches every
    /// session made afterwards.
    static var configPath: String {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/state/software-factory", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "tmux.conf")
        try? config.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// The line our terminal runs: make the session and attach, or attach to the one
    /// that is already there. The same line serves a launch and a reattach, which is why
    /// nothing else has to remember which is which.
    ///
    /// `exec`, so the pane's process is the agent itself rather than a shell holding it.
    /// That is what lets the factory know the agent's pid the moment it starts it, and
    /// an agent whose pid the factory already has has nothing left to register.
    /// The shell that used to sit there was only keeping the window open after the agent
    /// exited, and `remain-on-exit on` does that better: the pane stays, and tmux says
    /// outright that it is dead.
    ///
    /// SOFTWARE_FACTORY_SESSION is gone with it. The session is in the words the agent
    /// starts with, which survive a resume; an environment variable does not.
    /// (T-session, 13 Sep 2026.)
    static func command(session: String, running command: String, in folder: String?) -> String? {
        guard let binary, isOn else { return nil }
        let place = folder.map { " -c \(AppModel.quoted($0))" } ?? ""
        return "\(base(binary)) new-session -A -s \(AppModel.quoted(session))\(place) \(AppModel.quoted("exec \(command)"))"
    }

    /// The process running in a session's pane, which with `exec` is the agent itself.
    /// Never call this from the main thread: it runs tmux.
    static func panePID(session: String) -> Int32? {
        guard let binary, isOn else { return nil }
        guard let out = run(binary, ["-L", server, "list-panes", "-t", session, "-F", "#{pane_pid}"]),
              out.status == 0 else { return nil }
        return Int32(out.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Attaches to a session that is already there, for an agent whose terminal this app
    /// has lost: it quit, the session kept working. It does not ask tmux whether the
    /// session is there, because running tmux from the main thread is what beachballs;
    /// the caller checks against TerminalSessions.held, which is kept fresh off it.
    /// (Alex, 13 Sep 2026.)
    static func attachCommand(session: String) -> String? {
        guard let binary, isOn else { return nil }
        return "\(base(binary)) attach-session -t \(AppModel.quoted(session))"
    }

    static func has(_ session: String) -> Bool {
        guard let binary, isInstalled else { return false }
        return run(binary, ["-L", server, "has-session", "-t", session])?.status == 0
    }

    /// Picks up a config written after this server started, so titles and BEL reach
    /// sessions that have been running since before the change.
    static func reloadConfig() {
        guard let binary, isInstalled else { return }
        _ = run(binary, ["-L", server, "source-file", configPath])
    }

    /// The sessions this app's server is holding, by name.
    static func sessions() -> [String] {
        guard let binary, isInstalled else { return [] }
        guard let out = run(binary, ["-L", server, "list-sessions", "-F", "#{session_name}"]), out.status == 0
        else { return [] }
        return out.text.split(separator: "\n").map(String.init)
    }

    /// Ends a session and whatever is running in it.
    static func kill(_ session: String) {
        guard let binary, isInstalled else { return }
        _ = run(binary, ["-L", server, "kill-session", "-t", session])
    }

    /// Whether the server is up at all. Nothing needs starting by hand: the first
    /// new-session starts it.
    static var isRunning: Bool { !sessions().isEmpty || has("") == false && serverAnswers }

    private static var serverAnswers: Bool {
        guard let binary else { return false }
        return run(binary, ["-L", server, "list-sessions"])?.status == 0
    }

    private static func base(_ binary: String) -> String {
        "\(binary) -L \(server) -f \(AppModel.quoted(configPath))"
    }

    /// Never call this from the main thread: it waits for tmux to answer, and a tmux
    /// server that has wedged waits for ever. The timeout means the caller gets nothing
    /// back instead of hanging behind it. (Alex, 13 Sep 2026: the beachball came from
    /// here.)
    @discardableResult
    private static func run(_ binary: String, _ arguments: [String],
                            timeout: TimeInterval = 3) -> (status: Int32, text: String)? {
        let task = Process()
        task.executableURL = URL(filePath: binary)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        nonisolated(unsafe) let running = task
        let giveUp = DispatchWorkItem { if running.isRunning { running.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: giveUp)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        giveUp.cancel()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Installing it

    static let installScript = """
    set -e
    if ! command -v brew >/dev/null; then
      echo "Homebrew is not installed. See https://brew.sh, then run: brew install tmux"
      exit 1
    fi
    brew install tmux
    echo
    echo "Done. Agents you launch can now keep working when Software Factory quits."
    """

    /// Opens a Terminal window running the install, so the person sees it happen.
    static func install() throws {
        let folder = URL.cachesDirectory.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "install-tmux.command")
        try "#!/bin/zsh\n\(installScript)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}
