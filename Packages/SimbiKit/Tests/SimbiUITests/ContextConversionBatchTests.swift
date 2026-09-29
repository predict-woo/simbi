import Testing

@testable import SimbiUI

@Suite("Context conversion batch")
struct ContextConversionBatchTests {
    @Test("multiple successful conversions emit one settled batch")
    func multipleFilesEmitOnce() {
        var batch = ContextConversionBatch()
        batch.started()
        batch.started()
        batch.started()

        #expect(batch.finished(successfully: true) == nil)
        #expect(batch.finished(successfully: true) == nil)
        #expect(batch.finished(successfully: true) == 3)
    }

    @Test("failed conversions are excluded and the next batch starts clean")
    func failuresAreExcluded() {
        var batch = ContextConversionBatch()
        batch.started()
        batch.started()

        #expect(batch.finished(successfully: false) == nil)
        #expect(batch.finished(successfully: true) == 1)

        batch.started()
        #expect(batch.finished(successfully: false) == nil)
    }
}
