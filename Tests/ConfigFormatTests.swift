//
//  ConfigFormatTests.swift
//  SwiftFormat
//
//  Created by Ethan Pippin on 25/10/2026.
//  Copyright 2026 Nick Lockwood
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import XCTest
@testable import SwiftFormat

private func parseYAML(_ yaml: String, logger: Logger? = nil) throws -> [[String: String]] {
    try parseConfigFile(Data(yaml.utf8), format: YAMLConfigFormat(), logger: logger)
}

/// A deterministic random number generator, so that fuzz test failures are reproducible
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

final class ConfigFormatTests: XCTestCase {
    func testConfigFormatForURL() {
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/.swiftformat")) is TextConfigFormat)
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/config.swiftformat")) is TextConfigFormat)
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/config")) is TextConfigFormat)
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/.swiftformat.yml")) is YAMLConfigFormat)
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/.swiftformat.yaml")) is YAMLConfigFormat)
        XCTAssert(configFormat(for: URL(fileURLWithPath: "/project/config.YML")) is YAMLConfigFormat)
    }

    func testParseYAMLOptions() throws {
        let config = try parseYAML("""
        indent: 2
        allman: true
        header: "// Copyright {year}"
        """)
        XCTAssertEqual(config, [["indent": "2", "allman": "true", "header": "// Copyright {year}"]])
    }

    func testParseYAMLValuesAsStrings() throws {
        let config = try parseYAML("""
        swift-version: 5.10
        language-mode: 6
        """)
        XCTAssertEqual(config, [["swift-version": "5.10", "language-mode": "6"]])
    }

    func testParseYAMLLists() throws {
        let config = try parseYAML("""
        disable:
          - redundantSelf
          - trailingCommas
        enable: [isEmpty, "sortImports"]
        exclude:
        - Pods
        - "**/Generated"
        """)
        XCTAssertEqual(config, [[
            "disable": "redundantSelf,trailingCommas",
            "enable": "isEmpty,sortImports",
            "exclude": "Pods,**/Generated",
        ]])
    }

    func testParseYAMLFlowListOnMultipleLines() throws {
        let config = try parseYAML("""
        disable: [
          redundantSelf, # comment
          trailingCommas,
        ]
        indent: 4
        """)
        XCTAssertEqual(config, [["disable": "redundantSelf,trailingCommas", "indent": "4"]])
    }

