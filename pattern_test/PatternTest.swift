// PatternTest — Companion-01 (1440×2560) 相机测试图样播放器
// 编译: swiftc -O PatternTest.swift -o PatternTest
// 用法: ./PatternTest                  (控制窗 + 输出窗)
//       ./PatternTest --dump 3 out.png (离屏渲染单个图样, 不建窗)
import AppKit
import CoreGraphics
import Foundation

let PANEL_W = 1440, PANEL_H = 2560

struct Params {
    var lineNumber = 19.6349
    var obliquity  = 0.103813
    var deviation  = 3.8456375
    var views      = 40
    var cols       = 8
}

func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> (UInt8, UInt8, UInt8) {
    let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let i = Int(floor(hh)), f = hh - Double(i)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    let (r, g, b): (Double, Double, Double)
    switch i % 6 {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return (UInt8(max(0, min(255, r * 255))), UInt8(max(0, min(255, g * 255))), UInt8(max(0, min(255, b * 255))))
}

typealias PixelFn = (Int, Int, Int) -> (UInt8, UInt8, UInt8)   // (view, x, y)

// MARK: - 交织

func renderInterleaved(_ p: Params, _ f: PixelFn) -> CGImage {
    var buf = [UInt8](repeating: 0, count: PANEL_W * PANEL_H * 4)
    let nV = Double(p.views), nC = p.cols
    buf.withUnsafeMutableBufferPointer { out in
        for y in 0..<PANEL_H {
            let yf = Double(y)
            let rowBase = y * PANEL_W * 4
            for x in 0..<PANEL_W {
                var ar = 0, ag = 0, ab = 0
                for s in 0..<3 {
                    let x1 = (Double(x) + yf * p.obliquity) * 3.0 + Double(s)
                    var xl = (x1 + p.deviation).truncatingRemainder(dividingBy: p.lineNumber)
                    if xl < 0 { xl += p.lineNumber }
                    var choice = Int(floor(xl / p.lineNumber * nV))
                    if choice < 0 { choice = 0 }
                    if choice > p.views - 1 { choice = p.views - 1 }
                    let col = nC - (choice % nC) - 1
                    let row = choice / nC
                    var view = row * nC + col
                    if view < 0 { view = 0 }
                    if view > p.views - 1 { view = p.views - 1 }
                    let c = f(view, x, y)
                    ar += Int(c.0); ag += Int(c.1); ab += Int(c.2)
                }
                let i = rowBase + x * 4
                out[i] = UInt8(ar / 3); out[i + 1] = UInt8(ag / 3); out[i + 2] = UInt8(ab / 3); out[i + 3] = 255
            }
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    return CGImage(width: PANEL_W, height: PANEL_H, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: PANEL_W * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

// 相机对齐标记: 四角品红块 + 细白边 (叠在所有图样上)
func overlayMarks(_ x: Int, _ y: Int, _ base: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
    let m = 10, s = 96
    if x < m || y < m || x >= PANEL_W - m || y >= PANEL_H - m { return (255, 255, 255) }
    let corners = [(m, m), (PANEL_W - s - m, m), (m, PANEL_H - s - m), (PANEL_W - s - m, PANEL_H - s - m)]
    for (cx, cy) in corners where x >= cx && x < cx + s && y >= cy && y < cy + s { return (255, 0, 255) }
    return base
}

// MARK: - 图样

struct Pattern {
    let name: String
    let note: String
    let fn: PixelFn
}

func makePatterns(params: Params) -> [Pattern] {
    let N = params.views
    let cx = PANEL_W / 2, cy = PANEL_H / 2

    func gray(_ g: UInt8) -> PixelFn { { _, _, _ in (g, g, g) } }

    /// 视点 → 色相: 相机看单一颜色, 移动平滑过渡; 交错错 → 出现与位置无关的固定彩虹条纹
    let viewHue: PixelFn = { v, _, _ in hsv2rgb(Double(v) * 360.0 / Double(N), 0.95, 0.88) }

    /// 视点 → 灰阶 (线性), 便于读数
    let viewGray: PixelFn = { v, _, _ in
        let g = UInt8(16 + 224 * v / max(1, N - 1)); return (g, g, g)
    }

    /// 视点 → 6 位二进制条 (相机拍到哪一档, 直接读出视点号)
    let viewBits: PixelFn = { v, x, y in
        let bg: (UInt8, UInt8, UInt8) = (40, 40, 40)
        guard x > 120, x < PANEL_W - 120, y > 700, y < 1900 else { return bg }
        let barH = 170, gap = 40, top = 760
        for k in 0..<6 {
            let y0 = top + k * (barH + gap)
            if y >= y0 && y < y0 + barH {
                let on = (v >> (5 - k)) & 1 == 1
                return on ? (250, 250, 250) : (70, 70, 70)
            }
        }
        return bg
    }

    /// 全视点同一画面: 应完全平, 任何重影/错相都会露出来
    let zeroPar: PixelFn = { _, x, y in
        let bg: (UInt8, UInt8, UInt8) = (90, 90, 90)
        if y > cy - 900 && y < cy - 760 { return (250, 250, 250) }        // 上横条
        if y > cy + 760 && y < cy + 900 { return (250, 250, 250) }        // 下横条
        if abs(x - cx) < 34 { return (250, 250, 250) }                     // 竖轴
        let dx = Double(x - cx), dy = Double(y - cy), r = (dx * dx + dy * dy).squareRoot()
        if abs(r - 520) < 26 { return (30, 200, 250) }                     // 圆环
        return bg
    }

    /// 奇偶视点左右错位: 判左右眼与串扰
    let pairLR: PixelFn = { v, x, y in
        let bg: (UInt8, UInt8, UInt8) = (70, 70, 70)
        let off = (v % 2 == 0) ? -110 : 110
        if y > cy - 700 && y < cy + 700 && abs(x - (cx + off)) < 90 { return (250, 250, 250) }
        return bg
    }

    /// 三档视差: 视点段 → 三种水平位置 (0-12 / 13-26 / 27-39)
    let steps3: PixelFn = { v, x, y in
        let bg: (UInt8, UInt8, UInt8) = (60, 60, 60)
        let band = v > 26 ? 2 : (v > 12 ? 1 : 0)
        let off = [-160, 0, 160][band]
        if y > cy - 620 && y < cy + 620 && abs(x - (cx + off)) < 100 {
            return band == 0 ? (240, 90, 90) : (band == 1 ? (90, 240, 120) : (110, 150, 250))
        }
        return bg
    }

    /// 真 3D 模拟: 三条竖条各在不同深度, 视差量不同、方向不同 (前=红, 屏=绿, 后=蓝)
    let depth3: PixelFn = { v, x, y in
        let bg: (UInt8, UInt8, UInt8) = (55, 55, 55)
        let k = Double(v) - Double(N - 1) / 2.0        // -19.5 … +19.5
        let bands: [(Double, Int, Int, (UInt8, UInt8, UInt8))] = [
            (+6.0, cy - 780, cy - 180, (240, 80, 80)),   // 前景: 视差最大, 往 +x
            ( 0.0, cy - 100, cy + 500, (110, 230, 130)), // 屏面: 无视差
            (-3.0, cy + 580, cy + 1180, (110, 150, 250)) // 后景: 反向
        ]
        for (pxPerView, y0, y1, col) in bands where y >= y0 && y < y1 {
            let off = Int((pxPerView * k).rounded())
            if abs(x - (cx + off)) < 110 { return col }
        }
        return bg
    }

    /// 几何 1:1: 边框 + 中心十字 + 每 100px 刻度 (相机侧标定/查缩放)
    let geom: PixelFn = { _, x, y in
        let bg: (UInt8, UInt8, UInt8) = (80, 80, 80)
        if x < 6 || y < 6 || x >= PANEL_W - 6 || y >= PANEL_H - 6 { return (250, 250, 250) }
        if abs(x - cx) < 3 || abs(y - cy) < 3 { return (250, 250, 250) }
        if y < 120 && x % 100 < 3 { return (250, 220, 60) }
        if x < 120 && y % 100 < 3 { return (250, 220, 60) }
        let dx = abs(x - cx), dy = abs(y - cy)
        if dx < 260 && dy < 260 {
            if dx < 60 && dy < 60 { return (250, 250, 250) }
            if abs(dx - dy) < 8 { return (250, 220, 60) }
        }
        return bg
    }

    return [
        Pattern(name: "0 灰场", note: "反光/亮度基准", fn: gray(128)),
        Pattern(name: "1 黑场", note: "看反光位置", fn: gray(0)),
        Pattern(name: "2 白场", note: "亮度均匀性", fn: gray(255)),
        Pattern(name: "3 视点色相", note: "应单色; 移动变色 = 交错正确", fn: viewHue),
        Pattern(name: "4 视点灰阶", note: "同上, 读数更稳", fn: viewGray),
        Pattern(name: "5 视点二进制条", note: "6 条读出当前视点号", fn: viewBits),
        Pattern(name: "6 零视差", note: "应完全平; 重影=错相/串扰", fn: zeroPar),
        Pattern(name: "7 左右眼错位", note: "奇偶视点左右跳", fn: pairLR),
        Pattern(name: "8 三档视差", note: "三段位置跳变", fn: steps3),
        Pattern(name: "9 深度三色条", note: "红前绿屏蓝后, 判方向", fn: depth3),
        Pattern(name: "10 几何 1:1", note: "边框/刻度, 查缩放", fn: geom)
    ]
}

// MARK: - 应用

final class OutputView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: bounds)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var params = Params()
    var patterns: [Pattern] = []
    var outWin: NSWindow!
    var ctrlWin: NSWindow!
    var outView: OutputView!
    var infoLabel: NSTextField!
    var sliders: [String: NSSlider] = [:]
    var current = 0
    var autoRun = false
    var autoTimer: Timer?
    var blinkTimer: Timer?
    var autocloseAfter: Double?

    func panelScreen() -> NSScreen? {
        NSScreen.screens.first { Int($0.frame.width) == PANEL_W && Int($0.frame.height) == PANEL_H }
            ?? NSScreen.screens.first { $0 != NSScreen.main }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        patterns = makePatterns(params: params)

        guard let scr = panelScreen() else {
            let a = NSAlert(); a.messageText = "找不到 1440×2560 面板"; a.runModal(); NSApp.terminate(nil); return
        }

        outWin = NSWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        outWin.setFrame(scr.frame, display: true)
        outWin.backgroundColor = .black
        outWin.isOpaque = true
        outWin.level = .normal
        outWin.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        outView = OutputView(frame: NSRect(origin: .zero, size: scr.frame.size))
        outWin.contentView = outView
        outWin.orderFrontRegardless()

        buildControl()
        show(current)
        NSApp.activate(ignoringOtherApps: true)
        ctrlWin.makeKeyAndOrderFront(nil)

        // 自检日志: 输出窗落在哪块屏、实际 frame 是多少
        let scrFrame = String(format: "%.0f,%.0f %.0fx%.0f", scr.frame.origin.x, scr.frame.origin.y, scr.frame.width, scr.frame.height)
        let winFrame = String(format: "%.0f,%.0f %.0fx%.0f", outWin.frame.origin.x, outWin.frame.origin.y, outWin.frame.width, outWin.frame.height)
        FileHandle.standardError.write("[PatternTest] screen=\(scrFrame) window=\(winFrame) scale=\(scr.backingScaleFactor)\n".data(using: .utf8)!)

        if let secs = autocloseAfter { Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in NSApp.terminate(nil) } }
    }

    func buildControl() {
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 720),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Companion-01 测试图样"
        ctrlWin = w
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 720))
        w.contentView = root

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.frame = NSRect(x: 16, y: 664, width: 368, height: 40)
        infoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        infoLabel.maximumNumberOfLines = 3
        infoLabel.lineBreakMode = .byWordWrapping
        root.addSubview(infoLabel)

        // 图样按钮
        for (i, p) in patterns.enumerated() {
            let b = NSButton(title: p.name, target: self, action: #selector(pickButton(_:)))
            b.tag = i
            b.frame = NSRect(x: 16, y: 600 - i * 34, width: 220, height: 28)
            b.bezelStyle = .rounded
            b.alignment = .left
            root.addSubview(b)
            let l = NSTextField(labelWithString: p.note)
            l.font = .systemFont(ofSize: 10); l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 244, y: 606 - i * 34, width: 146, height: 18)
            root.addSubview(l)
        }

        // 参数滑杆
        let specs: [(String, Double, Double, Double)] = [
            ("lineNumber", 19.40, 19.90, params.lineNumber),
            ("obliquity", 0.05, 0.17, params.obliquity),
            ("deviation", 0.0, 20.0, params.deviation)
        ]
        for (i, s) in specs.enumerated() {
            let y = 214 - i * 56
            let l = NSTextField(labelWithString: String(format: "%@  %.4f", s.0, s.3))
            l.frame = NSRect(x: 16, y: y + 26, width: 260, height: 18)
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.identifier = NSUserInterfaceItemIdentifier("lbl_" + s.0)
            root.addSubview(l)
            let sl = NSSlider(value: s.3, minValue: s.1, maxValue: s.2, target: self, action: #selector(sliderMoved(_:)))
            sl.frame = NSRect(x: 16, y: y, width: 368, height: 22)
            sl.identifier = NSUserInterfaceItemIdentifier(s.0)
            root.addSubview(sl)
            sliders[s.0] = sl
        }

        let ab = NSButton(checkboxWithTitle: "自动轮播 (5s)", target: self, action: #selector(toggleAuto(_:)))
        ab.frame = NSRect(x: 16, y: 24, width: 200, height: 24)
        root.addSubview(ab)
        let qb = NSButton(title: "退出", target: self, action: #selector(quit))
        qb.frame = NSRect(x: 300, y: 20, width: 84, height: 28)
        root.addSubview(qb)

        ctrlWin.makeFirstResponder(nil)
    }

    @objc func pickButton(_ s: NSButton) { show(s.tag) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleAuto(_ s: NSButton) {
        autoRun = s.state == .on
        autoTimer?.invalidate(); autoTimer = nil
        if autoRun {
            autoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.show((self.current + 1) % self.patterns.count)
            }
        }
    }

    @objc func sliderMoved(_ s: NSSlider) {
        guard let id = s.identifier?.rawValue else { return }
        switch id {
        case "lineNumber": params.lineNumber = s.doubleValue
        case "obliquity": params.obliquity = s.doubleValue
        case "deviation": params.deviation = s.doubleValue
        default: break
        }
        if let l = ctrlWin.contentView?.subviews.first(where: { $0.identifier?.rawValue == "lbl_" + id }) as? NSTextField {
            l.stringValue = String(format: "%@  %.4f", id, s.doubleValue)
        }
        show(current)
    }

    func show(_ i: Int) {
        guard i >= 0, i < patterns.count else { return }
        current = i
        let p = patterns[i]
        let img = renderInterleaved(params) { v, x, y in overlayMarks(x, y, p.fn(v, x, y)) }
        outView.image = img
        infoLabel.stringValue = String(format: "%@  |  %.4f / %.4f / %.4f  (%d 视点)", p.name, params.lineNumber, params.obliquity, params.deviation, params.views)
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if args.count >= 4, args[1] == "--dump" {
    let idx = Int(args[2]) ?? 0
    let path = args[3]
    let ps = makePatterns(params: Params())
    let i = max(0, min(idx, ps.count - 1))
    let img = renderInterleaved(Params()) { v, x, y in overlayMarks(x, y, ps[i].fn(v, x, y)) }
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(PANEL_W)x\(PANEL_H)  pattern=\(ps[i].name)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--autoclose"), i + 1 < args.count, let s = Double(args[i + 1]) { delegate.autocloseAfter = s }
app.delegate = delegate
app.run()
