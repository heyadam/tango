import CoreGraphics
import PaperEngine
import PaperModel

/// Geometry of one patch in the Patch Editor, in graph coordinates (y-down).
/// Inputs are listed first, then outputs, one per row.
struct PatchLayout {
    // Every measure is a whole number of grid units (12), so ports land on the grid.
    // The model keeps them (`PatchGrid`), so a document can find room for a patch itself.
    static let width = CGFloat(PatchGrid.nodeWidth)
    static let titleHeight = CGFloat(PatchGrid.titleHeight)
    static let subtitleHeight = CGFloat(PatchGrid.subtitleHeight)
    static let rowHeight = CGFloat(PatchGrid.rowHeight)
    static let bottomPadding = CGFloat(PatchGrid.bottomPadding)
    static let cornerRadius: CGFloat = 10
    static let portRadius: CGFloat = 5
    static let valueWidth: CGFloat = 76

    let node: PatchNode
    let ports: NodePorts

    var hasSubtitle: Bool { node.layerID != nil }

    var headerHeight: CGFloat {
        PatchLayout.titleHeight + (hasSubtitle ? PatchLayout.subtitleHeight : 0)
    }

    var size: CGSize {
        let rows = CGFloat(ports.inputs.count + ports.outputs.count)
        return CGSize(
            width: PatchLayout.width,
            height: headerHeight + rows * PatchLayout.rowHeight + PatchLayout.bottomPadding
        )
    }

    var frame: CGRect {
        CGRect(origin: CGPoint(x: node.position.x, y: node.position.y), size: size)
    }

    var headerRect: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: headerHeight)
    }

    func inputRow(_ index: Int) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.minY + headerHeight + CGFloat(index) * PatchLayout.rowHeight,
            width: frame.width,
            height: PatchLayout.rowHeight
        )
    }

    func outputRow(_ index: Int) -> CGRect {
        inputRow(ports.inputs.count + index)
    }

    func inputPort(_ index: Int) -> CGPoint {
        CGPoint(x: frame.minX, y: inputRow(index).midY)
    }

    func outputPort(_ index: Int) -> CGPoint {
        CGPoint(x: frame.maxX, y: outputRow(index).midY)
    }

    /// Where an unconnected input shows its editable value.
    func inputValueRect(_ index: Int) -> CGRect {
        let row = inputRow(index)
        return CGRect(
            x: row.maxX - PatchLayout.valueWidth - 8,
            y: row.minY + 2,
            width: PatchLayout.valueWidth,
            height: row.height - 4
        )
    }

    func inputPortCenter(id: String) -> CGPoint? {
        ports.inputs.firstIndex { $0.id == id }.map(inputPort)
    }

    func outputPortCenter(id: String) -> CGPoint? {
        ports.outputs.firstIndex { $0.id == id }.map(outputPort)
    }
}
