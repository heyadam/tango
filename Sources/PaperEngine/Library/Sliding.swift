import Foundation
import PaperModel

extension ComponentLibrary {
    /// A pill that slides to the chosen copy of a repeated view and stretches on its way, as
    /// a segmented control's and a tab bar's do on iOS 26 (held against the real ones by
    /// `REFERENCE_MOTION=1 Reference/run.sh`).
    ///
    /// Each edge follows two springs, a quick one and a slow one, and takes whichever is
    /// further out: so the edge in front leads and the one behind catches up, whichever way
    /// it goes. It reads where the copies are from their view patch's frame outputs, so it
    /// fits copies of any width. Until the choice first changes it stands on the chosen copy
    /// with no spring, so it never slides in from the corner when the control appears.
    struct Sliding {
        /// For each copy, how much of it the pill covers, 0 to 1 (a loop).
        let coverage: NodeID

        /// Builds it all from `column`, `row` on. `outset` is how far the pill reaches past
        /// the copy on each side (left, top, right, bottom).
        init(
            _ b: inout Builder, repeated: LayerID, pill: LayerID, chosen: NodeID,
            outset: (left: Double, top: Double, right: Double, bottom: Double) = (0, 0, 0, 0),
            quick: Double, slow: Double, damping: Double, column: Double, row: Double
        ) {
            func place(_ c: Double, _ r: Double) -> Point2 { at(column + c, row + r) }
            let copies = b.view(repeated)
            func chosenFrame(_ port: String, _ r: Double) -> NodeID {
                let pick = b.add("loopSelect", at: place(0, r), name: "Chosen \(port.dropFirst(5))", type: .number)
                b.connect(copies, port, to: pick, "loop")
                b.connect(chosen, "option", to: pick, "index")
                return pick
            }
            let x = chosenFrame("frameX", 0), y = chosenFrame("frameY", 1), width = chosenFrame("frameWidth", 2), height = chosenFrame("frameHeight", 3)
            let left = b.add("add", at: place(1, 0), name: "Left", inputs: ["b": .number(-outset.left)])
            b.connect(x, "value", to: left, "a")
            let end = b.add("add", at: place(1, 1), name: "End")
            b.connect(x, "value", to: end, "a")
            b.connect(width, "value", to: end, "b")
            let right = b.add("add", at: place(1, 2), name: "Right", inputs: ["b": .number(outset.right)])
            b.connect(end, "result", to: right, "a")

            // The choice has moved once: from then on the springs show.
            let moved = b.add("switch", at: place(1, 3), name: "Moved")
            b.connect(chosen, "changed", to: moved, "turnOn")
            // Until then the springs follow at once, so they are already on the chosen copy
            // when the frames arrive (a frame late) and nothing moves as the control appears.
            func response(_ seconds: Double, _ name: String, _ c: Double) -> NodeID {
                let choice = b.add("if", at: place(c, 3), name: name, type: .number, inputs: ["then": .number(seconds), "else": .number(0.01)])
                b.connect(moved, "on", to: choice, "condition")
                return choice
            }
            let quickResponse = response(quick, "Quick Response", 2), slowResponse = response(slow, "Slow Response", 3)
            func edge(_ target: NodeID, _ name: String, outward: String, _ r: Double) -> NodeID {
                let fast = b.add("spring", at: place(2, r), name: "\(name), Quick", inputs: ["damping": .number(damping)])
                let slowly = b.add("spring", at: place(2, r + 1), name: "\(name), Slow", inputs: ["damping": .number(damping)])
                b.connect(target, "result", to: fast, "target")
                b.connect(target, "result", to: slowly, "target")
                b.connect(quickResponse, "value", to: fast, "response")
                b.connect(slowResponse, "value", to: slowly, "response")
                let outer = b.add(outward, at: place(3, r), name: "\(name), Outer")
                b.connect(fast, "value", to: outer, "a")
                b.connect(slowly, "value", to: outer, "b")
                let shown = b.add("if", at: place(4, r), name: "\(name) Shown", type: .number)
                b.connect(moved, "on", to: shown, "condition")
                b.connect(outer, "result", to: shown, "then")
                b.connect(target, "result", to: shown, "else")
                return shown
            }
            let shownLeft = edge(left, "Left Edge", outward: "min", 4)
            let shownRight = edge(right, "Right Edge", outward: "max", 6)

            let span = b.add("subtract", at: place(5, 4), name: "Pill Width")
            b.connect(shownRight, "value", to: span, "a")
            b.connect(shownLeft, "value", to: span, "b")
            let top = b.add("add", at: place(5, 5), name: "Pill Top", inputs: ["b": .number(-outset.top)])
            b.connect(y, "value", to: top, "a")
            let tall = b.add("add", at: place(5, 6), name: "Pill Height", inputs: ["b": .number(outset.top + outset.bottom)])
            b.connect(height, "value", to: tall, "a")
            let position = b.add("makePoint", at: place(6, 4), name: "Pill Position")
            b.connect(shownLeft, "value", to: position, "x")
            b.connect(top, "result", to: position, "y")
            let size = b.add("makePoint", at: place(6, 5), name: "Pill Size")
            b.connect(span, "result", to: size, "x")
            b.connect(tall, "result", to: size, "y")
            b.connect(position, "point", to: b.property(.position, of: pill, at: place(7, 4)), "value")
            b.connect(size, "point", to: b.property(.size, of: pill, at: place(7, 5)), "value")

            // How much of each copy the pill covers, the pill taken without its outset so a
            // neighbor is not tinted by the part that reaches over it.
            let coreLeft = b.add("add", at: place(5, 8), name: "Core Left", inputs: ["b": .number(outset.left)])
            b.connect(shownLeft, "value", to: coreLeft, "a")
            let coreRight = b.add("add", at: place(5, 9), name: "Core Right", inputs: ["b": .number(-outset.right)])
            b.connect(shownRight, "value", to: coreRight, "a")
            let copyEnd = b.add("add", at: place(6, 7), name: "Copy End")
            b.connect(copies, "frameX", to: copyEnd, "a")
            b.connect(copies, "frameWidth", to: copyEnd, "b")
            let overlapEnd = b.add("min", at: place(6, 8), name: "Overlap End")
            b.connect(coreRight, "result", to: overlapEnd, "a")
            b.connect(copyEnd, "result", to: overlapEnd, "b")
            let overlapStart = b.add("max", at: place(6, 9), name: "Overlap Start")
            b.connect(coreLeft, "result", to: overlapStart, "a")
            b.connect(copies, "frameX", to: overlapStart, "b")
            let overlap = b.add("subtract", at: place(7, 8), name: "Overlap")
            b.connect(overlapEnd, "result", to: overlap, "a")
            b.connect(overlapStart, "result", to: overlap, "b")
            let share = b.add("divide", at: place(7, 9), name: "Share Covered")
            b.connect(overlap, "result", to: share, "a")
            b.connect(copies, "frameWidth", to: share, "b")
            coverage = b.add("clamp", at: place(8, 8), name: "Coverage", inputs: ["min": .number(0), "max": .number(1)])
            b.connect(share, "result", to: coverage, "value")
        }
    }
}
