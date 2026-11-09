//
//  DevShellActivity.swift
//  FunNotch
//
//  "Shell activity": when a terminal command that ran longer than N seconds
//  finishes, the notch says so. It works by appending a delimited block to
//  ~/.zshrc that hooks zsh's `preexec` and `precmd` and tells the local API.
//
//  The hook is built to be invisible:
//  - nothing happens for short commands, and nothing is printed, ever;
//  - the curl runs in a disowned background subshell with a 1 s limit, so the
//    prompt never waits for it, and it fails quietly when the API is off;
//  - the token is not in the file. The hook reads it from the Keychain at run
//    time, so the dotfile can be committed to a dotfiles repo without leaking.
//
//  Only the command's name is sent, never its arguments.
//

import Foundation

enum DevShellActivity {
    static let beginMarker = "# >>> Fun Notch: długie komendy >>>"
    static let endMarker = "# <<< Fun Notch: długie komendy <<<"
    static let minimumSecondsKey = "extras.dev.shell.minSeconds"
    static let defaultMinimumSeconds = 10

    /// Resolved through symlinks, so a dotfiles-managed ~/.zshrc is edited in
    /// place instead of being replaced by a regular file.
    private static var zshrc: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc")
            .resolvingSymlinksInPath()
    }

    private static var backup: URL {
        zshrc.deletingLastPathComponent().appendingPathComponent(".zshrc.funnotch-backup")
    }

    static var minimumSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: minimumSecondsKey)
            return stored > 0 ? stored : defaultMinimumSeconds
        }
        set { UserDefaults.standard.set(newValue, forKey: minimumSecondsKey) }
    }

    static var isInstalled: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(beginMarker) ?? false
    }

    /// Writes the block, replacing an older one if present.
    static func install(minimumSeconds: Int) throws {
        // A read failure must not look like an empty file, or the install would
        // replace the user's .zshrc without a backup. It surfaces as an error.
        let current = FileManager.default.fileExists(atPath: zshrc.path)
            ? try String(contentsOf: zshrc, encoding: .utf8)
            : ""
        // One copy of the user's original, taken before the first change.
        if !FileManager.default.fileExists(atPath: backup.path), !current.isEmpty {
            try current.write(to: backup, atomically: true, encoding: .utf8)
        }
        var body = strip(current)
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        if !body.isEmpty { body += "\n" }
        body += block(minimumSeconds: minimumSeconds)
        try body.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// Takes the block out again, along with the blank line it came with.
    static func remove() throws {
        guard let current = try? String(contentsOf: zshrc, encoding: .utf8), current.contains(beginMarker) else { return }
        try strip(current).write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// `text` without the managed block (and the blank line before it).
    static func strip(_ text: String) -> String {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: begin.upperBound ..< text.endIndex)
        else { return text }
        var head = String(text[..<begin.lowerBound])
        var tail = String(text[end.upperBound...])
        if tail.hasPrefix("\n") { tail.removeFirst() }
        // `install` added exactly one blank line before the block.
        if head.hasSuffix("\n\n") { head.removeLast() }
        return head + tail
    }

    static func block(minimumSeconds: Int) -> String {
        """
        \(beginMarker)
        # Zarządzane przez Fun Notch (Ustawienia > Dodatki > Terminal). Wyłącz tam
        # funkcję albo usuń cały ten blok, żeby przestała działać.
        if [[ -o interactive && -z "$FUNNOTCH_HOOK_LOADED" ]]; then
          FUNNOTCH_HOOK_LOADED=1
          zmodload zsh/datetime 2>/dev/null
          : ${FUNNOTCH_MIN_SECONDS:=\(minimumSeconds)}
          typeset -g _funnotch_cmd="" _funnotch_start=0
          _funnotch_preexec() { _funnotch_cmd=$1; _funnotch_start=$EPOCHSECONDS }
          _funnotch_precmd() {
            local code=$?
            [[ -n $_funnotch_cmd ]] || return 0
            local cmd=$_funnotch_cmd elapsed=$(( EPOCHSECONDS - _funnotch_start ))
            _funnotch_cmd=""
            (( elapsed >= FUNNOTCH_MIN_SECONDS )) || return 0
            # Ctrl-C is the user's own decision, not news.
            (( code == 130 )) && return 0
            local name="" word
            for word in ${(z)cmd}; do
              [[ $word == *=* || $word == (sudo|time|noglob|nocorrect|command|builtin|exec) ]] && continue
              name=${word:t}
              break
            done
            [[ -n $name ]] || return 0
            # Interactive programs end when you leave them; that is not a result.
            case $name in
              vim|nvim|vi|nano|emacs|less|more|man|top|htop|btop|ssh|mosh|tmux|screen|watch|tail|fzf|lazygit|omp|claude|codex) return 0 ;;
            esac
            local took
            if (( elapsed >= 3600 )); then took="$(( elapsed / 3600 )) godz. $(( elapsed % 3600 / 60 )) min"
            elif (( elapsed >= 60 )); then took="$(( elapsed / 60 )) min $(( elapsed % 60 )) s"
            else took="${elapsed} s"; fi
            local esc=${name//\\\\/\\\\\\\\}
            esc=${esc//\\"/\\\\\\"}
            esc=${esc//[[:cntrl:]]/ }
            esc=${esc[1,40]}
            local json
            if (( code == 0 )); then
              json="{\\"title\\":\\"$esc\\",\\"detail\\":\\"zakończone po $took\\",\\"symbol\\":\\"checkmark.circle.fill\\",\\"tint\\":\\"#34C759\\",\\"duration\\":4}"
            else
              json="{\\"title\\":\\"$esc\\",\\"detail\\":\\"błąd (kod $code) po $took\\",\\"symbol\\":\\"xmark.octagon.fill\\",\\"tint\\":\\"#FF453A\\",\\"duration\\":6}"
            fi
            # Disowned, so the prompt neither waits for it nor prints a job line.
            (
              local token
              token=$(/usr/bin/security find-generic-password -s \(LocalAPIToken.service) -a \(LocalAPIToken.account) -w 2>/dev/null) || exit 0
              [[ -n $token ]] || exit 0
              /usr/bin/curl -s -m 1 -o /dev/null -X POST \\
                -H "Authorization: Bearer $token" -H "Content-Type: application/json" \\
                -d "$json" http://127.0.0.1:\(LocalAPIManager.port)/island >/dev/null 2>&1
            ) &!
          }
          preexec_functions+=(_funnotch_preexec)
          precmd_functions=(_funnotch_precmd $precmd_functions)
        fi
        \(endMarker)

        """
    }
}
