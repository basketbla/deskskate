import AppKit

/// The keyboard-mode controls card, drawn at the top centre of a screen.
enum ControlsHUD {

    private struct Row {
        /// Key caps, with plain connector words ("or") written as `nil`-cap text.
        var keys: [Key]
        var text: String
    }

    private enum Key {
        case cap(String)
        case word(String)
    }

    private static let rows: [Row] = [
        Row(keys: [.cap("←"), .cap("→")], text: "Push / turn"),
        Row(keys: [.cap("Space")], text: "Hold to crouch, release to ollie"),
        Row(keys: [.cap("↑"), .word("or"), .cap("F")], text: "Kickflip & other flips (in the air)"),
        Row(keys: [.cap("↓")], text: "Hold while landing to grind"),
        Row(keys: [.cap("R")], text: "Respawn at mouse"),
        Row(keys: [.cap("Esc")], text: "Autonomous mode"),
        Row(keys: [.cap("/")], text: "Hide this card"),
    ]

    private static let title = "Keyboard mode"
    private static let footer = "Drag the skater with the mouse to move him"

    // Layout (points).
    private static let padding: CGFloat = 16
    private static let titleHeight: CGFloat = 18
    private static let titleGap: CGFloat = 10
    private static let rowHeight: CGFloat = 24
    private static let footerGap: CGFloat = 8
    private static let footerHeight: CGFloat = 14
    private static let keyColumn: CGFloat = 92
    private static let textColumn: CGFloat = 228
    private static let capHeight: CGFloat = 19
    private static let topInset: CGFloat = 40

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let textFont = NSFont.systemFont(ofSize: 12.5)
    private static let capFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let footerFont = NSFont.systemFont(ofSize: 11)

    static func size() -> CGSize {
        CGSize(width: padding * 2 + keyColumn + textColumn,
               height: padding * 2 + titleHeight + titleGap + CGFloat(rows.count) * rowHeight
                   + footerGap + footerHeight)
    }

    /// Where the card sits on `screen` (global AppKit coords, full screen frame).
    static func frame(on screen: CGRect) -> CGRect {
        let s = size()
        return CGRect(x: (screen.midX - s.width / 2).rounded(),
                      y: (screen.maxY - topInset - s.height).rounded(),
                      width: s.width, height: s.height)
    }

    static func draw(in ctx: CGContext, screen: CGRect, alpha: CGFloat) {
        guard alpha > 0.001 else { return }
        let card = frame(on: screen)

        ctx.saveGState()
        ctx.setAlpha(max(0, min(1, alpha)))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Card.
        let cardPath = CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(cardPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let white = NSColor.white
        let dim = NSColor(white: 1, alpha: 0.62)
        let left = card.minX + padding
        var y = card.maxY - padding  // top of the next line

        // Title.
        drawText(title, font: titleFont, color: white, x: left, centreY: y - titleHeight / 2)
        y -= titleHeight + titleGap

        // Rows.
        for row in rows {
            let midY = y - rowHeight / 2
            var x = left
            for key in row.keys {
                switch key {
                case .cap(let label):
                    x += drawCap(label, in: ctx, x: x, centreY: midY) + 4
                case .word(let word):
                    x += drawText(word, font: footerFont, color: dim, x: x + 1, centreY: midY) + 6
                }
            }
            drawText(row.text, font: textFont, color: white, x: left + keyColumn, centreY: midY)
            y -= rowHeight
        }

        // Footer.
        y -= footerGap
        drawText(footer, font: footerFont, color: dim, x: left, centreY: y - footerHeight / 2)

        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.current = previous

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: - Pieces

    /// Draws a key cap with its left edge at `x`; returns its width.
    private static func drawCap(_ label: String, in ctx: CGContext, x: CGFloat, centreY: CGFloat) -> CGFloat {
        let attr = NSAttributedString(string: label, attributes: [.font: capFont, .foregroundColor: NSColor.white])
        let textSize = attr.size()
        let w = max(capHeight + 3, ceil(textSize.width) + 12)
        let rect = CGRect(x: x, y: centreY - capHeight / 2, width: w, height: capHeight)

        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        // Little bottom lip so it reads as a key.
        ctx.addPath(CGPath(roundedRect: rect.offsetBy(dx: 0, dy: -1.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
        ctx.setLineWidth(1)
        ctx.strokePath()

        attr.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: centreY - textSize.height / 2))
        return w
    }

    /// Draws one line vertically centred on `centreY`; returns its width.
    @discardableResult
    private static func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, centreY: CGFloat) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = attr.size()
        attr.draw(at: CGPoint(x: x, y: centreY - sz.height / 2))
        return ceil(sz.width)
    }
}
