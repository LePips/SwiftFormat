//
//  ConfigFormat.swift
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

/// A syntax in which SwiftFormat config files can be written
protocol ConfigFormat {
    /// Parses the contents of a config file into sections, each of which is
    /// a flat list of command-line arguments, e.g. `["--indent", "4"]`
    func parse(_ input: String) throws -> [[String]]

    /// Serializes groups of arguments into the contents of a config file
    func serialize(_ arguments: [[String: String]]) -> String
}

/// Returns the format of a config file, based on its file extension
func configFormat(for url: URL) -> ConfigFormat {
    switch url.pathExtension.lowercased() {
    case "yml", "yaml":
        return YAMLConfigFormat()
    default:
        return TextConfigFormat()
    }
}

/// Parse a configuration file into a list of argument dictionaries.
///
/// Config files can have headers that separate them into separate sections.
/// Each section is treated as if it were its own file. For example:
/// ```
/// --indent 4
///
/// [Tests]
/// --filter **/Tests/**
/// --indent 2
/// ```
public func parseConfigFile(_ data: Data, logger: Logger? = nil) throws -> [[String: String]] {
    try parseConfigFile(data, format: TextConfigFormat(), logger: logger)
}

/// Parse a configuration file in the specified format into a list of argument dictionaries
func parseConfigFile(_ data: Data, format: ConfigFormat, logger: Logger? = nil) throws -> [[String: String]] {
    guard var input = String(data: data, encoding: .utf8) else {
        throw FormatError.reading("Unable to read data for configuration file")
    }
    // Not all Foundation implementations strip the UTF-8 byte order mark
    if input.unicodeScalars.first == "\u{FEFF}" {
        input.unicodeScalars.removeFirst()
    }

    var configOptions = [[String: String]]()
    var unknownOptions = UnknownOptionsMode.error

    for arguments in try format.parse(input) {
        do {
            try configOptions.append(preprocessArguments(
                arguments,
                optionsArguments,
                unknownOptions: unknownOptions,
                logger: logger.map { logger in
                    Logger { message, type in
                        logger.print(type == .warning ? "\(message) in configuration file" : message, type)
                    }
                }
            ))
            unknownOptions = unknownOptionsMode(in: arguments) ?? unknownOptions
        } catch let FormatError.options(message) {
            throw FormatError.options("\(message) in configuration file")
        }
    }

    return configOptions
}

/// Serialize a set of options into either an arguments string or a file
public func serialize(options: Options,
                      swiftVersion: Version = .undefined,
                      excludingDefaults: Bool = false,
                      separator: String = "\n") -> String
{
    serialize(
        options: options,
        swiftVersion: swiftVersion,
        excludingDefaults: excludingDefaults,
        format: TextConfigFormat(separator: separator)
    )
}

/// Serialize a set of options into a config file in the specified format,
/// with the file, format and rules options in separate groups
func serialize(options: Options,
               swiftVersion: Version = .undefined,
               excludingDefaults: Bool = false,
               format: ConfigFormat) -> String
{
    var arguments = [[String: String]]()
    if let fileOptions = options.fileOptions {
        arguments.append(argumentsFor(
            Options(fileOptions: fileOptions),
            excludingDefaults: excludingDefaults
        ))
    }
    if let formatOptions = options.formatOptions {
        arguments.append(argumentsFor(
            Options(formatOptions: formatOptions),
            excludingDefaults: excludingDefaults
        ))
    } else if swiftVersion != .undefined {
        let descriptor = Descriptors.swiftVersion
        arguments.append([descriptor.argumentName: swiftVersion.rawValue])
    }
    if let rules = options.rules {
        arguments.append(argumentsFor(
            Options(rules: rules),
            excludingDefaults: excludingDefaults
        ))
    }
    return format.serialize(arguments)
}

/// The `.swiftformat` config file format, consisting of command-line options split onto separate lines
struct TextConfigFormat: ConfigFormat {
    /// The separator between serialized options
    var separator = "\n"

    func parse(_ input: String) throws -> [[String]] {
        let lines = try cumulate(successiveLines: input.components(separatedBy: .newlines))

        let configSegments = lines.split(whereSeparator: { line in
            line.starts(with: "[") && line.contains("]")
        })

        return try configSegments.map { configSegmentLines in
            try configSegmentLines.flatMap { line -> [String] in
                // TODO: parseArguments isn't a perfect fit here - should we use a different approach?
                let line = line.replacingOccurrences(of: "\\n", with: "\n")
                let parts = parseArguments(line, ignoreComments: false).dropFirst().map {
                    $0.replacingOccurrences(of: "\n", with: "\\n")
                }
                guard let key = parts.first else {
                    return []
                }
                if !key.hasPrefix("-") {
                    throw FormatError.options("Unknown option '\(key)' in configuration file")
                }
                return [key, parts.dropFirst().joined(separator: " ")]
            }
        }
    }

    func serialize(_ arguments: [[String: String]]) -> String {
        arguments
            .map { arguments in
                arguments.map {
                    var value = $1
                    if value.contains(" ") {
                        value = "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
                    }
                    if value.contains("#") {
                        value = "\"\(value)\""
                    }
                    return "--\($0) \(value)"
                }.sorted().joined(separator: separator)
            }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    private func cumulate(successiveLines: [String]) throws -> [String] {
        var cumulatedLines = [String]()
        var iterator = successiveLines.makeIterator()
        while let currentLine = iterator.next() {
            var cumulatedLine = contentBeforeUnquotedComment(in: currentLine).trimmingCharacters(in: .whitespaces)
            while cumulatedLine.hasSuffix("\\") {
                guard let nextLine = iterator.next() else {
                    throw FormatError.reading("Configuration file ends with an illegal line continuation character '\'")
                }
                if !nextLine.trimmingCharacters(in: .whitespaces).starts(with: "#") {
                    cumulatedLine = cumulatedLine.dropLast() + contentBeforeUnquotedComment(in: nextLine).trimmingCharacters(in: .whitespaces)
                }
            }
            cumulatedLines.append(String(cumulatedLine))
        }
        return cumulatedLines
    }
}
