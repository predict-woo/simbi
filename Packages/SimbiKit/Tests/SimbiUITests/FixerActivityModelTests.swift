import CodexKit
import Testing

@testable import SimbiUI

@MainActor
@Suite struct FixerActivityModelTests {
    @Test func startsOff() {
        #expect(FixerActivityModel().status == .off)
    }

    @Test func recordingStartWakesFromOff() {
        let model = FixerActivityModel()
        model.noteRecordingStarted()
        #expect(model.status == .waiting)
    }

    @Test func passEventsToggleWorkingAndWaiting() {
        let model = FixerActivityModel()
        model.noteRecordingStarted()
        model.handle(.passStarted)
        #expect(model.status == .working)
        model.handle(.passCompleted)
        #expect(model.status == .waiting)
    }

    @Test func doneEndsTheSession() {
        let model = FixerActivityModel()
        model.noteRecordingStarted()
        model.handle(.passStarted)
        model.handle(.done)
        #expect(model.status == .done)
    }

    @Test func recordingRestartWakesFromDone() {
        let model = FixerActivityModel()
        model.handle(.done)
        model.noteRecordingStarted()
        #expect(model.status == .waiting)
    }

    @Test func recordingStartDoesNotDemoteAnActivePass() {
        let model = FixerActivityModel()
        model.handle(.passStarted)
        model.noteRecordingStarted()
        #expect(model.status == .working)
    }
}
