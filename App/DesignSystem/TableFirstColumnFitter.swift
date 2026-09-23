import AppKit
import SwiftUI

extension View {
    /// Keeps one column of a SwiftUI `Table` exactly as wide as the space the other
    /// columns leave, so the table never scrolls sideways.
    ///
    /// That column must be flexible (`.width(min:)`). A fixed width computed in
    /// SwiftUI becomes the column's AppKit `minWidth`, which then props the split view
    /// open when the inspector appears. NSTableView shrinks flexible columns on resize
    /// but sizes them too wide initially, so this corrects the width from AppKit.
    /// `columnsKey` changes whenever columns are added or removed.
    func fitsTableColumn(_ index: Int = 0, columnsKey: Int) -> some View {
        background(TableFirstColumnFitter(columnIndex: index, columnsKey: columnsKey))
    }
}

private struct TableFirstColumnFitter: NSViewRepresentable {
    let columnIndex: Int
    let columnsKey: Int

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.columnIndex = columnIndex
        view.scheduleFit()
    }

    final class FitterView: NSView {
        var columnIndex = 0
        private weak var table: NSTableView?
        private var fitScheduled = false

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize.width != frame.width
            super.setFrameSize(newSize)
            if changed { scheduleFit() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFit()
        }

        func scheduleFit() {
            // Coalesce SwiftUI updates and AppKit frame changes into one layout correction.
            guard !fitScheduled else { return }
            fitScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fitScheduled = false
                self.fit()
            }
        }

        private func fit() {
            guard window != nil, let table = table ?? locateTable(), table.numberOfColumns > 1,
                  table.tableColumns.indices.contains(columnIndex) else { return }
            self.table = table
            let first = table.tableColumns[columnIndex]
            // The background view has the table's SwiftUI frame; the scroll view itself
            // extends under the sidebar and inspector, so its own width can't be used.
            let lastMaxX = table.rect(ofColumn: table.numberOfColumns - 1).maxX
            let trailingInset = table.frame.width - table.rect(ofColumn: table.numberOfColumns - 1).maxX
            let target = frame.width - max(trailingInset, 0)
            let width = max(first.minWidth, (first.width + target - lastMaxX).rounded(.down))
            if abs(width - first.width) >= 1 { first.width = width }
        }

        /// The table is a sibling of this background view inside the same SwiftUI host.
        private func locateTable() -> NSTableView? {
            var node: NSView? = superview
            for _ in 0..<4 {
                guard let current = node else { return nil }
                if let table = Self.firstTable(in: current) { return table }
                node = current.superview
            }
            return nil
        }

        private static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = firstTable(in: subview) { return table }
            }
            return nil
        }
    }
}
