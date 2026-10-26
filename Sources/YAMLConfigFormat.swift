//
//  YAMLConfigFormat.swift
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

import Foundation

/// The YAML config file format, e.g.
/// ```
/// indent: 4
/// disable: [redundantSelf, trailingCommas]
/// sections:
///   - name: Tests
///     filter: "**/Tests/**"
///     indent: 2
/// ```
/// Only the subset of YAML needed to express SwiftFormat options is supported. Values are always
/// treated as strings, and lists are passed to options as comma-delimited values.
struct YAMLConfigFormat: ConfigFormat {
    func parse(_ input: String) throws -> [[String]] {
        var parser = YAMLParser(input)
        let document = try parser.parseDocument()
        guard case let .mapping(entries) = document.value else {
            throw yamlError("Expected a mapping of option names to values", line: document.line)
        }

        var arguments = [String]()
        var sections = [[String]]()
        for (key, value) in entries {
            guard key == "sections" else {
                arguments += try optionArguments(key, value)
                continue
            }
            guard case let .sequence(items) = value.value else {
                throw yamlError("Value of 'sections' must be a list", line: value.line)
            }
            for item in items {
                guard case let .mapping(entries) = item.value else {
                    throw yamlError("Items in 'sections' must be mappings of option names to values", line: item.line)
                }
                var section = [String]()
                for (key, value) in entries {
                    switch key {
                    case "name":
                        // Section names are only used to document the section
                        guard case .scalar = value.value else {
                            throw yamlError("Value of 'name' must be a string", line: value.line)
                        }
                    case "sections":
                        throw yamlError("Sections can't be nested", line: value.line)
                    default:
                        section += try optionArguments(key, value)
                    }
                }
                sections.append(section)
            }
        }
        return [arguments] + sections
    }