    func testParseYAMLQuotedValues() throws {
        let config = try parseYAML(#"""
        header: "Line 1\nLine \"2\"!"
        url-macro: '#URL,URLFoundation'
        acronyms: 'it''s'
        """#)
        XCTAssertEqual(config, [[
            "header": #"Line 1\nLine "2"!"#,
            "url-macro": "#URL,URLFoundation",
            "acronyms": "it's",
        ]])
    }

    func testParseYAMLLiteralBlockScalar() throws {
        let config = try parseYAML("""
        header: |
          // Copyright {year}

          // Licensed under MIT
        indent: 2
        """)
        XCTAssertEqual(config, [["header": #"// Copyright {year}\n\n// Licensed under MIT"#, "indent": "2"]])
    }

    func testParseYAMLFoldedBlockScalar() throws {
        let config = try parseYAML("""
        header: >-
          Copyright
          {year}

          Acme
        """)
        XCTAssertEqual(config, [["header": #"Copyright {year}\nAcme"#]])
    }

    func testParseYAMLBlockScalarWithoutTrailingLineBreaks() throws {
        for header in ["|", "|-", "|+", ">", ">+"] {
            let config = try parseYAML("header: \(header)\n  Copyright\n\n\nindent: 2\n")
            XCTAssertEqual(config, [["header": "Copyright", "indent": "2"]], header)
        }
    }

    func testParseYAMLCommentsAndDocumentMarkers() throws {
        let config = try parseYAML("""
        # SwiftFormat config
        ---
        indent: 4 # spaces

        # Line breaks
        linebreaks: lf
        """)
        XCTAssertEqual(config, [["indent": "4", "linebreaks": "lf"]])
    }

    func testParseYAMLSections() throws {
        let config = try parseYAML("""
        indent: 4
        sections:
          - name: Tests
            filter: "**/Tests/**"
            indent: 2
            disable:
              - redundantSelf
          - filter: "**/Generated/**"
            rules: indent
        """)
        XCTAssertEqual(config, [
            ["indent": "4"],
            ["filter": "**/Tests/**", "indent": "2", "disable": "redundantSelf"],
            ["filter": "**/Generated/**", "rules": "indent"],
        ])
    }

    func testParseEmptyYAMLConfigFile() throws {
        XCTAssertEqual(try parseYAML(""), try parseConfigFile(Data("".utf8)))
        XCTAssertEqual(try parseYAML("# Nothing here\n"), [[:]])
    }

    func testYAMLAndTextConfigFilesAreEquivalent() throws {
        let text = """
        --swift-version 5.10
        --indent 2
        --header "// Copyright {year}\\n// Acme"
        --disable redundantSelf,trailingCommas
        --exclude Pods,**/Generated

        [Tests]
        --filter **/Tests/**
        --indent 4
        """
        let yaml = """
        swift-version: "5.10"
        indent: 2
        header: |
          // Copyright {year}
          // Acme
        disable: [redundantSelf, trailingCommas]
        exclude:
          - Pods
          - "**/Generated"
        sections:
          - name: Tests
            filter: "**/Tests/**"
            indent: 4
        """
        XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)))
    }

    func testYAMLAndTextConfigFilesWithEscapedValuesAreEquivalent() throws {
        let text = #"""
        --header "Trailing line break\n"
        --url-macro "#URL,URLFoundation"
        """#
        let yaml = #"""
        header: "Trailing line break\n"
        url-macro: "#URL,URLFoundation"
        """#
        XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)))
    }

    func testYAMLAndTextConfigFilesWithCRLFAndLegacyNamesAreEquivalent() throws {
        let text = "--indentcase true\r\n--disable redundantSelf\r\n--disable trailingCommas\r\n"
        let yaml = "indentcase: true\r\ndisable: [redundantSelf, trailingCommas]\r\n"
        XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)))
    }

    func testUnknownOptionsModeAppliesToYAMLSections() throws {
        var warnings = [String]()
        let config = try parseYAML("""
        unknown-options: warn
        sections:
          - filter: "**/Tests/**"
            future-option: value
        """, logger: Logger { message, type in
            if type == .warning {
                warnings.append(message)
            }
        })
        XCTAssertEqual(config.count, 2)
        XCTAssertEqual(warnings.count, 1)
        XCTAssert(warnings.first?.contains("Unknown option --future-option") == true)
    }

    func testUnknownYAMLOption() {
        XCTAssertThrowsError(try parseYAML("indnet: 4")) { error in
            XCTAssert("\(error)".hasPrefix("Unknown option --indnet"), "\(error)")
            XCTAssert("\(error)".hasSuffix("in configuration file"), "\(error)")
        }
    }

    func testInvalidYAML() {
        let cases = [
            ("filter: **/Tests/**", #"Values starting with '*' must be quoted, e.g. "**/Tests/**" on line 1"#),
            ("--indent 4", "YAML config files don't use a leading '--' before option names"),
            ("indent: 2\nindent: 4", "Duplicate key 'indent' on line 2"),
            ("disable:\n\t- redundantSelf", "Tabs can't be used for indentation on line 2"),
            ("indent: 2\n  linebreaks: lf", "Unexpected indentation on line 2"),
            ("sections:\n  - sections: []", "Sections can't be nested on line 2"),
            ("sections: Tests", "Value of 'sections' must be a list on line 1"),
            ("indent:\n  value: 2", "Value of 'indent' must be a string or a list on line 2"),
            (#"exclude: ["a,b"]"#, "Items in 'exclude' can't contain commas on line 1"),
            ("indent: 2\n---\nindent: 4", "Multiple YAML documents are not supported on line 2"),
            (#"header: "Copyright"#, #"Missing closing " on line 1"#),
            ("indent: &size 2", "Values starting with '&' must be quoted"),
            ("- indent", "Expected a mapping of option names to values on line 1"),
            ("disable: [redundantSelf", "Missing closing ']' on line 1"),
            ("header: Copyright: Acme", "Values containing ': ' or starting with '- ' must be quoted on line 1"),
        ]
        for (yaml, message) in cases {
            XCTAssertThrowsError(try parseYAML(yaml), yaml) { error in
                XCTAssert("\(error)".contains(message), "\(error)")
            }
        }
    }

    func testYAMLSerialization() {
        let yaml = YAMLConfigFormat().serialize([
            ["exclude": "Pods,**/Generated"],
            ["indent": "2", "swift-version": "5.10", "header": #"// Copyright\n// Acme"#, "self": "remove"],
            ["disable": "redundantSelf,trailingCommas", "enable": ""],
        ])
        XCTAssertEqual(yaml, #"""
        exclude:
          - Pods
          - "**/Generated"
        header: "// Copyright\\n// Acme"
        indent: 2
        self: remove
        swift-version: "5.10"
        disable:
          - redundantSelf
          - trailingCommas
        enable: []
        """#)
    }

    func testYAMLScalarsRoundTrip() throws {
        let values = [
            "", " leading", "trailing ", "a b", "#a", "a #b", "a: b", "a:", "- a", "? a", "--a", "*a", "&a",
            "!a", "%a", "@a", "`a", "[a]", "{a}", "|a", ">a", "'", "\"", "a'b", "\\", #"\n"#, #"a\nb"#,
            #"\\n"#, "5.10", "0755", "-1", "true", "no", "Null", "~", "© Acme", "tab\tcharacter",
        ]
        for value in values {
            let yaml = YAMLConfigFormat().serialize([["header": value]])
            XCTAssertEqual(try YAMLConfigFormat().parse(yaml), [["--header", value]], yaml)
        }
    }

    func testAllOptionValuesRoundTripThroughYAML() throws {
        for descriptor in Descriptors.all where !descriptor.isDeprecated {
            for value in descriptor.validArguments ?? [descriptor.defaultArgument] {
                var formatOptions = FormatOptions.default
                try descriptor.toOptions(value, &formatOptions)
                let options = Options(formatOptions: formatOptions)
                let yaml = serialize(options: options, excludingDefaults: true, format: YAMLConfigFormat())
                let text = serialize(options: options, excludingDefaults: true)
                XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)), descriptor.argumentName)
            }
        }
    }

    func testDefaultOptionsRoundTripThroughYAML() throws {
        let yaml = serialize(options: .default, format: YAMLConfigFormat())
        let text = serialize(options: .default)
        XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)))
    }

    func testCustomOptionsRoundTripThroughYAML() throws {
        let options = Options(
            formatOptions: FormatOptions(
                indent: "\t",
                fileHeader: "// Hello\n// \"World\"",
                swiftVersion: "5.10"
            ),
            rules: Set(["indent", "braces"])
        )
        let yaml = serialize(options: options, excludingDefaults: true, format: YAMLConfigFormat())
        let text = serialize(options: options, excludingDefaults: true)
        XCTAssertEqual(try parseYAML(yaml), try parseConfigFile(Data(text.utf8)))
    }

    func testRandomScalarsRoundTripThroughYAML() throws {
        var generator = SeededGenerator(state: 1)
        let characters = Array(" \t#:-*&!%@`'\"\\/?|>,.[]{}~anZ09©")
        for _ in 0 ..< 2000 {
            let value = String((0 ..< Int.random(in: 0 ... 12, using: &generator)).map { _ in
                characters.randomElement(using: &generator)!
            })
            let yaml = YAMLConfigFormat().serialize([["header": value]])
            XCTAssertEqual(try YAMLConfigFormat().parse(yaml), [["--header", value]], yaml)
        }
    }

    func testRandomListsRoundTripThroughYAML() throws {
        var generator = SeededGenerator(state: 2)
        let characters = Array(" #:-*&'\"\\/[]{}an09")
        for _ in 0 ..< 500 {
            let items = (0 ..< Int.random(in: 1 ... 4, using: &generator)).map { _ in
                // List items are trimmed and can't be empty or contain commas
                "x" + String((0 ..< Int.random(in: 0 ... 6, using: &generator)).map { _ in
                    characters.randomElement(using: &generator)!
                }) + "x"
            }
            let yaml = YAMLConfigFormat().serialize([["disable": items.joined(separator: ",")]])
            XCTAssertEqual(try YAMLConfigFormat().parse(yaml), [["--disable", items.joined(separator: ",")]], yaml)
        }
    }

    func testRandomInvalidYAMLReportsLineNumbers() {
        var generator = SeededGenerator(state: 3)
        let indents = ["", "", "  ", "    ", "\t", " "]
        let keys = ["indent", "disable", "sections", "name", "filter", "--indent", "- ", "-", "a b", "\"key\"", ""]
        let separators = [": ", ":", " : ", " ", ""]
        let values = [
            "", "2", "[a, b]", "[a,", "]", "|", ">-", "|2", "\"x", "'y'", "*z", "&a b", "a: b", "# comment",
            "{a: b}", "\\", "\"\\q\"", "\"\\u12\"", "a #b", "---", "- item", "[[a]]", "'it''s'", "\"\\x41\"",
        ]
        var validCount = 0, invalidCount = 0
        for _ in 0 ..< 3000 {
            let yaml = (0 ..< Int.random(in: 1 ... 6, using: &generator)).map { _ in
                if Int.random(in: 0 ..< 20, using: &generator) == 0 {
                    return "---"
                }
                return indents.randomElement(using: &generator)! + keys.randomElement(using: &generator)! +
                    separators.randomElement(using: &generator)! + values.randomElement(using: &generator)!
            }.joined(separator: "\n")
            do {
                _ = try YAMLConfigFormat().parse(yaml)
                validCount += 1
            } catch let FormatError.options(message) {
                XCTAssert(message.range(of: " on line [0-9]+ of configuration file$", options: .regularExpression) != nil,
                          "\(message)\n\(yaml)")
                invalidCount += 1
            } catch {
                XCTFail("Unexpected error \(error) for:\n\(yaml)")
            }
        }
        // Make sure that both valid and invalid documents were generated
        XCTAssertGreaterThan(validCount, 50)
        XCTAssertGreaterThan(invalidCount, 50)
    }

    func testParseYAMLEdgeCases() throws {
        let cases: [(String, [[String: String]])] = [
            ("indent : 4", [["indent": "4"]]),
            ("Indent: 4", [["indent": "4"]]),
            ("exclude:", [["exclude": ""]]),
            ("disable: []", [["disable": ""]]),
            ("disable: [ a , 'b' , \"c\" ]", [["disable": "a,b,c"]]),
            ("disable: [a, # comment\n  b]", [["disable": "a,b"]]),
            ("disable: [a # comment\n]", [["disable": "a"]]),
            ("filter: header-creation-date-after:2026-08-31", [["filter": "header-creation-date-after:2026-08-31"]]),
            ("url-macro: URL#Foundation", [["url-macro": "URL#Foundation"]]),
            ("indent: 4\t# comment", [["indent": "4"]]),
            ("header: \"a\" # comment", [["header": "a"]]),
            ("header: 'a # b'", [["header": "a # b"]]),
            ("header: © Acme", [["header": "© Acme"]]),
            (#"header: "\t\\\/\x41©\U0001F600""#, [["header": "\t\\/A©😀"]]),
            (#"header: "\r\0""#, [["header": "\r\0"]]),
            ("--- # start\nindent: 2", [["indent": "2"]]),
            ("header: |\n  line 1\n    indented\n  line 3", [["header": #"line 1\n  indented\nline 3"#]]),
            ("header: |\nindent: 2", [["header": "", "indent": "2"]]),
            ("sections:\n-   filter: a\n    indent: 2", [[:], ["filter": "a", "indent": "2"]]),
            ("sections:\n- filter: a\n  disable:\n  - b\n  - c", [[:], ["filter": "a", "disable": "b,c"]]),
            (
                "sections:\n  - filter: a\n    header: |\n      // Tests\n    indent: 2",
                [[:], ["filter": "a", "header": "// Tests", "indent": "2"]]
            ),
        ]
        for (yaml, expected) in cases {
            XCTAssertEqual(try parseYAML(yaml), expected, yaml)
        }
    }

    func testParseConfigFilesWithByteOrderMark() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        XCTAssertEqual(try parseConfigFile(bom + Data("--indent 2".utf8)), [["indent": "2"]])
        XCTAssertEqual(try parseConfigFile(bom + Data("indent: 2".utf8), format: YAMLConfigFormat()), [["indent": "2"]])
    }

    func testParseConfigFilesWithInvalidUTF8() {
        let data = Data("indent: 2".utf8) + Data([0xFF])
        for format: ConfigFormat in [TextConfigFormat(), YAMLConfigFormat()] {
            XCTAssertThrowsError(try parseConfigFile(data, format: format)) { error in
                XCTAssertEqual("\(error)", "Unable to read data for configuration file")
            }
        }
    }

    func testInvalidYAMLEdgeCases() {
        let cases = [
            ("indent 4", "Expected 'name: value' on line 1"),
            ("header: |2\n  a", "Block scalar indentation indicators are not supported on line 1"),
            ("header: >\n  a\n    b", "More-indented lines in folded block scalars are not supported on line 3"),
            (#"header: "\q""#, #"Unsupported escape sequence '\q' on line 1"#),
            (#"header: "\u12""#, #"Invalid escape sequence '\u' on line 1"#),
            ("header: \"a\" b", "Unexpected 'b' on line 1"),
            ("header: 'a", "Missing closing ' on line 1"),
            (#"header: "a\"#, #"Missing closing " on line 1"#),
            ("disable: [\"a\n  b\"]", #"Missing closing " on line 1"#),
            ("--- foo", "Unexpected 'foo' on line 1"),
            ("disable: [a] b", "Unexpected 'b' on line 1"),
            ("disable: [a,,b]", "Unexpected ',' on line 1"),
            (#"disable: ["a" b]"#, "Expected ',' or ']' on line 1"),
            ("disable: [[a]]", "Nested lists and mappings are not supported on line 1"),
            ("disable: [a\nindent: 2", "Missing closing ']' on line 1"),
            ("disable:\n  - a\n   - b", "Unexpected indentation on line 3"),
            ("disable:\n  - a: b", "Items in 'disable' must be strings on line 2"),
            ("sections:\n  - Tests", "Items in 'sections' must be mappings of option names to values on line 2"),
            ("sections:\n  - name: [a]", "Value of 'name' must be a string on line 2"),
            ("sections:\n  - indent: 2\n    indent: 4", "Duplicate key 'indent' on line 3"),
            ("indent: !!int 4", "Values starting with '!' must be quoted"),
            ("header: %a", "Values starting with '%' must be quoted"),
            ("header: - a", "Values containing ': ' or starting with '- ' must be quoted on line 1"),
            ("header: a:", "Values containing ': ' or starting with '- ' must be quoted on line 1"),
            ("\"indent\": 4", "Unknown option --\"indent\""),
        ]
        for (yaml, message) in cases {
            XCTAssertThrowsError(try parseYAML(yaml), yaml) { error in
                XCTAssert("\(error)".contains(message), "\(error)")
            }
        }
    }

    func testDeprecatedOptionsMatchTextConfigFile() throws {
        let text = try parseConfigFile(Data("--hexliterals uppercase\n--indent 2".utf8))
        let yaml = try parseYAML("hexliterals: uppercase\nindent: 2")
        XCTAssertEqual(yaml, text)
        XCTAssertFalse(warningsForArguments(yaml[0]).isEmpty)
    }

    func testTextSerializationWithSeparator() {
        let options = Options(formatOptions: FormatOptions(indent: "  ", allmanBraces: true))
        XCTAssertEqual(
            serialize(options: options, excludingDefaults: true, separator: " "),
            "--allman true --indent 2"
        )
        XCTAssertEqual(
            serialize(options: options, excludingDefaults: true, format: YAMLConfigFormat()),
            "allman: true\nindent: 2"
        )
    }

    func testSerializeSwiftVersionWithoutFormatOptions() {
        let options = Options(rules: defaultRules.union(["isEmpty"]))
        XCTAssertEqual(
            serialize(options: options, swiftVersion: "5.10"),
            "--swift-version 5.10\n--enable isEmpty"
        )
        XCTAssertEqual(
            serialize(options: options, swiftVersion: "5.10", format: YAMLConfigFormat()),
            "swift-version: \"5.10\"\nenable:\n  - isEmpty"
        )
    }

    func testYAMLSerializationOfEmptyOptions() {
        XCTAssertEqual(YAMLConfigFormat().serialize([[:], [:]]), "")
        XCTAssertEqual(try YAMLConfigFormat().parse(""), [[]])
    }
}
