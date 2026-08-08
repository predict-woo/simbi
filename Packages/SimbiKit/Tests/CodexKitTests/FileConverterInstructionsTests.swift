import Foundation
import Testing

@testable import CodexKit

@Suite("FileConverter instructions")
struct FileConverterInstructionsTests {
    private let template = """
        Run "{{ anydoc }}" "files/{{ file }}" -o "context/{{ file }}.md".
        """

    @Test("renders the bundled tool path when present")
    func rendersPath() {
        let text = FileConverter.renderInstructions(
            template, fileName: "report.docx",
            anydocPath: "/Applications/Simbi.app/Contents/Helpers/anydoc")
        #expect(
            text == """
                Run "/Applications/Simbi.app/Contents/Helpers/anydoc" \
                "files/report.docx" -o "context/report.docx.md".
                """)
    }

    @Test("falls back to the bare tool name when the binary is absent")
    func rendersBareNameWithoutPath() {
        let text = FileConverter.renderInstructions(
            template, fileName: "report.docx", anydocPath: nil)
        #expect(text == "Run \"anydoc\" \"files/report.docx\" -o \"context/report.docx.md\".")
    }

    @Test("bundledAnydocPath is nil outside the app bundle")
    func bundledPathNilHeadless() {
        // Tests run in an xctest bundle with no Contents/Helpers/anydoc.
        #expect(FileConverter.bundledAnydocPath == nil)
    }
}
