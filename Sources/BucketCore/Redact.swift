import Foundation

/// Best-effort masking of high-confidence secrets in OCR text, before it is written to the sidecar.
/// Not a guarantee: it catches known shapes, not every secret. The PNG is never touched.
public enum Redact {
    public static let mask = "[redacted]"

    private enum Kind { case plain, labelled, card }

    /// Order matters: whole blocks first, then labelled values, then bare keys, then cards.
    private static let rules: [(kind: Kind, regex: NSRegularExpression?)] = {
        func rx(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p) }
        let b = #"(?<![A-Za-z0-9])"#
        return [
            (.plain, rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#)), // PEM; unterminated → to the end
            (.plain, rx(#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)), // JWT
            (.labelled, rx(#"(?i)(?<![A-Za-z])(?:password|passwd|pwd|secret|token|api[_-]?key)[ \t]*[:=][ \t]*(\S+)"#)),
            (.plain, rx(b + #"sk-ant-[A-Za-z0-9_-]{8,}"#)),
            (.plain, rx(b + #"sk-[A-Za-z0-9_-]{20,}"#)),
            (.plain, rx(b + #"gh[pousr]_[A-Za-z0-9]{20,}"#)),
            (.plain, rx(b + #"github_pat_[A-Za-z0-9_]{20,}"#)),
            (.plain, rx(b + #"xox[bp]-[A-Za-z0-9-]{10,}"#)),
            (.plain, rx(b + #"AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"#)),
            (.plain, rx(b + #"AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])"#)),
            (.card, rx(#"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#)),
        ]
    }()

    /// nil = the redactor could not run (a pattern failed to compile): the caller must store no text.
    public static func redact(_ text: String) -> (text: String, count: Int)? {
        var out = text
        var count = 0
        for rule in rules {
            guard let regex = rule.regex else { return nil }
            let ns = out as NSString
            let found = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for m in found.reversed() {
                var range = m.range
                switch rule.kind {
                case .plain: break
                case .labelled:
                    range = m.range(at: 1)
                    if ns.substring(with: range) == mask { continue }
                case .card:
                    let digits = ns.substring(with: range).filter(\.isNumber)
                    guard (13 ... 19).contains(digits.count), luhn(digits) else { continue }
                }
                out = (out as NSString).replacingCharacters(in: range, with: mask)
                count += 1
            }
        }
        return (out, count)
    }

    /// Never returns the raw text: if the redactor cannot run, everything is masked.
    public static func apply(_ text: String) -> (text: String, count: Int) {
        redact(text) ?? (mask, 1)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}

/// Apps whose screenshots are never read: the screen is the secret. Matched by the frontmost app's bundle id at capture.
public enum PasswordManagers {
    public static let bundleIds: Set<String> = [
        "com.1password.1password",          // 1Password 8 (from memory, not verified here)
        "com.agilebits.onepassword7",       // 1Password 7 (from memory, not verified here)
        "com.agilebits.onepassword-osx",    // 1Password 6 and earlier (from memory, not verified here)
        "com.bitwarden.desktop",            // verified against an installed Bitwarden.app
        "com.apple.keychainaccess",         // verified (Keychain Access.app)
        "com.apple.Passwords",              // verified (Passwords.app, macOS 15+)
        "com.dashlane.dashlanephonefinal",  // Dashlane (from memory, not verified here)
        "org.keepassxc.keepassxc",          // KeePassXC (from memory, not verified here)
        "in.sinew.Enpass-Desktop",          // Enpass (from memory, not verified here)
        "me.proton.pass.electron",          // Proton Pass desktop (from memory, not verified here)
    ]

    public static func contains(_ bundleId: String?) -> Bool { bundleId.map(bundleIds.contains) ?? false }
}
