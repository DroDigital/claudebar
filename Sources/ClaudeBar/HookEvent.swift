import Foundation

/// One event forwarded from a Claude Code hook. Claude Code pipes JSON to
/// hook commands on stdin; our hook script relays that JSON to the app's
/// unix socket untouched, so the fields here mirror the official hook input.
/// See: https://docs.anthropic.com/en/docs/claude-code/hooks
struct HookEvent: Decodable {
    let hookEventName: String
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    /// Present on Notification events, e.g.
    /// "Claude needs your permission to use Bash".
    let message: String?
    /// Present on Notification events in recent Claude Code versions, e.g.
    /// "permission_prompt" or "idle_prompt".
    let notificationType: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case message
        case notificationType = "notification_type"
    }

    var isPermissionRequest: Bool {
        guard hookEventName == "Notification" else { return false }
        // Prefer the structured field; fall back to the message text on
        // older Claude Code versions that don't send it.
        if let type = notificationType {
            return type == "permission_prompt"
        }
        return message?.localizedCaseInsensitiveContains("permission") ?? false
    }
}
