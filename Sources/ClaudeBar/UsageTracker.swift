import Foundation

/// Tails the active session's transcript (the JSONL file Claude Code writes)
/// so the Touch Bar can show usage live:
///
///  - **context**: how full the context window is right now — the input
///    side (fresh + cached) of the most recent API call.
///  - **output**: total tokens Claude has written this session.
final class UsageTracker {
    private struct TranscriptState {
        var readOffset: UInt64 = 0
        var contextTokens = 0
        var outputTokens = 0
        /// Claude Code writes one transcript line per content block, each
        /// repeating the same message id and usage. Tracking the last id
        /// keeps us from counting one response two or three times.
        var lastMessageID: String?
        var lastMessageOutput = 0
    }

    var onUpdate: (() -> Void)?

    private var transcriptURL: URL?
    /// Per-transcript progress, so hopping between sessions doesn't
    /// re-read whole transcripts from the top.
    private var states: [URL: TranscriptState] = [:]
    private var timer: Timer?

    private var current: TranscriptState {
        transcriptURL.flatMap { states[$0] } ?? TranscriptState()
    }

    var contextTokens: Int { current.contextTokens }
    var outputTokens: Int { current.outputTokens }

    /// Compact summary for the Touch Bar, e.g. "ctx 41k · out 2.3k".
    var summary: String {
        "ctx \(Self.compact(contextTokens)) · out \(Self.compact(outputTokens))"
    }

    func watch(transcriptPath: String) {
        let url = URL(fileURLWithPath: transcriptPath)
        let switched = url != transcriptURL
        transcriptURL = url
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
        poll(forceNotify: switched)
    }

    func forget(transcriptPath: String) {
        let url = URL(fileURLWithPath: transcriptPath)
        states[url] = nil
        if url == transcriptURL { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        transcriptURL = nil
        onUpdate?()
    }

    private func poll(forceNotify: Bool = false) {
        guard let url = transcriptURL else { return }
        var state = states[url] ?? TranscriptState()
        let changed = Self.consumeNewLines(from: url, into: &state)
        states[url] = state
        if changed || forceNotify { onUpdate?() }
    }

    /// Reads whatever was appended since last time. Only complete lines
    /// are consumed — a line Claude Code is halfway through writing waits
    /// for the next poll instead of being dropped.
    private static func consumeNewLines(from url: URL, into state: inout TranscriptState) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let size = handle.seekToEndOfFile()
        if size < state.readOffset {
            // Transcript was truncated or replaced; start over.
            state = TranscriptState()
        }
        guard size > state.readOffset else { return false }

        handle.seek(toFileOffset: state.readOffset)
        let data = handle.readData(ofLength: Int(size - state.readOffset))
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return false }
        let complete = data[data.startIndex...lastNewline]
        state.readOffset += UInt64(complete.count)

        var changed = false
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let output = usage["output_tokens"] as? Int ?? 0
            let id = message["id"] as? String
            if let id = id, id == state.lastMessageID {
                // Same response, another content block: replace, don't add.
                state.outputTokens += output - state.lastMessageOutput
            } else {
                state.outputTokens += output
            }
            state.lastMessageID = id
            state.lastMessageOutput = output

            // Subagent turns have their own context window; don't let them
            // masquerade as the main session's.
            if obj["isSidechain"] as? Bool != true {
                state.contextTokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            }
            changed = true
        }
        return changed
    }

    private static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
