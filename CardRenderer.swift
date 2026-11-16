import UIKit
import RealityKit
import CoreImage.CoreImageFilters
import CoreImage.CIFilterBuiltins

// MARK: - Physical + texture spec (numbers come straight from RoloPro's own CSS)

enum CardSpec {
    /// The web card is drawn on a 564 x 288 pt canvas (same as your screenshot). We keep that grid
    /// so every CSS pixel value (26 pt rows, 14/16 pt padding, 34 pt QR button) can be used as-is.
    static let canvas = CGSize(width: 564, height: 288)
    static let renderScale: CGFloat = 4              // 2256 x 1152 px texture: crisp when you lean in

    static let width: Float = 0.14                   // metres (a 5 x 3 in card is 0.127 m; slightly larger reads better in AR)
    static let height: Float = width * Float(canvas.height / canvas.width)
    static let thickness: Float = 0.0015             // real index cards are thinner; this is what makes the edge visible

    // CSS: .card background #fbf0c4, rule colour #e6b72f every 26 px, padding 14px 16px
    static let paper = UIColor(hex: 0xFBF0C4)
    static let rule = UIColor(hex: 0xE6B72F)
    static let ink = UIColor(hex: 0x2B2418)
    static let blue = UIColor(hex: 0x1D5FD1)         // .nm colour
    static let gold = UIColor(hex: 0xF0B823)
    static let goldEdge = UIColor(hex: 0xD9B247)     // .cqr border / shadow
    static let buttonFill = UIColor(hex: 0xFFF7DC)   // .cqr background
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

// MARK: - Fonts (bundle the two TTFs; fallbacks keep it usable without them)

private enum Fonts {
    /// "Special Elite" = the typewriter font RoloPro uses for names. Add SpecialElite-Regular.ttf to the app.
    static func elite(_ size: CGFloat) -> UIFont {
        UIFont(name: "SpecialElite-Regular", size: size) ?? UIFont(name: "AmericanTypewriter", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    /// "Courier Prime" = body font. Add CourierPrime-Regular.ttf to the app.
    static func prime(_ size: CGFloat) -> UIFont {
        UIFont(name: "CourierPrime", size: size) ?? UIFont(name: "Courier", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Renderer

enum CardRenderer {
    private static let row: CGFloat = 26

    // MARK: Front

    /// - Parameter brandHeader: true  = brief layout: "RoloPro" in blue, person's name below in black.
    ///                          false = layout of the live web card: name in blue, "company · title" below.
    static func front(_ c: RoloContact, brandHeader: Bool = true) -> UIImage {
        render(CardSpec.canvas, opaque: true) { g, size in
            paper(g, size)
            let padX: CGFloat = 16, top: CGFloat = 14
            let textW = size.width - padX * 2 - 42            // keep clear of the QR button (CSS: .nm padding-right 42px)
            func rowRect(_ i: Int, lines: Int = 1, x: CGFloat = padX, w: CGFloat? = nil) -> CGRect {
                CGRect(x: x, y: top + CGFloat(i) * row, width: w ?? textW, height: row * CGFloat(lines))
            }

            if brandHeader {
                text("RoloPro", rowRect(0), Fonts.elite(25), CardSpec.blue)
                text(c.name, rowRect(1), Fonts.prime(16), CardSpec.ink)
            } else {
                text(c.name, rowRect(0), Fonts.elite(25), CardSpec.blue)
                let sub = [c.company != c.name ? c.company : "", c.title].filter { !$0.isEmpty }.joined(separator: " · ")
                text(sub, rowRect(1), Fonts.prime(16), CardSpec.ink)
            }

            var i = 2
            func field(_ label: String, _ value: String, lines: Int = 1) {
                let lf = Fonts.prime(12.8), vf = Fonts.prime(16)             // CSS: label .8em, muted at 55 %
                let lw = ceil((label as NSString).size(withAttributes: [.font: lf]).width)
                text(label, rowRect(i, x: padX, w: lw + 2), lf, CardSpec.ink.withAlphaComponent(0.55))
                text(value.isEmpty ? "—" : value,
                     rowRect(i, lines: lines, x: padX + lw + 8, w: size.width - padX * 2 - lw - 8), vf, CardSpec.ink)
                i += lines
            }
            field("Email", c.email)
            field("Tel", c.phone)
            field("WhatsApp", c.whatsappDisplay)
            field("Address", c.addr, lines: 2)                               // wraps like the web .r.x row

            qrButton(g, CGRect(x: size.width - 10 - 34, y: 8, width: 34, height: 34))
        }
    }

    // MARK: Back

    static func back(_ c: RoloContact, defaultCC: String = "") -> UIImage {
        render(CardSpec.canvas, opaque: true) { g, size in
            paper(g, size)
            let tile: CGFloat = 220
            let tr = CGRect(x: (size.width - tile) / 2, y: 12, width: tile, height: tile)

            UIColor.white.setFill()
            UIBezierPath(roundedRect: tr, cornerRadius: 10).fill()
            let border = UIBezierPath(roundedRect: tr.insetBy(dx: 1, dy: 1), cornerRadius: 9)
            border.lineWidth = 2
            UIColor(hex: 0xE3C36A).setStroke()
            border.stroke()

            if let qr = qrModules(for: c, defaultCC: defaultCC), let cg = qr.cgImage {
                // Integer device-pixels per module + 4-module quiet zone => crisp, reliably scannable.
                let n = cg.width
                let tilePx = Int(tile * CardSpec.renderScale)
                let cell = max(1, tilePx / (n + 8))
                let side = CGFloat(cell * n) / CardSpec.renderScale
                g.interpolationQuality = .none
                qr.draw(in: CGRect(x: tr.midX - side / 2, y: tr.midY - side / 2, width: side, height: side))
            }

            text("\(c.name) · RoloPro",
                 CGRect(x: 16, y: tr.maxY + 8, width: size.width - 32, height: row),
                 Fonts.prime(14), CardSpec.ink, align: .center)
        }
    }

    /// 1 px = 1 module bitmap. Same fallback chain as makeQR() in the web app: full vCard M, full vCard L, mini card L.
    static func qrModules(for c: RoloContact, defaultCC: String) -> UIImage? {
        var mini = RoloContact(id: c.id, name: c.name)
        mini.company = c.company; mini.phone = c.phone; mini.email = c.email
        let tries: [(String, String)] = [(c.vCardLite(defaultCC: defaultCC), "M"),
                                         (c.vCardLite(defaultCC: defaultCC), "L"),
                                         (mini.vCardLite(defaultCC: defaultCC), "L")]
        let ctx = CIContext(options: nil)
        for (payload, level) in tries {
            let f = CIFilter.qrCodeGenerator()
            f.message = Data(payload.utf8)
            f.correctionLevel = level
            if let out = f.outputImage, let cg = ctx.createCGImage(out, from: out.extent) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    // MARK: Shared drawing

    private static func paper(_ g: CGContext, _ size: CGSize) {
        CardSpec.paper.setFill()
        g.fill(CGRect(origin: .zero, size: size))
        // CSS: linear-gradient(transparent 25px, #e6b72f 25px), size 26px, origin = content box (top padding 14)
        CardSpec.rule.setFill()
        var y: CGFloat = 14 + 25
        while y < size.height { g.fill(CGRect(x: 0, y: y, width: size.width, height: 1)); y += row }
    }

    private static func text(_ s: String, _ r: CGRect, _ font: UIFont, _ color: UIColor, align: NSTextAlignment = .left) {
        guard !s.isEmpty else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = max(0, row - font.lineHeight)               // keeps wrapped lines on the 26 pt ruling
        let box = CGRect(x: r.minX, y: r.minY + (row - font.lineHeight) / 2, width: r.width, height: r.height)
        (s as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p], context: nil)
    }

    /// The small QR chip, top right (CSS .cqr: 34 pt, 2 px #d9b247 border, 10 pt radius, 0 2px 0 shadow, 20 pt icon).
    private static func qrButton(_ g: CGContext, _ r: CGRect) {
        CardSpec.goldEdge.setFill()
        UIBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 2), cornerRadius: 10).fill()
        CardSpec.buttonFill.setFill()
        UIBezierPath(roundedRect: r, cornerRadius: 10).fill()
        let b = UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 9)
        b.lineWidth = 2
        CardSpec.goldEdge.setStroke()
        b.stroke()

        // Icon: three finder squares + data blocks, drawn on the same 24-unit grid as the web SVG.
        let s = 20.0 / 24.0, ox = r.minX + 7, oy = r.minY + 7
        CardSpec.ink.setFill()
        func ring(_ x: CGFloat, _ y: CGFloat) {
            let p = UIBezierPath(rect: CGRect(x: ox + x * s, y: oy + y * s, width: 8 * s, height: 8 * s))
            p.append(UIBezierPath(rect: CGRect(x: ox + (x + 2) * s, y: oy + (y + 2) * s, width: 4 * s, height: 4 * s)))
            p.usesEvenOddFillRule = true
            p.fill()
        }
        func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            UIBezierPath(rect: CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)).fill()
        }
        ring(3, 3); ring(13, 3); ring(3, 13)
        block(13, 15, 2, 2); block(17, 15, 4, 2); block(17, 17, 2, 2); block(13, 19, 2, 2); block(17, 19, 2, 2); block(19, 19, 2, 2)
    }

    // MARK: Small utility textures

    /// Soft contact shadow (alpha only). Card sits in the middle 160 x 82 of the 256 x 140 canvas.
    static func shadow() -> UIImage {
        render(CGSize(width: 256, height: 140), scale: 2, opaque: false) { g, _ in
            g.setShadow(offset: .zero, blur: 34, color: UIColor.black.withAlphaComponent(0.7).cgColor)
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(x: 48, y: 29, width: 160, height: 82), cornerRadius: 6).fill()
        }
    }
    static let shadowScale = SIMD2<Float>(256 / 160, 140 / 82)      // plane size = card size * this

