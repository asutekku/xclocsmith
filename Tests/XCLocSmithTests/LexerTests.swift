import XCTest
@testable import XCLocSmithKit

/// Table tests for the Swift tokenizer. Each case is Swift that compiles; the
/// expectation is the exact set of catalog keys the compiler would extract.
final class LexerTests: XCTestCase {

    private func values(_ source: String) -> [String] {
        SwiftLexer.lex(source).literals.filter { !$0.hasInterpolation }.map(\.value)
    }

    func testPlainAndEscapedLiterals() {
        XCTAssertEqual(values(#"Text("Hello")"#), ["Hello"])
        XCTAssertEqual(values(#"Text("say \"hi\"")"#), [#"say "hi""#])
        XCTAssertEqual(values(#"Text("line\nbreak")"#), ["line\nbreak"])
        XCTAssertEqual(values(##"Text(#"raw \(not interpolated)"#)"##), [#"raw \(not interpolated)"#])
        XCTAssertEqual(values(###"Text(##"hash "quoted""##)"###), [#"hash "quoted""#])
    }

    /// Swift strips the closing delimiter's indentation from every line. When
    /// that indentation mixes spaces and tabs, collecting it backwards without
    /// reversing transposes it, the prefix stops matching, and the extracted
    /// value keeps whitespace that is not part of the key — which made `prune`
    /// delete live keys.
    func testMultilineIndentStripping() {
        let spaces = "let x = \"\"\"\n    Body line\n    \"\"\""
        XCTAssertEqual(values(spaces), ["Body line"])

        let mixed = "let x = \"\"\"\n \tBody line\n \t\"\"\""
        XCTAssertEqual(values(mixed), ["Body line"])

        let tabsFirst = "let x = \"\"\"\n\t Body line\n\t \"\"\""
        XCTAssertEqual(values(tabsFirst), ["Body line"])

        let twoLines = "let x = \"\"\"\n  First\n  Second\n  \"\"\""
        XCTAssertEqual(values(twoLines), ["First\nSecond"])
    }

    func testCommentsAreNotLiterals() {
        XCTAssertEqual(values(#"// Text("commented")"#), [])
        XCTAssertEqual(values("/* Text(\"block\") */"), [])
        XCTAssertEqual(values("/* outer /* nested \"x\" */ still */ Text(\"real\")"), ["real"])
    }

    /// A block comment inside an interpolation contains a `)` that must not be
    /// mistaken for the end of the interpolation.
    func testBlockCommentInsideInterpolation() {
        let source = #"Text("count \(1 /* ) */ + 2) end")"#
        let literals = SwiftLexer.lex(source).literals
        XCTAssertEqual(literals.count, 1)
        XCTAssertTrue(literals[0].hasInterpolation)
        XCTAssertEqual(literals[0].value, "count  end")
    }

    func testNestedLiteralsInInterpolationAreMarked() {
        let literals = SwiftLexer.lex(#"Text("a \(flag ? "yes" : "no") b")"#).literals
        XCTAssertEqual(literals.filter(\.isNested).map(\.value), ["yes", "no"])
        XCTAssertEqual(literals.filter { !$0.isNested }.count, 1)
    }

    func testLineNumbersSurviveCRLF() {
        let source = "import SwiftUI\r\nstruct V {\r\n  var body = Text(\"CRLF\")\r\n}\r\n"
        let literals = SwiftLexer.lex(source).literals
        XCTAssertEqual(literals.first?.value, "CRLF")
        XCTAssertEqual(literals.first?.line, 3)
    }

    func testUnterminatedLiteralDoesNotHang() {
        let literals = SwiftLexer.lex("Text(\"unterminated\n").literals
        XCTAssertEqual(literals.count, 1)
    }

    func testInterpolationProducesAFormatPattern() {
        let literals = SwiftLexer.lex(#"Text("Hello \(name)!")"#).literals
        XCTAssertEqual(literals.count, 1)
        let pattern = try? XCTUnwrap(literals[0].formatPattern)
        XCTAssertNotNil(pattern)
        let regex = try? NSRegularExpression(pattern: "^" + (pattern ?? "") + "$")
        for candidate in ["Hello %@!", "Hello %lld!"] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            XCTAssertNotNil(regex?.firstMatch(in: candidate, range: range), candidate)
        }
        let mismatch = "Goodbye %@!"
        XCTAssertNil(regex?.firstMatch(in: mismatch, range: NSRange(mismatch.startIndex..., in: mismatch)))
    }

    func testPreviewBodiesAreIdentified() {
        let source = """
            struct V: View { var body: some View { Text("Shipped") } }
            #Preview {
                V(title: "Sample data")
            }
            """
        let lexed = SwiftLexer.lex(source)
        let preview = lexed.literals.first { $0.value == "Sample data" }
        let shipped = lexed.literals.first { $0.value == "Shipped" }
        XCTAssertTrue(lexed.isInsidePreview(try! XCTUnwrap(preview)))
        XCTAssertFalse(lexed.isInsidePreview(try! XCTUnwrap(shipped)))
    }

    func testIgnoreDirectives() {
        let lexed = SwiftLexer.lex("Text(\"skipped\")   // xclocsmith:ignore\nText(\"kept\")")
        XCTAssertTrue(lexed.ignoredLines.contains(1))
        XCTAssertFalse(lexed.ignoredLines.contains(2))
        XCTAssertTrue(SwiftLexer.lex("// xclocsmith:ignore-file\nText(\"x\")").isFileIgnored)
    }

    /// The blanked code keeps the original offsets, which every context lookup
    /// depends on. Offsets are into the source's UTF-8, so a multi-byte
    /// character occupies as many of them as it has bytes.
    func testBlankedCodeKeepsLength() {
        let source = "Text(\"emoji 🧖 here\") // comment\nlet x = 1\n"
        let lexed = SwiftLexer.lex(source)
        XCTAssertEqual(lexed.bytes.count, source.utf8.count)
    }

    /// A literal's offsets have to land on the literal itself, or every parser
    /// that reads around one is looking at the wrong place.
    func testLiteralOffsetsAreUTF8() {
        let source = "let 🧖 = 1\nText(\"Sauna\")\n"
        let literal = try? XCTUnwrap(SwiftLexer.lex(source).literals.first)
        guard let literal else { return }
        let bytes = Array(source.utf8)
        XCTAssertEqual(bytes[literal.start], UInt8(ascii: "\""))
        XCTAssertEqual(bytes[literal.end - 1], UInt8(ascii: "\""))
        XCTAssertEqual(literal.value, "Sauna")
        XCTAssertEqual(literal.line, 2)
    }

    /// `\r\n` is one line break, not two.
    func testWindowsLineEndingsCountOnce() {
        let lexed = SwiftLexer.lex("let a = 1\r\nlet b = 2\r\nText(\"Hi\")\r\n")
        XCTAssertEqual(lexed.literals.first?.line, 3)
    }
}
