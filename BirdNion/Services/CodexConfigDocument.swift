import Foundation

/// Small TOML-aware editor for the exact top-level keys BirdNion owns. It
/// avoids reformatting unrelated Codex configuration, which may contain
/// comments, tables, MCP servers, or user-authored settings.
enum CodexConfigDocument {
    private static let selectionStart = "# >>> BirdNion Codex selection >>>"
    private static let selectionEnd = "# <<< BirdNion Codex selection <<<"
    private static let providerStart = "# >>> BirdNion Codex provider >>>"
    private static let providerEnd = "# <<< BirdNion Codex provider <<<"

    static func rootAssignments(in contents: String) -> (String?, String?) {
        var model: String?
        var provider: String?
        var insideTable = false
        for line in lines(contents) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isTableHeader(trimmed) { insideTable = true }
            guard !insideTable, let key = assignmentKey(line) else { continue }
            if key == "model", model == nil { model = line }
            if key == "model_provider", provider == nil { provider = line }
        }
        return (model, provider)
    }

    static func removeRootAssignments(from contents: String) -> String {
        var insideTable = false
        let kept = lines(contents).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isTableHeader(trimmed) { insideTable = true }
            guard !insideTable, let key = assignmentKey(line) else { return true }
            return key != "model" && key != "model_provider"
        }
        return joined(kept)
    }

    static func removeManagedSections(from contents: String) -> String {
        let withoutSelection = removingBlock(start: selectionStart, end: selectionEnd, from: contents)
        return removingBlock(start: providerStart, end: providerEnd, from: withoutSelection)
    }

    static func hasManagedSections(_ contents: String) -> Bool {
        hasBlock(start: selectionStart, end: selectionEnd, in: contents)
            && hasBlock(start: providerStart, end: providerEnd, in: contents)
    }

    static func applying(_ configuration: CodexProviderConfiguration, to contents: String) -> String {
        let selection = [
            selectionStart,
            "model = \(tomlString(configuration.model))",
            "model_provider = \(tomlString(configuration.providerID))",
            selectionEnd,
            "",
        ]
        let withSelection = insertingAtRoot(selection, into: contents)
        let provider = [
            providerStart,
            "[model_providers.\(configuration.providerID)]",
            "name = \(tomlString(configuration.providerName))",
            "base_url = \(tomlString(configuration.baseURL))",
            "experimental_bearer_token = \(tomlString(configuration.bearerToken))",
            "wire_api = \"responses\"",
            providerEnd,
        ].joined(separator: "\n")
        let body = withSelection.trimmingCharacters(in: .newlines)
        return body.isEmpty ? provider + "\n" : body + "\n\n" + provider + "\n"
    }

    static func insertingRootAssignments(modelLine: String?, providerLine: String?, into contents: String) -> String {
        let assignments = [modelLine, providerLine].compactMap { $0 }
        guard !assignments.isEmpty else { return contents }
        return insertingAtRoot(assignments + [""], into: contents)
    }

    static func containsManagedConfiguration(_ contents: String,
                                             configuration: CodexProviderConfiguration) -> Bool {
        let selection = [
            selectionStart,
            "model = \(tomlString(configuration.model))",
            "model_provider = \(tomlString(configuration.providerID))",
            selectionEnd,
        ].joined(separator: "\n")
        let provider = [
            providerStart,
            "[model_providers.\(configuration.providerID)]",
            "base_url = \(tomlString(configuration.baseURL))",
            "experimental_bearer_token = \(tomlString(configuration.bearerToken))",
            "wire_api = \"responses\"",
            providerEnd,
        ]
        return contents.contains(selection) && provider.allSatisfy(contents.contains)
    }

    private static func removingBlock(start: String, end: String, from contents: String) -> String {
        var output = lines(contents)
        guard let startIndex = output.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == start
        }), let endIndex = output[startIndex...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == end
        }) else {
            // A manually damaged marker must never cause BirdNion to discard
            // the remainder of a user's config file.
            return contents
        }
        output.removeSubrange(startIndex...endIndex)
        return joined(output)
    }

    private static func hasBlock(start: String, end: String, in contents: String) -> Bool {
        let source = lines(contents)
        guard let startIndex = source.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == start
        }) else { return false }
        return source[startIndex...].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == end
        }
    }

    private static func insertingAtRoot(_ insertion: [String], into contents: String) -> String {
        var output = lines(contents)
        let index = output.firstIndex {
            isTableHeader($0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? output.count
        output.insert(contentsOf: insertion, at: index)
        return joined(output)
    }

    private static func assignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func isTableHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]")
    }

    private static func lines(_ contents: String) -> [String] {
        contents.components(separatedBy: "\n")
    }

    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private static func tomlString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string.replacingOccurrences(of: "\\/", with: "/")
    }
}
