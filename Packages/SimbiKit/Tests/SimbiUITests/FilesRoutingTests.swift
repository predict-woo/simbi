import Testing

@testable import SimbiAudio
@testable import SimbiKit
@testable import SimbiUI

@Suite("Files routing")
struct FilesRoutingTests {
    @Test("media routes to import, documents to the converter, unsupported to a failed row")
    func routing() {
        #expect(FilesModel.route(for: "talk.mp4") == .mediaImport)
        #expect(FilesModel.route(for: "voice.m4a") == .mediaImport)
        #expect(FilesModel.route(for: "clip.webm") == .unsupportedMedia)
        #expect(FilesModel.route(for: "slides.pptx") == .documentConversion)
        #expect(FilesModel.route(for: "notes.pdf") == .documentConversion)
    }
}
