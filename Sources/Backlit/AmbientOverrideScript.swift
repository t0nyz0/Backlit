import Foundation

/// The only thing Backlit runs with administrator rights.
///
/// It used to be the app's own executable, started as root. That file lives in
/// Applications, where the user account can change it, so root would run
/// whatever was on disk at that moment. This is instead a fixed shell script,
/// built in memory, that calls only system tools by absolute path. Nothing the
/// user account can write is executed or trusted as root.
///
/// What it does is unchanged: save the two ambient brightness limits once,
/// replace them with flat limits (or put the saved ones back), restart the
/// brightness service, and on restore remove the saved copy only after readback
/// confirms both original limits (including an originally absent limit).
enum AmbientOverrideScript {
    static let keys = ["LEPWMLuxToMinNitsRestrictionMapping", "LEPWMLuxToMaxNitsRestrictionMapping"]
    static let minimumNits = "12.5"
    static let maximumNits = "1000"

    // Confirm that the old service has exited, not merely that TERM was sent.
    // Reconnection may then wait for a replacement, never bind the dying daemon.
    static let serviceRestart = """
    if old_pids="$(/usr/bin/pgrep -x corebrightnessd)"; then
      :
    else
      status=$?
      [ "$status" -eq 1 ] || fail 'The brightness service could not be identified. Recovery was retained.'
      old_pids=''
    fi
    if [ -n "$old_pids" ]; then
      /usr/bin/killall -TERM corebrightnessd >/dev/null 2>&1 || fail 'The brightness service could not be restarted. Recovery was retained.'
      attempts=0
      while :; do
        alive=''
        for pid in $old_pids; do
          if /bin/kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        [ -z "$alive" ] && break
        attempts=$((attempts + 1))
        [ "$attempts" -lt 50 ] || fail 'The old brightness service has not stopped. Recovery was retained.'
        /bin/sleep 0.1
      done
    fi
    """

    /// A flat limit at every light level, as an XML property-list fragment.
    static func flatLimit(_ nits: String) -> String {
        "<array><array><real>0</real><real>\(nits)</real></array><array><real>3.4028234663852886e+38</real><real>\(nits)</real></array></array>"
    }

