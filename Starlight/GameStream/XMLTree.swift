//
//  XMLTree.swift
//  Starlight
//
//  A tiny XML tree built with XMLParser, used for GameStream HTTP responses.
//

import Foundation

nonisolated final class XMLTree: @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLTree] = []
    fileprivate(set) var value = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLTree? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [XMLTree] {
        children.filter { $0.name == name }
    }

    func text(_ childName: String) -> String? {
        child(childName)?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ data: Data) -> XMLTree? {
        // GFE declares UTF-16 in the prolog while sending UTF-8 bytes
        var data = data
        if let string = String(data: data, encoding: .utf8) {
            data = Data(
                string
                    .replacingOccurrences(of: "encoding=\"UTF-16\"", with: "encoding=\"UTF-8\"")
                    .replacingOccurrences(of: "encoding=\"utf-16\"", with: "encoding=\"utf-8\"")
                    .utf8
            )
        }

        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }
}

nonisolated private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTree?
    private var stack: [XMLTree] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let element = XMLTree(name: elementName, attributes: attributes)
        if let parent = stack.last {
            parent.children.append(element)
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.value += string
    }
}
