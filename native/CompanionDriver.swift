// Companion-01 原生驱动 (macOS, Metal) — 最小可用版
// 两个窗口：输出窗（无边框，可投副屏，纯画面）/ 控制窗（Mac 上操作）
// 支持：模式A 40宫格图集交织；模式B RGB+深度视差；校准图；合成测试图；1:1 指示
// 构建：swiftc -O CompanionDriver.swift -o CompanionDriver
// 运行：./CompanionDriver

import AppKit
import MetalKit
import simd

// MARK: - 参数
struct U {
    var interval: Float = 19.6349
    var slope: Float = 0.103813
    var x0: Float = 3.8456375
    var offsetY: Float = 0
    var cols: Float = 8
    var rows: Float = 5
    var outW: Float = 1440
    var outH: Float = 2560
    var mode: Float = 0          // 0=quilt 1=parallax
    var depthFactor: Float = 1
    var inverseDepth: Float = 0
    var inverseDisplay: Float = 0
    var gammaDepth: Float = 1
    var order: Float = 0         // 0=factory 1=natural
}

// MARK: - Shader
let shaderSrc = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float interval, slope, x0, offsetY, cols, rows, outW, outH;
    float mode, depthFactor, inverseDepth, inverseDisplay, gammaDepth, order;
};
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs_main(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 1 || vid == 3) ? 1.0 : -1.0,
                      (vid >= 2) ? 1.0 : -1.0);
    VOut o;
    o.pos = float4(p, 0.0, 1.0);
    o.uv  = float2((p.x + 1.0) * 0.5, (p.y + 1.0) * 0.5);
    return o;
}

static inline float2 tc(float2 uv) { return float2(uv.x, 1.0 - uv.y); }
static inline float modp(float a, float b) { float r = fmod(a, b); return r < 0.0 ? r + b : r; }

fragment float4 fs_quilt(VOut in [[stage_in]],
                         constant U& u [[buffer(0)]],
                         texture2d<float> tex [[texture(0)]],
                         sampler s [[sampler(0)]]) {
    float3 c = float3(1.0);
    float n = u.cols * u.rows;
    float x = floor(in.uv.x * u.outW) + 1.0;
    float y = floor((1.0 - in.uv.y) * u.outH) + 1.0;
    for (int b = 0; b < 3; b++) {
        float bias = float(b);
        float x1 = (x + y * u.slope) * 3.0 + bias;
        float xl = modp(x1 + u.x0, u.interval);
        float choice = floor((xl / u.interval) * n);
        choice = min(choice, n - 1.0);
        float col = (u.order < 0.5) ? (u.cols - modp(choice, u.cols) - 1.0) : modp(choice, u.cols);
        float row = (u.order < 0.5) ? floor(choice / u.cols) : (u.rows - 1.0 - floor(choice / u.cols));
        float2 suv = (float2(col, row) + float2(in.uv.x, in.uv.y + u.offsetY)) / float2(u.cols, u.rows);
        float4 t = tex.sample(s, tc(suv));
        if (b == 0) c.r = t.r; else if (b == 1) c.g = t.g; else c.b = t.b;
    }
    return float4(c, 1.0);
}

static inline float sampleDepth(texture2d<float> d, sampler s, float2 uv, constant U& u) {
    float v = d.sample(s, tc(uv)).r;
    if (u.gammaDepth > 0.5) v = clamp(v * 1.2 - 0.1, 0.0, 1.0);
    if (u.inverseDepth > 0.5) v = 1.0 - v;
    return v;
}

static inline float viewCoord(float2 su, float bias, constant U& u) {
    float unit = 1.0 / (u.outW * 3.0);
    float pitch = (u.outW * 3.0) / u.interval;
    float sl = u.slope * (u.outH / u.outW);
    float center = (u.x0 + 3.0) / u.interval;
    float v = su.x + su.y * sl + bias * unit;
    v = modp(v * pitch + center, 1.0);
    return 1.0 - v;
}