    private static func safe(_ value: String, _ allowed: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.unicodeScalars.contains($0) }
    }
    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    /// `directory`, `domain`, `ownerID` and `restart` have production defaults.
    /// Tests override them to run the same script without administrator rights
    /// against a temporary folder and a throwaway settings domain.
    static func make(enabled: Bool, directory: String = "/var/db/local.backlit",
                     domain: String = "com.apple.CoreBrightness", ownerID: UInt32 = 0,
                     restart: String = "/usr/bin/killall -TERM corebrightnessd") throws -> String {
        // Every interpolated value is restricted to characters that cannot
        // end a quoted shell word or start a new command.
        guard directory.hasPrefix("/"), safe(directory, letters + "/._-"), !directory.contains(".."),
              safe(domain, letters + "._-"), safe(restart, letters + "/._- "), restart.hasPrefix("/") else {
            throw RuntimeServices.failure("The brightness-limit helper was given an invalid setting.")
        }
        let header = """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        umask 077
        dir='\(directory)'
        backup="$dir/ambient.plist"
        domain='\(domain)'
        fail() { echo "$1" >&2; exit 1; }
        if [ -e "$dir" ] || [ -L "$dir" ]; then
          [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(/usr/bin/stat -f %u "$dir")" = '\(ownerID)' ] || fail 'Invalid recovery directory.'
        else
          /bin/mkdir -m 700 "$dir"
        fi
        if [ -e "$backup" ] || [ -L "$backup" ]; then
          [ -f "$backup" ] && [ ! -L "$backup" ] || fail 'Invalid recovery file.'
        fi
        work="$(/usr/bin/mktemp -d "$dir/work.XXXXXX")"
        trap '/bin/rm -rf "$work"' EXIT
        fragment() {
          value="$(/usr/bin/sed -e '1,3d' -e '$d' "$1")"
          [ -n "$value" ] || fail 'A saved brightness limit could not be read. Nothing was changed.'
          printf '%s' "$value"
        }
        """
        let restartScript = restart == "/usr/bin/killall -TERM corebrightnessd" ? Self.serviceRestart : "\(restart) >/dev/null 2>&1 || true"
        let keyList = keys.joined(separator: " ")
        let body: String
        if enabled {
            body = """
            if [ ! -e "$backup" ]; then
              /usr/bin/defaults export "$domain" "$work/current.plist"
              printf '%s\\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "$work/backup.plist"
              for key in \(keyList); do
                if /usr/bin/plutil -extract "$key" xml1 -o "$work/value.xml" "$work/current.plist" >/dev/null 2>&1; then
                  saved="$(fragment "$work/value.xml")"
                  /usr/bin/plutil -insert "$key" -xml "$saved" "$work/backup.plist"
                fi
              done
              /usr/bin/plutil -lint "$work/backup.plist" >/dev/null
              /bin/chmod 600 "$work/backup.plist"
              /bin/mv -f "$work/backup.plist" "$backup"
            fi
            /usr/bin/defaults write "$domain" \(keys[0]) '\(flatLimit(minimumNits))'
            /usr/bin/defaults write "$domain" \(keys[1]) '\(flatLimit(maximumNits))'
            \(restartScript)
            """
        } else {
            body = """
            [ -f "$backup" ] || fail 'No saved brightness limits to restore.'
            /usr/bin/plutil -lint "$backup" >/dev/null 2>&1 || fail 'The saved brightness limits are unreadable. They were left untouched.'
            for key in \(keyList); do
              if /usr/bin/plutil -extract "$key" xml1 -o "$work/value.xml" "$backup" >/dev/null 2>&1; then
                saved="$(fragment "$work/value.xml")"
                /usr/bin/defaults write "$domain" "$key" "$saved"
              else
                /usr/bin/defaults delete "$domain" "$key" >/dev/null 2>&1 || true
              fi
            done
            # A failed delete is harmless only if the key is already absent.
            # Command success alone is not enough: retain the original backup
            # until fresh readback matches every original value or absence.
            /usr/bin/defaults export "$domain" "$work/restored.plist" >/dev/null 2>&1 || fail 'The restored brightness limits could not be read. Recovery was retained.'
            /usr/bin/plutil -lint "$work/restored.plist" >/dev/null 2>&1 || fail 'The restored brightness limits are unreadable. Recovery was retained.'
            for key in \(keyList); do
              if /usr/bin/plutil -extract "$key" xml1 -o "$work/expected.xml" "$backup" >/dev/null 2>&1; then
                /usr/bin/plutil -extract "$key" xml1 -o "$work/observed.xml" "$work/restored.plist" >/dev/null 2>&1 || fail 'A restored brightness limit is missing. Recovery was retained.'
                /usr/bin/cmp -s "$work/expected.xml" "$work/observed.xml" || fail 'The restored brightness limits did not match. Recovery was retained.'
              elif /usr/bin/plutil -extract "$key" xml1 -o "$work/observed.xml" "$work/restored.plist" >/dev/null 2>&1; then
                fail 'A brightness limit that was originally absent is still present. Recovery was retained.'
              fi
            done
            \(restartScript)
            /bin/rm -f "$backup"
            """
        }
        return header + "\n" + body + "\n"
    }

    /// AppleScript string literal escaping: backslash, double quote, newline.
    static func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The administrator prompt is macOS's own; `privileged: false` exists so
    /// the same source can be compiled and exercised without it.
    static func appleScript(enabled: Bool, shell: String, privileged: Bool = true) -> String {
        let prompt = "Backlit wants to \(enabled ? "unlock" : "restore") the logo brightness range."
        return "do shell script \"\(appleScriptLiteral(shell))\"" +
            (privileged ? " with prompt \"\(appleScriptLiteral(prompt))\" with administrator privileges" : "")
    }
}