    /// Gold outline shown under the selected card.
    static func ring() -> UIImage {
        render(CGSize(width: 256, height: 140), scale: 2, opaque: false) { _, _ in
            let p = UIBezierPath(roundedRect: CGRect(x: 44, y: 25, width: 168, height: 90), cornerRadius: 8)
            p.lineWidth = 5
            CardSpec.gold.setStroke()
            p.stroke()
        }
    }

    /// The "Later" tray drawn on the table.
    static func tray() -> UIImage {
        render(CGSize(width: 340, height: 210), scale: 2, opaque: false) { _, s in
            CardSpec.gold.withAlphaComponent(0.16).setFill()
            let r = CGRect(x: 6, y: 6, width: s.width - 12, height: s.height - 12)
            UIBezierPath(roundedRect: r, cornerRadius: 14).fill()
            let d = UIBezierPath(roundedRect: r, cornerRadius: 14)
            d.lineWidth = 4
            d.setLineDash([14, 9], count: 2, phase: 0)
            CardSpec.goldEdge.setStroke()
            d.stroke()
            text("Later", CGRect(x: 0, y: s.height - 56, width: s.width, height: row),
                 Fonts.elite(26), CardSpec.goldEdge, align: .center)
        }
    }

    /// Placement reticle.
    static func reticle() -> UIImage {
        render(CGSize(width: 128, height: 128), scale: 2, opaque: false) { _, s in
            let p = UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: s.width - 20, height: s.height - 20))
            p.lineWidth = 6
            UIColor.white.setStroke()
            p.stroke()
            UIColor.white.withAlphaComponent(0.25).setFill()
            p.fill()
        }
    }

    private static func render(_ size: CGSize, scale: CGFloat = CardSpec.renderScale, opaque: Bool,
                               _ draw: @escaping (CGContext, CGSize) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: f).image { draw($0.cgContext, size) }
    }
}

// MARK: - RealityKit materials

enum CardMaterials {
    static func texture(_ image: UIImage) -> TextureResource? {
        guard let cg = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cg, withName: nil, options: .init(semantic: .color))
    }

    /// Lit paper, so the card picks up the room's light and reflects the real environment a little.
    static func paperFace(_ image: UIImage) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let t = texture(image) { m.baseColor = .init(tint: .white, texture: .init(t)) }
        m.roughness = .init(floatLiteral: 0.92)
        m.metallic = .init(floatLiteral: 0)
        return m
    }

    static func paperEdge() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(hex: 0xE9D98D))
        m.roughness = .init(floatLiteral: 0.95)
        return m
    }

    /// Flat, always-bright material with alpha (shadow, tray, ring, reticle).
    static func overlay(_ image: UIImage) -> UnlitMaterial {
        var m = UnlitMaterial()
        if let t = texture(image) { m.color = .init(tint: .white, texture: .init(t)) }
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        return m
    }
}