static inline float findOffset(float2 uv, float viewOffset, float maxPar,
                               texture2d<float> depth, sampler s, constant U& u) {
    float stepSize = 1.0 / 16.0;
    float ray = 1.0;
    float x = uv.x - viewOffset * 0.5 * maxPar;
    float dx = viewOffset * maxPar / 16.0;
    float px = x, pr = ray;
    float pd = sampleDepth(depth, s, float2(x, uv.y), u);
    float sd = pd;
    for (int i = 0; i < 16; i++) {
        if (sd >= ray) break;
        px = x; pr = ray; pd = sd;
        ray -= stepSize; x += dx;
        sd = sampleDepth(depth, s, float2(x, uv.y), u);
    }
    float d1 = pr - pd, d2 = sd - ray;
    float w = (d1 + d2) > 1e-5 ? d1 / (d1 + d2) : 0.0;
    return clamp(mix(px, x, w), 0.0, 1.0);
}

fragment float4 fs_parallax(VOut in [[stage_in]],
                            constant U& u [[buffer(0)]],
                            texture2d<float> color [[texture(0)]],
                            texture2d<float> depth [[texture(1)]],
                            sampler s [[sampler(0)]]) {
    float2 uv = in.uv;
    if (u.inverseDisplay > 0.5) uv = float2(1.0 - uv.x, 1.0 - uv.y);
    float2 su = float2(uv.x, 1.0 - uv.y);
    float mp = 0.2 * u.depthFactor;
    float oR = -(viewCoord(su, 0.0, u) - 0.5);
    float oG = -(viewCoord(su, 1.0, u) - 0.5);
    float oB = -(viewCoord(su, 2.0, u) - 0.5);
    float xR = findOffset(uv, oR, mp, depth, s, u);
    float xG = findOffset(uv, oG, mp, depth, s, u);
    float xB = findOffset(uv, oB, mp, depth, s, u);
    float3 c;
    c.r = color.sample(s, tc(float2(xR, uv.y))).r;
    c.g = color.sample(s, tc(float2(xG, uv.y))).g;
    c.b = color.sample(s, tc(float2(xB, uv.y))).b;
    return float4(c, 1.0);
}
"""

// MARK: - Renderer
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pQuilt: MTLRenderPipelineState!
    var pParallax: MTLRenderPipelineState!
    var sampler: MTLSamplerState!
    var quilt: MTLTexture?
    var depth: MTLTexture?
    var u = U()

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        super.init()
        do {
            let lib = try device.makeLibrary(source: shaderSrc, options: nil)
            func makePipe(_ frag: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "vs_main")
                d.fragmentFunction = lib.makeFunction(name: frag)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: d)
            }
            pQuilt = try makePipe("fs_quilt")
            pParallax = try makePipe("fs_parallax")
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: sd)
        } catch {
            NSLog("pipeline error: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        u.outW = Float(view.drawableSize.width)
        u.outH = Float(view.drawableSize.height)
        if let tex = quilt, u.mode < 0.5 {
            enc.setRenderPipelineState(pQuilt)
            enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else if let tex = quilt, let d = depth, u.mode >= 0.5 {
            enc.setRenderPipelineState(pParallax)
            enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentTexture(d, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        if let dd = view.currentDrawable { cb.present(dd) }
        cb.commit()
    }

    // MARK: 纹理
    func texture(from cg: CGImage) -> MTLTexture? {
        let w = cg.width, h = cg.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }

    func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var outWindow: NSWindow!
    var ctrlWindow: NSWindow!
    var mtkView: MTKView!
    var renderer: Renderer!
    var infoLabel: NSTextField!
    var statusLabel: NSTextField!
    var calibLabel: NSTextField!
    var sliders: [String: NSSlider] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice(), let r = Renderer(device: dev) else {
            let a = NSAlert(); a.messageText = "Metal 不可用"; a.runModal(); NSApp.terminate(nil); return
        }
        renderer = r

        mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 1440, height: 2560), device: dev)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.delegate = renderer

        outWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 2560),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        outWindow.contentView = mtkView
        outWindow.backgroundColor = .black
        outWindow.isOpaque = true
        outWindow.title = "Companion-01 输出"
        outWindow.makeKeyAndOrderFront(nil)

        ctrlWindow = NSWindow(contentRect: NSRect(x: 40, y: 120, width: 460, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ctrlWindow.title = "Companion-01 控制"
        ctrlWindow.contentView = buildControls()
        ctrlWindow.makeKeyAndOrderFront(nil)

        placeOutputOnSecondary()
        updateInfo()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 放置输出窗
    func placeOutputOnSecondary() {
        let screens = NSScreen.screens
        let target = screens.first(where: { $0 != NSScreen.main }) ?? screens.first!
        outWindow.setFrame(target.frame, display: true)
        mtkView.frame = NSRect(origin: .zero, size: target.frame.size)
        mtkView.drawableSize = CGSize(width: target.frame.width, height: target.frame.height)
        updateInfo()
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func updateInfo() {
        guard infoLabel != nil else { return }
        let ds = mtkView.drawableSize
        let ok = Int(ds.width) == 1440 && Int(ds.height) == 2560
        infoLabel.stringValue = String(format: "输出 %.0f×%.0f（1:1 %@）· 屏幕 %@",
                                       ds.width, ds.height, ok ? "✓" : "✗ 需设为原生 1440×2560",
                                       (outWindow.screen?.localizedName ?? "?"))
        infoLabel.textColor = ok ? .systemGreen : .systemRed
    }

    // MARK: 控制面板
    func buildControls() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        infoLabel = NSTextField(labelWithString: "输出 —")
        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        root.addArrangedSubview(infoLabel)

        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        // 模式
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: ["A · 40宫格图集", "B · RGB+深度视差"])
        mode.target = self; mode.action = #selector(modeChanged(_:))
        root.addArrangedSubview(row("模式", mode))

        // 滑杆
        root.addArrangedSubview(slider("interval", 17, 22, Double(renderer.u.interval), 0.0001, #selector(intervalChanged(_:))))
        root.addArrangedSubview(slider("obliquity", -0.3, 0.3, Double(renderer.u.slope), 0.000001, #selector(slopeChanged(_:))))
        root.addArrangedSubview(slider("deviation", -20, 20, Double(renderer.u.x0), 0.01, #selector(x0Changed(_:))))
        root.addArrangedSubview(slider("offsetY", -0.5, 0.5, 0, 0.001, #selector(offsetChanged(_:))))
        root.addArrangedSubview(slider("depthFactor", 0, 4, 1, 0.01, #selector(depthChanged(_:))))

        // 校准读数（三线画面下实时更新）
        calibLabel = NSTextField(labelWithString: "校准读数：—（进「三线校准画面」后显示）")
        calibLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        calibLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(calibLabel)

        // 按钮
        root.addArrangedSubview(buttons([
            ("载入图集…", #selector(loadQuilt)),
            ("载入 RGBD…", #selector(loadRgbd)),
            ("校准图", #selector(showCalib)),
            ("合成测试图", #selector(showSynth)),
        ]))
        root.addArrangedSubview(buttons([
            ("三线校准画面", #selector(showCalibScene)),
            ("周期 −0.01", #selector(intervalDown10)),
            ("周期 +0.01", #selector(intervalUp10)),
        ]))
        root.addArrangedSubview(buttons([
            ("周期 −0.001", #selector(intervalDown)),
            ("周期 +0.001", #selector(intervalUp)),
            ("x0 −0.10", #selector(x0Down10)),
            ("x0 +0.10", #selector(x0Up10)),
        ]))
        root.addArrangedSubview(buttons([
            ("x0 −0.01", #selector(x0Down01)),
            ("x0 +0.01", #selector(x0Up01)),
        ]))
        root.addArrangedSubview(buttons([
            ("深度标尺", #selector(showDepthRuler)),
            ("深度斜坡", #selector(showDepthRamp)),
            ("物理视差(±6.5px)", #selector(showPhysicalRuler)),
        ]))
        root.addArrangedSubview(buttons([
            ("投到副屏", #selector(toSecondary)),
            ("1:1 居中", #selector(toNativeSize)),
            ("自动求对称周期", #selector(solveInterval)),
        ]))

        let note = NSTextField(wrappingLabelWithString:
            "提示：输出窗是独立无边框窗口，可拖到 Companion-01 上；控制窗留在 Mac。\n" +
            "1:1 必须显示 ✓，否则相位整体错位。校准图用于看 6.5px 光栅条纹与视点编号。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(note)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 720))
        scroll.hasVerticalScroller = true
        scroll.documentView = root
        root.translatesAutoresizingMaskIntoConstraints = false
        if let clip = scroll.contentView as NSClipView? {
            root.widthAnchor.constraint(equalTo: clip.widthAnchor).isActive = true
        }
        return scroll
    }

    func row(_ title: String, _ v: NSView) -> NSView {
        let s = NSStackView(views: [NSTextField(labelWithString: title), v])
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    func slider(_ title: String, _ lo: Double, _ hi: Double, _ val: Double, _ step: Double, _ act: Selector) -> NSView {
        let sl = NSSlider(value: val, minValue: lo, maxValue: hi, target: self, action: act)
        sl.isContinuous = true
        sliders[title] = sl
        sl.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let lab = NSTextField(labelWithString: title)
        lab.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        lab.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let s = NSStackView(views: [lab, sl])
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    func buttons(_ items: [(String, Selector)]) -> NSView {
        let s = NSStackView()
        s.orientation = .horizontal
        s.spacing = 8
        for (t, a) in items {
            let b = NSButton(title: t, target: self, action: a)
            b.bezelStyle = .rounded
            s.addArrangedSubview(b)
        }
        return s
    }

    @objc func modeChanged(_ s: NSPopUpButton) {
        renderer.u.mode = s.indexOfSelectedItem == 1 ? 1 : 0
        redraw()
    }
    @objc func intervalChanged(_ s: NSSlider) { renderer.u.interval = Float(s.doubleValue); redraw() }
    @objc func intervalDown() { renderer.u.interval -= 0.001; syncSliders(); redraw() }
    @objc func intervalUp()   { renderer.u.interval += 0.001; syncSliders(); redraw() }
    @objc func intervalDown10() { renderer.u.interval -= 0.01; syncSliders(); redraw() }
    @objc func intervalUp10()   { renderer.u.interval += 0.01; syncSliders(); redraw() }
    @objc func x0Down10() { renderer.u.x0 -= 0.10; syncSliders(); redraw() }
    @objc func x0Up10()   { renderer.u.x0 += 0.10; syncSliders(); redraw() }
    @objc func x0Down01() { renderer.u.x0 -= 0.01; syncSliders(); redraw() }
    @objc func x0Up01()   { renderer.u.x0 += 0.01; syncSliders(); redraw() }
    @objc func slopeChanged(_ s: NSSlider) { renderer.u.slope = Float(s.doubleValue); redraw() }
    @objc func x0Changed(_ s: NSSlider) { renderer.u.x0 = Float(s.doubleValue); redraw() }
    @objc func offsetChanged(_ s: NSSlider) { renderer.u.offsetY = Float(s.doubleValue); redraw() }
    @objc func depthChanged(_ s: NSSlider) { renderer.u.depthFactor = Float(s.doubleValue); redraw() }

    func redraw() {
        mtkView.setNeedsDisplay(mtkView.bounds)
        updateInfo()
        updateCalibReadout()
    }

    func syncSliders() {
        sliders["interval"]?.doubleValue = Double(renderer.u.interval)
        sliders["obliquity"]?.doubleValue = Double(renderer.u.slope)
        sliders["deviation"]?.doubleValue = Double(renderer.u.x0)
        sliders["depthFactor"]?.doubleValue = Double(renderer.u.depthFactor)
    }

    /// 三线校准读数：左右绿条相对中白条的横向偏移（源像素）与有符号和
    func updateCalibReadout() {
        guard calibLabel != nil else { return }
        let W = 1440.0, H = 2560.0
        let interval = Double(renderer.u.interval)
        let slope = Double(renderer.u.slope)
        let x0 = Double(renderer.u.x0)
        let df = Double(renderer.u.depthFactor)
        let pitch = (W * 3) / interval
        let s = slope * (H / W)
        let center = (x0 + 3) / interval
        let mp = 0.2 * df
        func vc(_ sux: Double) -> Double {
            var v = (sux + 0.5 * s) * pitch + center
            v -= floor(v)
            return 1 - v
        }
        func off(_ sux: Double, _ depth: Double) -> Double {
            (-(vc(sux) - 0.5)) * mp * (0.5 - depth) * 540
        }
        let L = off(0.22, 0), R = off(0.78, 1)
        let sum = L + R
        calibLabel.stringValue = String(format: "校准读数：左 %+.1f / 右 %+.1f / 和 %+.1f px   jiange %.4f",
                                        L, R, sum, interval / 3)
        calibLabel.textColor = abs(sum) < 1.5 ? .systemGreen : .systemOrange
    }

    /// 深度标尺：13 条竖条，深度 0..1 均分，用于找“开始重影”的那一档
    @objc func showDepthRuler() {
        let W = 720, H = 1280
        let n = 13
        let bw = CGFloat(W) / CGFloat(n)
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        let cols: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow]
        for i in 0..<n {
            let x = CGFloat(i) * bw
            cols[i % cols.count].setFill()
            NSRect(x: x + 5, y: 240, width: bw - 10, height: CGFloat(H) - 480).fill()
            let k = i - n / 2
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.white]
            NSString(string: "\(k)").draw(at: NSPoint(x: x + 10, y: 150), withAttributes: attrs)
        }
        img.unlockFocus()

        let dimg = NSImage(size: NSSize(width: W, height: H))
        dimg.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        for i in 0..<n {
            let x = CGFloat(i) * bw
            let d = 0.5 + (Double(i - n / 2) / Double(n - 1)) * 0.9
            NSColor(white: CGFloat(min(1, max(0, d))), alpha: 1).setFill()
            NSRect(x: x + 5, y: 240, width: bw - 10, height: CGFloat(H) - 480).fill()
        }
        dimg.unlockFocus()

        if let c1 = renderer.cgImage(from: img), let c2 = renderer.cgImage(from: dimg) {
            renderer.quilt = renderer.texture(from: c1)
            renderer.depth = renderer.texture(from: c2)
            renderer.u.mode = 1
            renderer.u.gammaDepth = 0
            syncSliders(); redraw()
            statusLabel.stringValue = "深度标尺：中间 0 = 屏面，负=凹进，正=凸出；找出开始重影/闪烁的那一条"
        }
    }

    /// 深度斜坡：0→1 连续渐变，重影起点会形成一条明显的边界
    @objc func showDepthRamp() {
        let W = 720, H = 1280
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor(white: 0.55, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        for x in 0..<16 {
            NSRect(x: CGFloat(x) * CGFloat(W) / 16, y: 0, width: CGFloat(W) / 32, height: CGFloat(H)).fill()
        }
        img.unlockFocus()
        let dimg = NSImage(size: NSSize(width: W, height: H))
        dimg.lockFocus()
        NSGradient(starting: .black, ending: .white)?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 0)
        dimg.unlockFocus()
        if let c1 = renderer.cgImage(from: img), let c2 = renderer.cgImage(from: dimg) {
            renderer.quilt = renderer.texture(from: c1)
            renderer.depth = renderer.texture(from: c2)
            renderer.u.mode = 1
            renderer.u.gammaDepth = 0
            syncSliders(); redraw()
            statusLabel.stringValue = "深度斜坡：左黑=0(远) 右白=1(近)；记下开始花掉的位置 x/W"
        }
    }

    /// 物理视差尺：把 depthFactor 设为“整周期 = 6.545px”，第 i 条 ≈ i 个视点
    @objc func showPhysicalRuler() {
        // maxPar 使整幅深度(0..1)产生 ±6.545px：shift=0.25*maxPar*W
        let maxPar = 6.54497 / (0.25 * 1440.0)          // = 0.01818 UV
        renderer.u.depthFactor = Float(maxPar / 0.2)     // 0.0909
        renderer.u.gammaDepth = 0
        showDepthRuler()
        statusLabel.stringValue = String(format: "物理视差尺：整周期=6.545px，depthFactor=%.4f（每条≈1/6视点）", renderer.u.depthFactor)
    }

    /// 三线校准画面（复刻 D20：左绿=最远 / 中白=零视差 / 右绿=最近）
    @objc func showCalibScene() {
        let W = 540, H = 960
        let bw = CGFloat(W) * 0.17, bh: CGFloat = 26
        let cy = CGFloat(H) * 0.5
        let gap = CGFloat(W) * 0.22
        let barRects = [
            NSRect(x: gap - bw / 2, y: cy - bh / 2, width: bw, height: bh),
            NSRect(x: CGFloat(W) / 2 - bw / 2, y: cy - bh / 2, width: bw, height: bh),
            NSRect(x: CGFloat(W) - gap - bw / 2, y: cy - bh / 2, width: bw, height: bh)
        ]

        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        let green = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
        green.setFill(); barRects[0].fill()
        NSColor.white.setFill(); barRects[1].fill()
        green.setFill(); barRects[2].fill()
        img.unlockFocus()

        let dimg = NSImage(size: NSSize(width: W, height: H))
        dimg.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        NSColor.black.setFill(); barRects[0].fill()                      // 最远
        NSColor(white: 0.5, alpha: 1).setFill(); barRects[1].fill()      // 零视差
        NSColor.white.setFill(); barRects[2].fill()                      // 最近
        dimg.unlockFocus()

        if let c1 = renderer.cgImage(from: img), let c2 = renderer.cgImage(from: dimg) {
            renderer.quilt = renderer.texture(from: c1)
            renderer.depth = renderer.texture(from: c2)
            renderer.u.mode = 1
            renderer.u.depthFactor = 2.0
            renderer.u.gammaDepth = 0
            syncSliders()
            statusLabel.stringValue = "三线校准：单眼正对屏幕中心，调周期直到左右绿条与中白条共线（和→0）"
            redraw()
        }
    }

    // MARK: 内容
    @objc func loadQuilt() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .bmp]
        if p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url), let cg = renderer.cgImage(from: img) {
            renderer.quilt = renderer.texture(from: cg)
            renderer.u.mode = 0
            statusLabel.stringValue = "图集 \(cg.width)×\(cg.height)"
            redraw()
        }
    }

    @objc func loadRgbd() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .bmp]
        if p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url), let cg = renderer.cgImage(from: img) {
            let w = cg.width / 2, h = cg.height
            guard let left = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)),
                  let right = cg.cropping(to: CGRect(x: w, y: 0, width: w, height: h)) else { return }
            renderer.quilt = renderer.texture(from: left)
            renderer.depth = renderer.texture(from: right)
            renderer.u.mode = 1
            statusLabel.stringValue = "RGBD \(cg.width)×\(cg.height) → 单视点 \(w)×\(h)"
            redraw()
        }
    }

    @objc func showCalib() {
        let cols = Int(renderer.u.cols), rows = Int(renderer.u.rows)
        let vw = 540, vh = 960
        let img = NSImage(size: NSSize(width: vw * cols, height: vh * rows))
        img.lockFocus()
        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                let g = CGFloat(idx) / CGFloat(max(1, cols * rows - 1))
                NSColor(white: g, alpha: 1).setFill()
                NSRect(x: c * vw, y: r * vh, width: vw, height: vh).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 120),
                    .foregroundColor: NSColor.red
                ]
                NSString(string: "\(idx)").draw(at: NSPoint(x: c * vw + 40, y: r * vh + 120), withAttributes: attrs)
            }
        }
        img.unlockFocus()
        if let cg = renderer.cgImage(from: img) {
            renderer.quilt = renderer.texture(from: cg)
            renderer.u.mode = 0
            statusLabel.stringValue = "校准图 \(vw * cols)×\(vh * rows)（40 视点）"
            redraw()
        }
    }

    @objc func showSynth() {
        let w = 720, h = 1280
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor(white: 0.06, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let cell = 60
        for y in stride(from: 0, to: h, by: cell) {
            for x in stride(from: 0, to: w, by: cell) {
                if ((x / cell) + (y / cell)) % 2 == 0 {
                    NSColor(white: 0.32, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                }
            }
        }
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath()
        for i in 0...8 {
            let y = CGFloat(i * h / 8)
            path.move(to: NSPoint(x: 0.0, y: y))
            path.line(to: NSPoint(x: CGFloat(w), y: y))
        }
        path.lineWidth = 3; path.stroke()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: CGFloat(w / 2 - 90), y: CGFloat(h / 2 - 90),
                                    width: 180, height: 180)).fill()
        img.unlockFocus()

        // 深度：左近右远
        let dimg = NSImage(size: NSSize(width: w, height: h))
        dimg.lockFocus()
        NSGradient(starting: .black, ending: .white)?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 0)
        dimg.unlockFocus()

        if let c1 = renderer.cgImage(from: img), let c2 = renderer.cgImage(from: dimg) {
            renderer.quilt = renderer.texture(from: c1)
            renderer.depth = renderer.texture(from: c2)
            renderer.u.mode = 1
            statusLabel.stringValue = "合成测试图 \(w)×\(h)（左近右远）"
            redraw()
        }
    }

    @objc func toSecondary() { placeOutputOnSecondary() }

    @objc func toNativeSize() {
        let f = outWindow.frame
        outWindow.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: 1440, height: 2560), display: true)
        mtkView.frame = NSRect(x: 0, y: 0, width: 1440, height: 2560)
        mtkView.drawableSize = CGSize(width: 1440, height: 2560)
        redraw()
    }

    // 自动求对称周期：有符号和 L+R 的过零点，取 |L+R| 最小者
    @objc func solveInterval() {
        let W = Double(renderer.u.outW), H = Double(renderer.u.outH)
        let slope = Double(renderer.u.slope)
        let x0 = Double(renderer.u.x0)
        let depthF = Double(renderer.u.depthFactor)
        func LR(_ interval: Double) -> (Double, Double) {
            let pitch = (W * 3) / interval
            let s = slope * (H / W)
            let center = (x0 + 3) / interval
            let mp = 0.2 * depthF
            func vc(_ sux: Double) -> Double {
                var v = (sux + 0.5 * s) * pitch + center
                v -= floor(v)
                return 1 - v
            }
            let off = { (sux: Double, depth: Double) -> Double in
                (-(vc(sux) - 0.5)) * mp * (0.5 - depth) * 540
            }
            return (off(0.22, 0.0), off(0.78, 1.0))
        }
        let base = 19.6349
        var best: (Double, Double)? = nil
        var x = base - 0.075
        var prev = { () -> Double in let (l, r) = LR(x); return l + r }()
        while x <= base + 0.075 {
            let cur = { () -> Double in let (l, r) = LR(x); return l + r }()
            if prev * cur < 0 {
                let m = x - 0.00025
                let (l, r) = LR(m)
                if abs(l + r) < 5 && l * r < 0 {
                    if best == nil || abs(l + r) < best!.1 { best = (m, abs(l + r)) }
                }
            }
            prev = cur
            x += 0.0005
        }
        if let b = best {
            renderer.u.interval = Float(b.0)
            statusLabel.stringValue = String(format: "对称周期 %.5f（Δ%+.4f，|L+R|=%.2f px）", b.0, b.0 - base, b.1)
            redraw()
        } else {
            statusLabel.stringValue = "未找到对称周期（±0.075 内）"
        }
    }
}

// MARK: - main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
