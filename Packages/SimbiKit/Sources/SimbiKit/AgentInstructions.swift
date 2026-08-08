import CryptoKit
import Foundation

/// The user-editable agent instruction files at the `~/Simbi` root
/// (SPEC.md §2.1): one markdown file per Codex role, bootstrapped with the
/// built-in default and thereafter owned by the user. Dynamic parts are
/// `{{ variable }}` placeholders the app substitutes at use time, so users
/// can move them around freely.
///
/// A missing or blank file falls back to the built-in default — deleting a
/// file is a reset, and no agent can end up with empty instructions.
public enum AgentInstructions: String, CaseIterable, Identifiable, Sendable {
    /// Transcript-fixer thread instructions. No variables.
    case fixer = "FIXER.md"
    /// File-import conversion instructions. Variables: `{{ file }}` — the
    /// imported file's name inside `files/`; `{{ anydoc }}` — path of the
    /// bundled anydoc converter CLI (the bare word `anydoc` when the app
    /// bundle doesn't carry it, so the command fails fast and the agent
    /// falls back).
    case ingest = "INGEST.md"
    /// The note chat's opening developer message. Variables:
    /// `{{ note_path }}` — the note's home-relative path; `{{ files }}` —
    /// a sentence inventorying the note's current files.
    case chat = "CHAT.md"
    /// Ground rules for any agent working in the Simbi home. No variables;
    /// picked up by codex itself as a plain AGENTS.md.
    case agents = "AGENTS.md"

    public var id: String { rawValue }

    public var fileName: String { rawValue }

    /// Row label in Settings; matches the model pickers' vocabulary.
    public var title: String {
        switch self {
        case .fixer: "Transcript fixer"
        case .ingest: "File converter"
        case .chat: "Note chat"
        case .agents: "All agents"
        }
    }

    /// The `{{ variable }}` names this file's template supports, in the
    /// order the app fills them. Shown in the instructions editor's
    /// footer; unknown names in a template are left verbatim.
    public var variables: [String] {
        switch self {
        case .fixer, .agents: []
        case .ingest: ["file", "anydoc"]
        case .chat: ["note_path", "files"]
        }
    }

    public func url(homeRootURL: URL) -> URL {
        homeRootURL.appending(path: fileName)
    }

    /// The file's current template text: the user's file when it has any
    /// content, the built-in default otherwise.
    public func contents(homeRootURL: URL) -> String {
        guard let text = try? String(contentsOf: url(homeRootURL: homeRootURL), encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return defaultContents }
        return text
    }

    /// `contents` with `{{ variable }}` placeholders substituted.
    public func resolve(homeRootURL: URL, variables: [String: String] = [:]) -> String {
        Self.render(contents(homeRootURL: homeRootURL), variables: variables)
    }