    func serialize(_ arguments: [[String: String]]) -> String {
        arguments.flatMap { arguments in
            arguments.sorted(by: { $0.key < $1.key }).map { key, value -> String in
                guard isListArgument(key) else {
                    return "\(key): \(yamlScalar(value))"
                }
                let items = parseCommaDelimitedList(value)
                if items.isEmpty {
                    return "\(key): []"
                }
                return "\(key):\n" + items.map { "  - \(yamlScalar($0))" }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// Converts a YAML option into command-line arguments
    private func optionArguments(_ key: String, _ value: YAMLNode) throws -> [String] {
        var string: String
        switch value.value {
        case let .scalar(scalar):
            string = scalar
        case let .sequence(items):
            string = try items.map { item -> String in
                guard case let .scalar(scalar) = item.value else {
                    throw yamlError("Items in '\(key)' must be strings", line: item.line)
                }
                if scalar.contains(",") {
                    throw yamlError("Items in '\(key)' can't contain commas", line: item.line)
                }
                return scalar
            }.joined(separator: ",")
        case .mapping:
            throw yamlError("Value of '\(key)' must be a string or a list", line: value.line)
        }
        // Line breaks are passed to options as `\n`, matching the text config format
        return ["--\(key)", string.replacingOccurrences(of: "\n", with: "\\n")]
    }

    /// Whether the argument takes a comma-delimited list of values
    private func isListArgument(_ name: String) -> Bool {
        switch Descriptors.byName[name]?.type {
        case .array?, .set?:
            return true
        default:
            return listArguments.contains(name)
        }
    }

    /// Formats a value as a YAML scalar, quoting it unless it can't be misread
    private func yamlScalar(_ value: String) -> String {
        let isPlain = value.range(of: "^([A-Za-z_][A-Za-z0-9_./-]*|0|[1-9][0-9]*)$", options: .regularExpression) != nil
        if isPlain, !["y", "n", "yes", "no", "on", "off", "null"].contains(value.lowercased()) {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private func yamlError(_ message: String, line: Int) -> FormatError {
    .options("\(message) on line \(line) of configuration file")
}

private struct YAMLNode {
    enum Value {
        case scalar(String)
        case sequence([YAMLNode])
        case mapping([(key: String, value: YAMLNode)])
    }

    var value: Value
    var line: Int
}

/// Parses block mappings, block and flow sequences, plain, quoted and block scalars, and comments
private struct YAMLParser {
    private struct Line {
        var number: Int
        var indent: Int
        /// The line with its indentation removed
        var content: Substring
        /// The whole line, used for block scalars
        var text: Substring
    }

    private var lines: [Line]
    private var index = 0

    init(_ input: String) {
        let input = input.replacingOccurrences(of: "\r\n", with: "\n")
        lines = input.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, text in
            let content = text.drop(while: { $0 == " " })
            return Line(number: offset + 1, indent: text.count - content.count, content: content, text: text)
        }
    }

    mutating func parseDocument() throws -> YAMLNode {
        if let line = try nextLine(), isDocumentStart(line) {
            try checkEndOfLine(line.content.dropFirst(3), line: line)
            index += 1
        }
        guard let line = try nextLine() else {
            return YAMLNode(value: .mapping([]), line: 1)
        }
        let document = try parseBlock(indent: line.indent)
        if let line = try nextLine() {
            throw yamlError(
                isDocumentStart(line) ? "Multiple YAML documents are not supported" : "Unexpected indentation",
                line: line.number
            )
        }
        return document
    }

    /// Returns the next line containing content, skipping blank lines and comments
    private mutating func nextLine() throws -> Line? {
        while index < lines.count {
            let line = lines[index]
            let content = line.content.drop(while: { $0 == " " || $0 == "\t" })
            if !content.isEmpty, !content.hasPrefix("#") {
                if line.content.hasPrefix("\t") {
                    throw yamlError("Tabs can't be used for indentation", line: line.number)
                }
                return line
            }
            index += 1
        }
        return nil
    }

    /// Whether the line is a `---` document marker
    private func isDocumentStart(_ line: Line) -> Bool {
        line.indent == 0 && line.content.hasPrefix("---") &&
            (line.content.count == 3 || " \t".contains(line.content.dropFirst(3).first!))
    }

    private func isSequenceItem(_ line: Line) -> Bool {
        line.content == "-" || line.content.hasPrefix("- ")
    }

    /// Throws if there is anything other than whitespace or a comment
    private func checkEndOfLine(_ text: Substring, line: Line) throws {
        let text = text.drop(while: { $0 == " " || $0 == "\t" })
        if !text.isEmpty, !text.hasPrefix("#") {
            throw yamlError("Unexpected '\(text)'", line: line.number)
        }
    }

    private mutating func parseBlock(indent: Int) throws -> YAMLNode {
        if let line = try nextLine(), isSequenceItem(line) {
            return try parseSequence(indent: indent)
        }
        return try parseMapping(indent: indent)
    }

    private mutating func parseMapping(indent: Int) throws -> YAMLNode {
        var entries = [(key: String, value: YAMLNode)]()
        let startLine = try nextLine()?.number ?? 1
        while let line = try nextLine(), line.indent >= indent, !isDocumentStart(line) {
            guard line.indent == indent else {
                throw yamlError("Unexpected indentation", line: line.number)
            }
            let separator = isSequenceItem(line) ? nil : keySeparator(in: line.content)
            let key = separator.map { line.content[..<$0].trimmingCharacters(in: .whitespaces) } ?? ""
            guard let colon = separator, !key.isEmpty, !key.hasPrefix("-") else {
                var message = "Expected 'name: value'"
                if line.content.hasPrefix("-"), !isSequenceItem(line) {
                    message += ". YAML config files don't use a leading '--' before option names, e.g. 'indent: 4'"
                }
                throw yamlError(message, line: line.number)
            }
            if entries.contains(where: { $0.key == key }) {
                throw yamlError("Duplicate key '\(key)'", line: line.number)
            }
            index += 1
            let value = try parseValue(
                line.content[line.content.index(after: colon)...],
                indent: indent,
                line: line
            )
            entries.append((key, value))
        }
        return YAMLNode(value: .mapping(entries), line: startLine)
    }

    /// Returns the index of the colon separating a key from its value
    private func keySeparator(in content: Substring) -> Substring.Index? {
        var start = content.startIndex
        while let colon = content[start...].firstIndex(of: ":") {
            let next = content.index(after: colon)
            if next == content.endIndex || " \t".contains(content[next]) {
                return colon
            }
            start = next
        }
        return nil
    }

    private mutating func parseSequence(indent: Int) throws -> YAMLNode {
        var items = [YAMLNode]()
        let startLine = try nextLine()?.number ?? 1
        while let line = try nextLine(), line.indent == indent, isSequenceItem(line) {
            let spaces = line.content.dropFirst().prefix(while: { $0 == " " }).count
            let text = line.content.dropFirst(1 + spaces)
            if text.isEmpty || text.hasPrefix("#") {
                // Item is a nested block on the following lines, or empty
                index += 1
                if let next = try nextLine(), next.indent > indent {
                    try items.append(parseBlock(indent: next.indent))
                } else {
                    items.append(YAMLNode(value: .scalar(""), line: line.number))
                }
            } else if !"\"'[".contains(text.first!), keySeparator(in: text) != nil {
                // Item is a mapping that starts on the same line as the dash
                let itemIndent = indent + 1 + spaces
                lines[index].indent = itemIndent
                lines[index].content = text
                try items.append(parseMapping(indent: itemIndent))
            } else {
                index += 1
                try items.append(parseValue(text, indent: indent, line: line))
            }
        }
        return YAMLNode(value: .sequence(items), line: startLine)
    }

    /// Parses the value following a key or dash, which may continue onto subsequent lines
    private mutating func parseValue(_ text: Substring, indent: Int, line: Line) throws -> YAMLNode {
        let text = text.drop(while: { $0 == " " || $0 == "\t" })
        if text.isEmpty || text.hasPrefix("#") {
            // Value is a nested block on the following lines, or empty. A sequence nested inside
            // a mapping can have the same indent as the mapping keys.
            if let next = try nextLine(), !isDocumentStart(next),
               next.indent > indent || (next.indent == indent && isSequenceItem(next))
            {
                return try parseBlock(indent: next.indent)
            }
            return YAMLNode(value: .scalar(""), line: line.number)
        }
        switch text.first {
        case "|", ">":
            return try parseBlockScalar(text, indent: indent, line: line)
        case "[":
            return try parseFlowSequence(text, indent: indent, line: line)
        default:
            return try YAMLNode(value: .scalar(parseScalar(text, line: line)), line: line.number)
        }
    }

    /// Parses a literal (`|`) or folded (`>`) block scalar. Trailing line breaks aren't
    /// meaningful for any option, so they are always removed and chomping indicators are ignored.
    private mutating func parseBlockScalar(_ header: Substring, indent: Int, line: Line) throws -> YAMLNode {
        let isFolded = header.first == ">"
        var rest = header.dropFirst()
        if let first = rest.first, "+-".contains(first) {
            rest = rest.dropFirst()
        }
        if let first = rest.first, first.isNumber {
            throw yamlError("Block scalar indentation indicators are not supported", line: line.number)
        }
        try checkEndOfLine(rest, line: line)

        var contentLines = [Substring]()
        var contentIndent: Int?
        while index < lines.count {
            let next = lines[index]
            if next.text.allSatisfy({ $0 == " " }) {
                contentLines.append("")
                index += 1
                continue
            }
            let blockIndent = contentIndent ?? next.indent
            guard next.indent > indent, next.indent >= blockIndent else {
                break
            }
            if isFolded, next.indent > blockIndent {
                throw yamlError("More-indented lines in folded block scalars are not supported", line: next.number)
            }
            contentIndent = blockIndent
            contentLines.append(next.text.dropFirst(blockIndent))
            index += 1
        }

        while contentLines.last == "" {
            contentLines.removeLast()
        }
        var value = ""
        if isFolded {
            var previousLineIsEmpty = true
            for contentLine in contentLines {
                if contentLine.isEmpty {
                    value += "\n"
                } else {
                    value += (previousLineIsEmpty ? "" : " ") + contentLine
                }
                previousLineIsEmpty = contentLine.isEmpty
            }
        } else {
            value = contentLines.joined(separator: "\n")
        }
        return YAMLNode(value: .scalar(value), line: line.number)
    }

    /// Parses a flow sequence such as `[a, "b"]`, which may span multiple lines
    private mutating func parseFlowSequence(_ text: Substring, indent: Int, line: Line) throws -> YAMLNode {
        var text = String(text)
        while true {
            if let items = try parseFlowItems(text, line: line) {
                return YAMLNode(value: .sequence(items), line: line.number)
            }
            // Continuation lines must be indented, apart from the closing bracket
            guard index < lines.count, lines[index].indent > indent ||
                (lines[index].indent == indent && lines[index].content.hasPrefix("]")) ||
                lines[index].content.allSatisfy({ " \t".contains($0) }) ||
                lines[index].content.hasPrefix("#")
            else {
                throw yamlError("Missing closing ']'", line: line.number)
            }
            text += "\n" + lines[index].content
            index += 1
        }
    }

    /// Parses the items of a flow sequence, or returns nil if the closing bracket hasn't been reached
    private func parseFlowItems(_ text: String, line: Line) throws -> [YAMLNode]? {
        var text = Substring(text).dropFirst()
        var items = [YAMLNode]()
        var expectingItem = true
        while true {
            text = text.drop(while: { " \t\n".contains($0) })
            if text.hasPrefix("#") {
                text = text.drop(while: { $0 != "\n" })
                continue
            }
            guard let first = text.first else {
                return nil
            }
            if first == "]" {
                try checkEndOfLine(text.dropFirst(), line: line)
                return items
            }
            if !expectingItem {
                guard first == "," else {
                    throw yamlError("Expected ',' or ']'", line: line.number)
                }
                text = text.dropFirst()
                expectingItem = true
                continue
            }
            var value: String
            switch first {
            case ",":
                throw yamlError("Unexpected ','", line: line.number)
            case "[", "{":
                throw yamlError("Nested lists and mappings are not supported", line: line.number)
            case "\"", "'":
                let scalar = try parseQuotedScalar(text, line: line)
                value = scalar.0
                text = scalar.1
            default:
                var end = text.firstIndex(where: { ",]\n".contains($0) }) ?? text.endIndex
                if let comment = text[..<end].range(of: " #") {
                    end = comment.lowerBound
                }
                value = text[..<end].trimmingCharacters(in: .whitespaces)
                try validatePlainScalar(value, line: line)
                text = text[end...]
            }
            items.append(YAMLNode(value: .scalar(value), line: line.number))
            expectingItem = false
        }
    }

    /// Parses a plain or quoted scalar that ends at the end of the line
    private func parseScalar(_ text: Substring, line: Line) throws -> String {
        if "\"'".contains(text.first!) {
            let (value, rest) = try parseQuotedScalar(text, line: line)
            try checkEndOfLine(rest, line: line)
            return value
        }
        var value = text
        if let comment = value.range(of: " #") ?? value.range(of: "\t#") {
            value = value[..<comment.lowerBound]
        }
        let scalar = value.trimmingCharacters(in: .whitespaces)
        try validatePlainScalar(scalar, line: line)
        return scalar
    }

    /// Throws if the value can't be used without quotes
    private func validatePlainScalar(_ value: String, line: Line) throws {
        if let first = value.first, "*&!%@`{}[],|>\"'".contains(first) {
            throw yamlError("Values starting with '\(first)' must be quoted, e.g. \"\(value)\"", line: line.number)
        }
        if value.hasPrefix("- ") || value.hasPrefix("? ") || value.contains(": ") || value.hasSuffix(":") {
            throw yamlError("Values containing ': ' or starting with '- ' must be quoted", line: line.number)
        }
    }

    /// Parses a single or double quoted scalar, returning its value and the remaining text
    private func parseQuotedScalar(_ text: Substring, line: Line) throws -> (String, Substring) {
        let quote = text.first!
        var text = text.dropFirst()
        var value = ""
        while let char = text.popFirst() {
            switch char {
            case quote:
                if quote == "'", text.first == "'" {
                    text.removeFirst()
                    value.append("'")
                    continue
                }
                return (value, text)
            case "\\" where quote == "\"":
                guard let escape = text.popFirst() else {
                    break
                }
                switch escape {
                case "\\", "\"", "/", " ":
                    value.append(escape)
                case "n":
                    value.append("\n")
                case "t":
                    value.append("\t")
                case "r":
                    value.append("\r")
                case "0":
                    value.append("\0")
                case "x", "u", "U":
                    let length = ["x": 2, "u": 4, "U": 8][escape]!
                    guard let code = UInt32(text.prefix(length), radix: 16), text.count >= length,
                          let scalar = Unicode.Scalar(code)
                    else {
                        throw yamlError("Invalid escape sequence '\\\(escape)'", line: line.number)
                    }
                    value.unicodeScalars.append(scalar)
                    text = text.dropFirst(length)
                default:
                    throw yamlError("Unsupported escape sequence '\\\(escape)'", line: line.number)
                }
            default:
                value.append(char)
            }
        }
        throw yamlError("Missing closing \(quote)", line: line.number)
    }
}
