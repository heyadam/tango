import Foundation

/// What makes a document a sketch of a screen that lives in code. A coding agent builds the
/// screen here from the code, the person plays with it, and the agent then asks what changed
/// since the starting point and writes that into the code. The app never reads the code.
public struct Sketch: Codable, Hashable, Sendable {
    /// What was sketched, in the agent's words: a file, a view, a repository.
    public var source: String?
    /// The document as it was when it was brought in, or when changes were last carried back.
    public var baseline: Baseline

    public struct Baseline: Codable, Hashable, Sendable {
        public var screen: Layer
        public var graph: Graph
        public var components: [ComponentDefinition]

        public init(_ document: Document) {
            screen = document.screen
            graph = document.graph
            components = document.components
        }

        /// The starting point as a document that can be run and drawn.
        public var document: Document {
            var document = Document(screen: screen, graph: graph)
            document.components = components
            return document
        }
    }

    public init(source: String? = nil, baseline: Baseline) {
        self.source = source
        self.baseline = baseline
    }
}