    /// Replaces every `{{ key }}` (whitespace inside the braces optional)
    /// with its value. Unknown placeholders stay verbatim — visible beats
    /// silently vanished.
    public static func render(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            let pattern = "\\{\\{\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*\\}\\}"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: value),
                options: .regularExpression)
        }
        return result
    }

    /// Stable short hash of an instruction text, persisted in a note's
    /// state.json so threads created under different (user-edited)
    /// instructions are retired rather than resumed.
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    public var defaultContents: String {
        switch self {
        case .fixer: Self.defaultFixer
        case .ingest: Self.defaultIngest
        case .chat: Self.defaultChat
        case .agents: Self.defaultAgents
        }
    }

    private static let defaultFixer = """
        You are the transcript fixer for this note. The file transcript.vtt in your \
        working directory is YOUR WORKING COPY of the note's live WebVTT transcript — \
        it is refreshed from the live file before every ping, and after each of your \
        turns I diff your copy against what you were given and merge the changed cue \
        payloads into the live transcript myself. Never write outside your working \
        directory. The note's own files are read-only ground truth for names and \
        jargon: ../../note.md, and ../../context/*.md if present.

        On each of my pings, review the cues I name (plus earlier ones if needed for \
        consistency) and fix ASR errors in their text: spelling of names and jargon, \
        punctuation, and obvious mis-hearings. Rules you must never break:
        - Edit ONLY cue text and `<v Name>` speaker tags. The merge takes nothing \
        else: renumbering cues, changing timestamps, or adding/deleting cues or NOTE \
        blocks is discarded, so it is wasted work.
        - Speaker diarization is imperfect: when the conversation makes it pretty \
        certain a cue is attributed to the wrong speaker (e.g. a reply credited to \
        the person who just asked the question, or a sentence obviously continuing \
        the other speaker's thought), fix that cue's `<v>` tag — copy the correct \
        speaker's tag exactly as it appears on their other cues. When in doubt, \
        leave the attribution alone.
        - Renaming a speaker's identity is different from fixing attribution: rename \
        ONLY when the transcript makes the identity unambiguous (e.g. a speaker \
        introduces themselves), then rename that speaker consistently across the \
        whole file.
        - `NOTE session` blocks mark stop/resume boundaries. Speaker slot numbering may \
        reshuffle across them ("Speaker 1" in session 2 may be a different person than \
        in session 1) — unify names across sessions only when identity is clear from \
        the content.
        - Keep your copy valid WebVTT — a copy that fails to parse contributes nothing.

        Reply with a one-line summary of what you changed (or "no changes").
        """

    private static let defaultIngest = """
        Convert files/{{ file }} to a markdown mirror at context/{{ file }}.md \
        (create the context/ directory if needed).

        If the file is Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, \
        CSV, or PDF, try "{{ anydoc }}" "files/{{ file }}" -o \
        "context/{{ file }}.md" first. Then read the output and verify it \
        against the original; fix or augment it as needed. If the document \
        has embedded images, rerun it with --assets <a temp directory> to \
        extract them, then look at each image and describe it in place in \
        the markdown. If the tool is missing, fails, or does not support \
        the format, find your own way to read the format.

        Hard requirement: NO information loss — prefer verbose fidelity over \
        pretty summarization. Tables stay tables, numbers stay exact, all text \
        content is carried over. Describe images/figures in place.

        Never modify files/{{ file }} or anything outside context/. Reply with \
        one line: DONE, or FAILED: <reason>.
        """

    private static let defaultChat = """
        This session is attached to the Simbi note at {{ note_path }} (your working \
        directory). Simbi notes keep a fixed layout: `note.md` is the user's note, \
        `transcript.vtt` is the meeting transcript with speaker labels, `context/` \
        holds markdown conversions of attached files, and `files/` holds the \
        original attachments.

        {{ files }}

        Read whichever files are relevant before answering, and when the user asks \
        for changes, edit the files on disk.
        """

    private static let defaultAgents = """
        # Simbi home directory

        This directory is managed by **Simbi**, a macOS notetaking app that records,
        diarizes, and transcribes audio into plain files. There is no database:
        what you see on disk is the entire state.

        ## Layout

        - A folder containing `note.md` is a **note folder** — a single note. Note
          folders are never nested inside other note folders.
        - Folders without `note.md` are purely organizational.
        - `.simbi/` at this root holds app-global settings.

        ## Inside a note folder

        | Entry | Meaning |
        |---|---|
        | `note.md` | The user's own markdown note. |
        | `audio.webm` | The note's single continuous recording (WebM/Opus, all sessions appended). |
        | `transcript.vtt` | The WebVTT transcript of `audio.webm`. Rendered live by the app. |
        | `files/` | User-added input files. **Originals — never modify.** |
        | `context/` | Markdown conversions of `files/` entries (`<name>.md` mirrors `files/<name>`). |
        | `.simbi/` | Internal state (thread ids, job state, pending uploads). Do not edit by hand. |

        ## Rules for agents working here

        - Any edit to `transcript.vtt` must leave it **valid WebVTT** — the app renders
          it live. Never renumber cues, never change cue timestamps.
        - `NOTE session` blocks mark recording stop/resume boundaries. Speaker slot
          numbering may reshuffle across sessions; `<v>` speaker names may be unified
          across sessions only when the content makes identity unambiguous.
        - `NOTE gap` blocks mark silences that have audio but no transcript cue.
        - Never modify anything under `files/` or `.simbi/`.
        """
}
