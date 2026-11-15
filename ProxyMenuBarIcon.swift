import Cocoa

enum ProxyMenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // Preserve the app's terminal mark without its background or shadows.
            let terminal = NSBezierPath()
            terminal.lineWidth = 1.9
            terminal.lineCapStyle = .round
            terminal.lineJoinStyle = .round
            terminal.move(to: NSPoint(x: 4.5, y: 15.5))
            terminal.line(to: NSPoint(x: 9, y: 11.5))
            terminal.line(to: NSPoint(x: 4.5, y: 7.5))
            terminal.stroke()
            let underscore = NSBezierPath()
            underscore.lineWidth = 1.7
            underscore.lineCapStyle = .round
            underscore.move(to: NSPoint(x: 10.5, y: 7.5))
            underscore.line(to: NSPoint(x: 14.5, y: 7.5))
            underscore.stroke()
            // Three connected nodes retain the proxy/network identity.
            let link = NSBezierPath()
            link.lineWidth = 1.1
            link.move(to: NSPoint(x: 3, y: 3))
            link.line(to: NSPoint(x: 15, y: 3))
            link.stroke()
            for x: CGFloat in [3, 9, 15] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: 1.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ChatGPT Proxy"
        return image
    }
}
