import Foundation
import SimbiKit

/// Maps thread turn-lifecycle notifications onto conversion-status effects
/// (live-view spec §5): after the app's own job ends, status follows
/// whatever turns the user runs on the thread from a viewer terminal, and
/// the output file on disk is the truth. Pure decision logic — FilesModel
/// applies the effects.
public enum ConversionThreadEvents {
    public enum Effect: Equatable, Sendable {
        /// A turn began on `file`'s thread: show converting and suppress
        /// re-dispatch until the turn ends.
        case turnBegan(file: String)
        /// The turn ended: verify context/<file>.md and record done/failed.
        case turnEnded(file: String)
    }

    /// Decides the effect of one notification. Files with an app-owned job
    /// in flight (`activeJobs`) are the job's business — the observer only
    /// tracks turns on threads the job machinery is done with.
    public static func effect(
        method: String,
        params: Data,
        conversions: [String: NoteRecordingState.FileConversion],
        activeJobs: Set<String>
    ) -> Effect? {
        guard method == "turn/started" || method == "turn/completed",
            let object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any],
            let threadId = object["threadId"] as? String,
            let file = conversions.first(where: { $0.value.threadId == threadId })?.key,
            !activeJobs.contains(file)
        else { return nil }
        return method == "turn/started" ? .turnBegan(file: file) : .turnEnded(file: file)
    }
}
