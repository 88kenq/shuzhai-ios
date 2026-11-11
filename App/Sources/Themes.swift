import UIKit
import CoreImage
import ShuZhaiCore

/// 閱讀主題。texture：0 純色、1 宣紙紋理、2 木紋、3 自己的照片。順序與 Android 版相同，備份可互通。
struct ReaderTheme: Equatable {
    let name: String
    let bg: UIColor
    let fg: UIColor
    var texture = 0
    var night = false
    var info: UIColor { fg.withAlphaComponent(0.5) }

    static let presets: [ReaderTheme] = [
        ReaderTheme(name: "紙白", bg: UIColor(rgb: 0xFAFAF7), fg: UIColor(rgb: 0x222222)),
        ReaderTheme(name: "羊皮紙", bg: UIColor(rgb: 0xF4ECD8), fg: UIColor(rgb: 0x2B2B2B)),
        ReaderTheme(name: "護眼綠", bg: UIColor(rgb: 0xCCE8CF), fg: UIColor(rgb: 0x1F2D20)),
        ReaderTheme(name: "淡粉", bg: UIColor(rgb: 0xF8E6E8), fg: UIColor(rgb: 0x3A2A2C)),
        ReaderTheme(name: "淡藍", bg: UIColor(rgb: 0xE3EDF7), fg: UIColor(rgb: 0x22303D)),
        ReaderTheme(name: "宣紙", bg: UIColor(rgb: 0xF1E6CF), fg: UIColor(rgb: 0x2E261C), texture: 1),
        ReaderTheme(name: "木紋", bg: UIColor(rgb: 0xCBA67A), fg: UIColor(rgb: 0x2A1D10), texture: 2),
        ReaderTheme(name: "深灰", bg: UIColor(rgb: 0x3A3A3A), fg: UIColor(rgb: 0xCFCFCF), night: true),
        ReaderTheme(name: "夜間暖色", bg: UIColor(rgb: 0x1C1813), fg: UIColor(rgb: 0x9C8E78), night: true),
        ReaderTheme(name: "純黑", bg: UIColor(rgb: 0x000000), fg: UIColor(rgb: 0x7A7A7A), night: true),
    ]
    static let custom = 100

    static func resolve(_ s: ReadStyle, _ index: Int) -> ReaderTheme {
        if index == custom {
            let bg = UIColor(argb: s.customBg)
            return ReaderTheme(name: "自訂", bg: bg, fg: UIColor(argb: s.customFg), texture: s.customImage ? 3 : 0, night: bg.isDark)
        }
        return index >= 0 && index < presets.count ? presets[index] : presets[1]
    }

    static func == (a: ReaderTheme, b: ReaderTheme) -> Bool { a.name == b.name && a.bg == b.bg && a.fg == b.fg && a.texture == b.texture }
}

extension UIColor {
    convenience init(argb: Int) {
        let v = UInt32(truncatingIfNeeded: argb)
        self.init(rgb: v & 0xFFFFFF, alpha: CGFloat((v >> 24) & 0xFF) / 255)
    }
    var argb: Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let v = (UInt32(a * 255) << 24) | (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
        return Int(Int32(bitPattern: v))
    }
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r * 299 + g * 587 + b * 114) / 1000 < 0.43
    }
}

/// 背景：紋理與照片
enum Backgrounds {
    private static var textures: [String: UIImage] = [:]
    private static var photo: (key: String, image: UIImage)?

    static func reset() { textures = [:]; photo = nil }

    static func texture(_ kind: Int, base: UIColor) -> UIImage {
        let key = "\(kind)-\(base.argb)"
        if let t = textures[key] { return t }
        let size = CGSize(width: 256, height: 256)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            base.setFill(); c.fill(CGRect(origin: .zero, size: size))
            var rng = SeededRandom(seed: 42)
            if kind == 1 {      // 宣紙：細小纖維與斑點
                for _ in 0..<1800 {
                    let dark = rng.next() < 0.5
                    let col = dark ? base.blend(.black, 0.06 + rng.next() * 0.05) : base.blend(.white, 0.25)
                    col.withAlphaComponent(0.35 + rng.next() * 0.3).set()
                    let x = rng.next() * 256, y = rng.next() * 256
                    if rng.next() < 0.2 {
                        let a = rng.next() * 6.283, l = 3 + rng.next() * 9
                        c.setLineWidth(0.6)
                        c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + l * cos(a), y: y + l * sin(a))); c.strokePath()
                    } else {
                        let r = 0.5 + rng.next() * 0.9
                        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    }
                }
            } else if kind == 2 {   // 木紋
                c.setLineWidth(2)
                for row in stride(from: 0, to: 256, by: 2) {
                    let shade = sin(Double(row) * 0.19) * 0.5 + sin(Double(row) * 0.047 + 1.3) * 0.5
                    base.blend(UIColor(rgb: 0x5A3719), CGFloat(0.08 + 0.10 * (shade + 1) / 2)).setStroke()
                    c.move(to: CGPoint(x: 0, y: CGFloat(row)))
                    var x: CGFloat = 0
                    while x <= 256 {
                        x += 16
                        c.addLine(to: CGPoint(x: x, y: CGFloat(row) + CGFloat(sin(Double(x) * 0.049 + Double(row) * 0.01) * 3)))
                    }
                    c.strokePath()
                }
            }
        }
        textures[key] = img
        return img
    }

    static func photoURL(_ root: URL) -> URL { root.appendingPathComponent("bg.jpg") }

    /// 照片背景（裁成螢幕比例、模糊、變暗）
    static func photo(root: URL, size: CGSize, blur: Int, dim: Int) -> UIImage? {
        let u = photoURL(root)
        let mod = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(Int(size.width))x\(Int(size.height))/\(blur)/\(dim)/\(mod)"
        if let p = photo, p.key == key { return p.image }
        guard size.width > 0, let src = UIImage(contentsOfFile: u.path), let cg = src.cgImage else { return nil }
        var ci = CIImage(cgImage: cg)
        let scale = max(size.width * 2 / ci.extent.width, size.height * 2 / ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: (ci.extent.width - size.width * 2) / 2, y: (ci.extent.height - size.height * 2) / 2, width: size.width * 2, height: size.height * 2)
        if blur > 0 { ci = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(blur) * 2) }
        ci = ci.cropped(to: crop)
        if dim > 0 {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(dim) / 100)).cropped(to: crop)
            ci = black.composited(over: ci)
        }
        guard let out = CIContext().createCGImage(ci, from: crop) else { return nil }
        let img = UIImage(cgImage: out, scale: 2, orientation: .up)
        photo = (key, img)
        return img
    }

    /// 存使用者選的照片（縮到螢幕大小左右）
    static func savePhoto(_ data: Data, root: URL) -> Bool {
        guard let img = UIImage(data: data) else { return false }
        let maxSide: CGFloat = 2400
        let k = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let r = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = r.jpegData(compressionQuality: 0.9) else { return false }
        photo = nil
        return (try? jpg.write(to: photoURL(root), options: .atomic)) != nil
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
}

extension UIColor {
    func blend(_ o: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1); o.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
