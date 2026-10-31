// Stereo2View v4
import Cocoa
import Metal
import MetalKit
import AVFoundation
import CoreVideo

let VW = 1440, VH = 2560
let DEF_LINE: Float = 19.6349
let DEF_OBL: Float = 0.103813
let DEF_DEV: Float = 3.8456375
let DST_ASPECT: Float = Float(VW) / Float(VH)

struct P {
    var W: Float = Float(VW), H: Float = Float(VH)
    var obliquity: Float = DEF_OBL
    var lineNumber: Float = DEF_LINE
    var deviation: Float = DEF_DEV
    var N: Float = 2
    var swap: Float = 0
    var layout: Float = 0
    var zoom: Float = 1
    var panX: Float = 0, panY: Float = 0
    var shiftPx: Float = 0
    var flipY: Float = 0
    var projComp: Float = 0
    var srcAspect: Float = DST_ASPECT
    var fitMode: Float = 0
    var testMode: Float = 0
    var testDispPx: Float = 20
    var projMode: Float = 0
    var fovWin: Float = 60
    var yaw: Float = 0
    var pitch: Float = 0
    var srcFOV: Float = 60
    var dispGain: Float = 1
    var anamorphic: Float = 1
    var edgeFade: Float = 0
    var borderPx: Float = 0
    var eyeShiftY: Float = 0       // 右眼垂直偏移（uv）
    var eyeRot: Float = 0          // 右眼旋转（弧度）
    var eyeScale: Float = 0        // 右眼缩放差
}

let msl = """
#include <metal_stdlib>
using namespace metal;

struct P {
    float W; float H;
    float obliquity; float lineNumber; float deviation;
    float N; float swap; float layout;
    float zoom; float panX; float panY;
    float shiftPx; float flipY; float projComp;
    float srcAspect; float fitMode;
    float testMode; float testDispPx;
    float projMode; float fovWin; float yaw; float pitch;
    float srcFOV; float dispGain; float anamorphic;
    float edgeFade; float borderPx;
    float eyeShiftY; float eyeRot; float eyeScale; float pad2;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv  = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);
    return o;
}

// 单眼源图坐标（0..1）。bBound 越界时返回 false
static float2 srcUV(float2 scr, constant P &p, bool right, thread bool &ok) {
    const float PI = 3.14159265359;
    ok = true;

    if (p.projMode < 0.5) {
        float2 loc = (scr - 0.5) / p.zoom + 0.5 + float2(p.panX, p.panY);
        float2 c = loc - 0.5;
        if (p.fitMode < 0.5) {
            if (p.srcAspect > 0.5625) c.x *= 0.5625 / p.srcAspect;
            else                      c.y *= p.srcAspect / 0.5625;
        } else if (p.fitMode < 1.5) {
            if (p.srcAspect > 0.5625) c.y *= p.srcAspect / 0.5625;
            else                      c.x *= 0.5625 / p.srcAspect;
        }   // 2 = 拉伸，不调整
        loc = 0.5 + c;
        loc.x = 0.5 + (loc.x - 0.5) * p.anamorphic;
        float e = (p.dispGain - 1.0) * 0.2;              // 视差强度：左右眼反向缩放
        loc.x = 0.5 + (loc.x - 0.5) * (right ? 1.0 - e : 1.0 + e);
        if (right && (fabs(p.eyeRot) > 0.00001 || fabs(p.eyeScale) > 0.00001 || fabs(p.eyeShiftY) > 0.00001)) {
            float2 d = loc - 0.5;
            float ca = cos(p.eyeRot), sa = sin(p.eyeRot);
            d = float2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
            d *= (1.0 + p.eyeScale);
            d.y += p.eyeShiftY;
            loc = 0.5 + d;
        }
        if (fabs(p.projComp) > 0.0001) {
            float2 d = loc - 0.5;
            loc = 0.5 + d * (1.0 + p.projComp * dot(d, d) * 2.0);
        }
        return loc;
    }

    float2 ndc = float2(scr.x * 2.0 - 1.0, 1.0 - scr.y * 2.0);
    float tanH = tan(p.fovWin * 0.01745329252 * 0.5);
    float tanV = tanH / 0.5625;
    float3 d = normalize(float3(ndc.x * tanH, ndc.y * tanV, 1.0));
    float cy = cos(p.yaw), sy = sin(p.yaw);
    d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
    float cp = cos(p.pitch), sp = sin(p.pitch);
    d = float3(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
    d = normalize(d);

    float2 uv;
    if (p.projMode < 2.5) {
        float halfLon = (p.projMode < 1.5) ? PI * 0.5 : PI;
        uv = float2(0.5 + atan2(d.x, d.z) / (2.0 * halfLon),
                    0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
    } else {
        float theta = acos(clamp(d.z, -1.0, 1.0));
        float psi = atan2(d.y, d.x);
        float r = theta / (PI * 0.5);
        uv = float2(0.5 + 0.5 * r * cos(psi), 0.5 - 0.5 * r * sin(psi));
    }
    uv.x = 0.5 + (uv.x - 0.5) * (right ? 1.0 - (p.dispGain - 1.0) * 0.2 : 1.0 + (p.dispGain - 1.0) * 0.2);
    if (right && (fabs(p.eyeRot) > 0.00001 || fabs(p.eyeScale) > 0.00001 || fabs(p.eyeShiftY) > 0.00001)) {
        float2 d = uv - 0.5;
        float ca = cos(p.eyeRot), sa = sin(p.eyeRot);
        d = float2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
        d *= (1.0 + p.eyeScale);
        d.y += p.eyeShiftY;
        uv = 0.5 + d;
    }
    if (fabs(p.projComp) > 0.0001) {
        float2 d2 = uv - 0.5;
        uv = 0.5 + d2 * (1.0 + p.projComp * dot(d2, d2) * 2.0);
    }
    return uv;
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant P &p [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]]) {
    constexpr sampler sm(filter::linear, address::clamp_to_edge);

    float X = in.uv.x * p.W + 0.5;
    float Y = in.uv.y * p.H + 0.5;

    // 浮动黑框
    if (p.borderPx > 0.5 &&
        (X < p.borderPx || X > p.W - p.borderPx || Y < p.borderPx || Y > p.H - p.borderPx)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    if (p.testMode > 0.5) {
        float3 outc;
        for (int ch = 0; ch < 3; ++ch) {
            float x1 = (X + Y * p.obliquity) * 3.0 + float(ch);
            float xl = fmod(x1 + p.deviation, p.lineNumber);
            if (xl < 0.0) xl += p.lineNumber;
            int choice = (int)clamp(floor(xl / p.lineNumber * p.N), 0.0, p.N - 1.0);
            if (p.swap > 0.5) choice = int(p.N) - 1 - choice;
            float2 t = in.uv;
            if (choice == 1) t.x += p.testDispPx / p.W;
            float2 q = t * float2(p.W, p.H);
            float chk = fmod(floor(q.x / 24.0) + floor(q.y / 24.0), 2.0);
            float base = 0.07 + chk * 0.06;
            float bar  = (fabs(q.x - p.W * 0.5) < 4.0) ? 1.0 : 0.0;
            float hbar = (fabs(q.y - p.H * 0.5) < 3.0) ? 0.85 : 0.0;
            float mark = (fabs(q.x - p.W * 0.30) < 7.0 && fabs(q.y - p.H * 0.22) < 7.0) ? 1.0 : 0.0;
            outc[ch] = clamp(max(base, max(bar, max(hbar, mark))), 0.0, 1.0);
        }
        return float4(outc, 1.0);
    }

    // 两个视点各取一次（边缘融合需要）
    bool okL = true, okR = true;
    float2 uvL = srcUV(in.uv, p, false, okL);
    float2 uvR = srcUV(in.uv, p, true, okR);
    float shiftUV = p.shiftPx / p.W;

    float3 cL = float3(0.0), cR = float3(0.0);
    if (p.layout < 0.5) {
        float2 a = uvL; a.x = uvL.x * 0.5 - shiftUV * 0.25;      // 左眼右移一半
        float2 b = uvR; b.x = uvR.x * 0.5 + 0.5 + shiftUV * 0.25; // 右眼左移一半
        okL = okL && a.x >= 0.0 && a.x <= 0.5;
        okR = okR && b.x >= 0.5 && b.x <= 1.0;
        cL = okL ? tex.sample(sm, a).rgb : float3(0.0);
        cR = okR ? tex.sample(sm, b).rgb : float3(0.0);
    } else if (p.layout < 1.5) {
        float2 a = uvL; a.y = uvL.y * 0.5 - shiftUV * 0.25;
        float2 b = uvR; b.y = uvR.y * 0.5 + 0.5 + shiftUV * 0.25;
        okL = okL && a.y >= 0.0 && a.y <= 0.5;
        okR = okR && b.y >= 0.5 && b.y <= 1.0;
        cL = okL ? tex.sample(sm, a).rgb : float3(0.0);
        cR = okR ? tex.sample(sm, b).rgb : float3(0.0);
    } else {
        cL = okL ? tex.sample(sm, uvL).rgb : float3(0.0);
        cR = cL;
    }

    // 边缘融合：越靠边越接近两眼平均（消除窗框冲突）
    float m = 0.0;
    if (p.edgeFade > 0.001) {
        float2 q = float2(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
        float d = min(q.x, q.y) / max(0.001, p.edgeFade);
        m = clamp(1.0 - d, 0.0, 1.0);
        m = m * m * (3.0 - 2.0 * m);
    }
    float3 avg = (cL + cR) * 0.5;

    float3 outc;
    for (int ch = 0; ch < 3; ++ch) {
        float x1 = (X + Y * p.obliquity) * 3.0 + float(ch);
        float xl = fmod(x1 + p.deviation, p.lineNumber);
        if (xl < 0.0) xl += p.lineNumber;
        int choice = (int)clamp(floor(xl / p.lineNumber * p.N), 0.0, p.N - 1.0);
        if (p.swap > 0.5) choice = int(p.N) - 1 - choice;
        float v = (choice == 1) ? cR[ch] : cL[ch];
        outc[ch] = mix(v, avg[ch], m);
    }
    return float4(outc, 1.0);
}
"""

final class Core {
    let dev: MTLDevice
    let queue: MTLCommandQueue
    var pipe: MTLRenderPipelineState!
    var texCache: CVMetalTextureCache?
    var srcTex: MTLTexture?
    var srcSize = CGSize.zero
    var lastCG: CGImage?
    var lastPB: CVPixelBuffer?
    var params = P()

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        dev = d; queue = q
        do {
            let lib = try d.makeLibrary(source: msl, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipe = try d.makeRenderPipelineState(descriptor: desc)
        } catch {
            FileHandle.standardError.write(("pipeline: \(error)\n").data(using: .utf8)!)
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, d, nil, &texCache)
    }

    func setImage(_ url: URL) -> Bool {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let loader = MTKTextureLoader(device: dev)
        guard let t = try? loader.newTexture(cgImage: cg, options: [
            .SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)]) else { return false }
        srcTex = t; srcSize = CGSize(width: t.width, height: t.height); lastCG = cg; lastPB = nil
        params.flipY = 0; updateSrcAspect()
        return true
    }

    func setPixelBuffer(_ pb: CVPixelBuffer) {
        guard let cache = texCache else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                        w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let t = CVMetalTextureGetTexture(cvTex) else { return }
        srcTex = t
        lastPB = pb; lastCG = nil
        if Int(srcSize.width) != w || Int(srcSize.height) != h {
            srcSize = CGSize(width: w, height: h); updateSrcAspect()
        }
    }

    func updateSrcAspect() {
        guard srcSize.width > 0, srcSize.height > 0 else { return }
        var ew = Double(srcSize.width), eh = Double(srcSize.height)
        if params.layout < 0.5 { ew *= 0.5 }
        else if params.layout < 1.5 { eh *= 0.5 }
        params.srcAspect = Float(ew / eh)
    }
}

final class PanelView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat, Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.deltaX, e.deltaY) }
    override func scrollWheel(with e: NSEvent) { onScroll?(e.scrollingDeltaY, e.hasPreciseScrollingDeltas) }
}

final class App: NSObject, NSApplicationDelegate, MTKViewDelegate {
    var core: Core!
    var panelWin: NSWindow!
    var ctrlWin: NSWindow!
    var player: AVPlayer?
    var videoOut: AVPlayerItemVideoOutput?
    var statusLabel: NSTextField!
    var fileLabel: NSTextField!
    var timeLabel: NSTextField!
    var progress: NSSlider!
    var playBtn: NSButton!
    var timer: Timer?
    var sliders: [String: NSSlider] = [:]
    var fields: [String: NSTextField] = [:]
    var dumpPath: String?
    var autoclose: Double = 0
    var windowMode = false
    var saved: (fov: Float, gain: Float, edge: Float, border: Float)?

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let c = Core() else { exit(2) }
        core = c
        buildPanel(); buildControls(); parseArgs()
        core.updateSrcAspect()
        if core.srcTex == nil { loadTestImage() }
        syncUI(); updateInfo()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NSApp.activate(ignoringOtherApps: true)
        if dumpPath != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.dump() } }
        if autoclose > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + autoclose) { NSApp.terminate(nil) } }
    }

    func buildPanel() {
        let scr = NSScreen.screens.first { Int($0.frame.height) == VH && Int($0.frame.width) == VW }
            ?? NSScreen.screens.first { Int($0.frame.width) == VW } ?? NSScreen.main!
        let f = scr.frame
        panelWin = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false, screen: scr)
        panelWin.setFrame(f, display: true)
        panelWin.level = .normal
        panelWin.backgroundColor = .black
        panelWin.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = PanelView(frame: NSRect(origin: .zero, size: f.size), device: core.dev)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColorMake(0, 0, 0, 1)
        v.delegate = self
        v.preferredFramesPerSecond = 60
        v.enableSetNeedsDisplay = false
        v.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            let p = self.core.params
            if p.projMode < 0.5 {
                let z = max(0.01, Double(p.zoom))
                self.core.params.panX -= Float(Double(dx) * 2.0 / Double(VW) / z)
                self.core.params.panY -= Float(Double(dy) * 2.0 / Double(VH) / z)
            } else {
                let k = Double(p.fovWin) * .pi / 180.0 / Double(VW) * 1.6
                self.core.params.yaw -= Float(Double(dx) * k)
                self.core.params.pitch += Float(Double(dy) * k)
            }
            self.updateInfo()
        }
        v.onScroll = { [weak self] dy, precise in
            guard let self else { return }
            let step = precise ? 0.025 : 0.10
            self.setFOV(Double(self.core.params.fovWin) * exp(-Double(dy) * step * 3.0))
        }
        panelWin.contentView = v
        panelWin.ignoresMouseEvents = false
        panelWin.acceptsMouseMovedEvents = true
        panelWin.makeKeyAndOrderFront(nil)
        panelWin.orderFrontRegardless()
    }

    func buildControls() {
        let CW: CGFloat = 428
        ctrlWin = NSWindow(contentRect: NSRect(x: 70, y: 60, width: CW, height: 700),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ctrlWin.title = "Stereo2View"
        ctrlWin.level = .floating

        func header(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            return l
        }
        func hrow(_ v: [NSView], spacing: CGFloat = 6) -> NSStackView {
            let st = NSStackView(views: v)
            st.orientation = .horizontal
            st.spacing = spacing
            st.alignment = .centerY
            return st
        }
        func makeSliderRow(_ name: String, _ lo: Double, _ hi: Double, _ v: Double, _ fmt: String) -> NSView {
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 11)
            l.widthAnchor.constraint(equalToConstant: 82).isActive = true
            let sl = NSSlider(value: v, minValue: lo, maxValue: hi, target: self, action: #selector(sliderMoved(_:)))
            sl.identifier = NSUserInterfaceItemIdentifier(name)
            sl.widthAnchor.constraint(equalToConstant: 210).isActive = true
            let f = NSTextField(string: String(format: fmt, v))
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.alignment = .right
            f.identifier = NSUserInterfaceItemIdentifier(name)
            f.target = self; f.action = #selector(fieldChanged(_:))
            f.widthAnchor.constraint(equalToConstant: 72).isActive = true
            sliders[name] = sl; fields[name] = f
            return hrow([l, sl, f])
        }
        func iconButton(_ symbol: String, _ action: Selector, tip: String) -> NSButton {
            let b = NSButton(title: "", target: self, action: action)
            b.bezelStyle = .rounded
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
                b.image = img; b.imagePosition = .imageOnly
            } else { b.title = tip }
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.toolTip = tip
            return b
        }
        func page(_ rows: [NSView]) -> NSView {
            let st = NSStackView(views: rows)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 8
            st.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
            st.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView()
            host.addSubview(st)
            NSLayoutConstraint.activate([
                st.topAnchor.constraint(equalTo: host.topAnchor),
                st.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                st.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            return host
        }

        // ── 顶部：源 + 播放
        let top = NSStackView()
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 6
        top.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        top.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "打开图像 / 视频…", target: self, action: #selector(openFile))
        open.bezelStyle = .rounded
        top.addArrangedSubview(open)

        fileLabel = NSTextField(labelWithString: "（未载入）")
        fileLabel.font = .systemFont(ofSize: 11, weight: .medium)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.widthAnchor.constraint(equalToConstant: CW - 28).isActive = true
        top.addArrangedSubview(fileLabel)

        progress = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seek(_:)))
        progress.isContinuous = true
        progress.widthAnchor.constraint(equalToConstant: CW - 28).isActive = true
        top.addArrangedSubview(progress)

        let back5 = iconButton("gobackward.5", #selector(skipBack), tip: "后退 5 秒")
        playBtn = iconButton("play.fill", #selector(togglePlay), tip: "播放 / 暂停")
        let fwd5 = iconButton("goforward.5", #selector(skipFwd), tip: "前进 5 秒")
        let mute = iconButton("speaker.slash", #selector(toggleMute), tip: "静音 / 取消")
        timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        top.addArrangedSubview(hrow([back5, playBtn, fwd5, mute, timeLabel], spacing: 8))

        // ── 三个分页
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let fitRows: [NSView] = [
            header("源投影方式"),
            { let p = NSPopUpButton(); p.addItems(withTitles: ["直线（普通双目）", "等距柱状 180", "等距柱状 360", "鱼眼 180"])
              p.target = self; p.action = #selector(projChanged(_:)); return p }(),
            makeSliderRow("源FOV°", 10, 200, 60, "%.0f"),
            makeSliderRow("窗口FOV°", 3, 120, 60, "%.1f"),
            makeSliderRow("横向比例", 0.5, 2.0, 1, "%.3f"),
            { let p = NSPopUpButton(); p.addItems(withTitles: ["填满（裁切）", "适应（黑边）", "拉伸（变形）"])
              p.target = self; p.action = #selector(fitChanged(_:)); return p }(),
            header("取景（面板上拖动 = 平移，滚轮 = 缩放）"),
            makeSliderRow("水平", -0.5, 0.5, 0, "%.3f"),
            makeSliderRow("垂直", -0.5, 0.5, 0, "%.3f"),
        ]

        let stereoRows: [NSView] = [
            header("交织"),
            makeSliderRow("交织相位", 0, 40, Double(DEF_DEV), "%.3f"),
            makeSliderRow("零视差面px", -150, 150, 0, "%.0f"),
            makeSliderRow("视差强度", 0.5, 1.5, 1.0, "%.2f"),
            header("右眼对位（远景对不上时先调这里）"),
            makeSliderRow("右眼垂直px", -40, 40, 0, "%.0f"),
            makeSliderRow("右眼旋转°", -2, 2, 0, "%.2f"),
            makeSliderRow("右眼缩放%", -5, 5, 0, "%.1f"),
            header("窗口模式（试验）"),
            NSButton(checkboxWithTitle: "全入屏 + 收视角 + 窗框", target: self, action: #selector(toggleWindow(_:))),
            { let b = NSButton(title: "对齐主体到屏面", target: self, action: #selector(alignSubject))
              b.bezelStyle = .rounded; return b }(),
        ]

        let moreRows: [NSView] = [
            header("舒适度"),
            makeSliderRow("边缘融合%", 0, 30, 0, "%.0f"),
            makeSliderRow("浮窗黑边px", 0, 60, 0, "%.0f"),
            makeSliderRow("径向残留", -0.6, 0.6, 0, "%.2f"),
            header("测试"),
            NSButton(checkboxWithTitle: "视差靶", target: self, action: #selector(toggleTest(_:))),
            makeSliderRow("靶视差px", 0, 160, 20, "%.0f"),
        ]

        for (title, rows) in [("取景", fitRows), ("立体", stereoRows), ("更多", moreRows)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = page(rows)
            tabs.addTabViewItem(item)
        }

        // ── 底部
        let bottom = NSStackView()
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let pop = NSPopUpButton()
        pop.addItems(withTitles: ["SBS 左右", "TB 上下", "单眼"])
        pop.target = self; pop.action = #selector(layoutChanged(_:))
        let swapBtn = NSButton(checkboxWithTitle: "交换左右", target: self, action: #selector(toggleSwap(_:)))
        let quit = NSButton(title: "退出", target: self, action: #selector(doQuit))
        quit.bezelStyle = .rounded
        bottom.addArrangedSubview(hrow([pop, swapBtn, quit]))

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.widthAnchor.constraint(equalToConstant: CW - 28).isActive = true
        bottom.addArrangedSubview(statusLabel)

        let root = NSView()
        for v in [top, tabs, bottom] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            tabs.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tabs.heightAnchor.constraint(equalToConstant: 300),

            bottom.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        ctrlWin.contentView = root
        ctrlWin.makeKeyAndOrderFront(nil)
        ctrlWin.orderFrontRegardless()
    }

    func syncUI() {
        for (k, s) in sliders {
            if let v = sliderValue(k) { s.doubleValue = v }
        }
        fields["窗口FOV°"]?.stringValue = String(format: "%.1f", core.params.fovWin)
        fields["源FOV°"]?.stringValue = String(format: "%.0f", core.params.srcFOV)
        fields["横向比例"]?.stringValue = String(format: "%.3f", core.params.anamorphic)
        fields["视差强度"]?.stringValue = String(format: "%.2f", core.params.dispGain)
        fields["边缘融合%"]?.stringValue = String(format: "%.0f", Double(core.params.edgeFade) * 100)
        fields["浮窗黑边px"]?.stringValue = String(format: "%.0f", core.params.borderPx)
    }
    func sliderValue(_ k: String) -> Double? {
        switch k {
        case "源FOV°": return Double(core.params.srcFOV)
        case "窗口FOV°": return Double(core.params.fovWin)
        case "横向比例": return Double(core.params.anamorphic)
        case "水平": return Double(core.params.panX)
        case "垂直": return Double(core.params.panY)
        case "交织相位": return Double(core.params.deviation)
        case "零视差面px": return Double(core.params.shiftPx)
        case "视差强度": return Double(core.params.dispGain)
        case "边缘融合%": return Double(core.params.edgeFade) * 100
        case "浮窗黑边px": return Double(core.params.borderPx)
        case "径向残留": return Double(core.params.projComp)
        case "靶视差px": return Double(core.params.testDispPx)
        case "右眼垂直px": return Double(core.params.eyeShiftY) * eyeHeightPx()
        case "右眼旋转°": return Double(core.params.eyeRot) * 180 / .pi
        case "右眼缩放%": return Double(core.params.eyeScale) * 100
        default: return nil
        }
    }

    func eyeHeightPx() -> Double {
        let h = Double(core.srcSize.height)
        return core.params.layout < 1.5 && core.params.layout >= 0.5 ? h * 0.5 : h
    }

    func setFOV(_ fov: Double) {
        let f = max(3, min(120, fov))
        core.params.fovWin = Float(f)
        if core.params.projMode < 0.5 {
            core.params.zoom = Float(max(0.2, Double(core.params.srcFOV) / f))
        }
        sliders["窗口FOV°"]?.doubleValue = f
        fields["窗口FOV°"]?.stringValue = String(format: "%.1f", f)
        updateInfo()
    }

    @objc func sliderMoved(_ s: NSSlider) {
        guard let name = s.identifier?.rawValue else { return }
        apply(name, s.doubleValue)
        fields[name]?.stringValue = String(format: name.contains("px") || name.contains("%") ? "%.0f" : "%.3f", s.doubleValue)
    }
    @objc func fieldChanged(_ f: NSTextField) {
        guard let name = f.identifier?.rawValue, let v = Double(f.stringValue) else { return }
        apply(name, v); sliders[name]?.doubleValue = v
    }
    func apply(_ name: String, _ v: Double) {
        switch name {
        case "源FOV°":
            core.params.srcFOV = Float(v)
            if core.params.projMode < 0.5 { core.params.zoom = Float(max(0.2, v / Double(core.params.fovWin))) }
        case "窗口FOV°": setFOV(v); return
        case "横向比例": core.params.anamorphic = Float(v)
        case "水平": core.params.panX = Float(v)
        case "垂直": core.params.panY = Float(v)
        case "交织相位": core.params.deviation = Float(v)
        case "零视差面px": core.params.shiftPx = Float(v)
        case "视差强度": core.params.dispGain = Float(v)
        case "边缘融合%": core.params.edgeFade = Float(v / 100)
        case "浮窗黑边px": core.params.borderPx = Float(v)
        case "径向残留": core.params.projComp = Float(v)
        case "靶视差px": core.params.testDispPx = Float(v)
        case "右眼垂直px": core.params.eyeShiftY = Float(v / eyeHeightPx())
        case "右眼旋转°": core.params.eyeRot = Float(v * .pi / 180)
        case "右眼缩放%": core.params.eyeScale = Float(v / 100)
        default: break
        }
        updateInfo()
    }

    @objc func layoutChanged(_ s: NSPopUpButton) { core.params.layout = Float(s.indexOfSelectedItem); core.updateSrcAspect(); updateInfo() }
    @objc func projChanged(_ s: NSPopUpButton) {
        core.params.projMode = Float(s.indexOfSelectedItem)
        let preset: [Float] = [60, 180, 360, 180]
        core.params.srcFOV = preset[min(3, s.indexOfSelectedItem)]
        sliders["源FOV°"]?.doubleValue = Double(core.params.srcFOV)
        fields["源FOV°"]?.stringValue = String(format: "%.0f", core.params.srcFOV)
        if core.params.projMode < 0.5 {
            core.params.zoom = Float(Double(core.params.srcFOV) / Double(core.params.fovWin))
        }
        updateInfo()
    }
    @objc func fitChanged(_ s: NSPopUpButton) { core.params.fitMode = Float(s.indexOfSelectedItem); updateInfo() }
    @objc func toggleWindow(_ b: NSButton) {
        windowMode = (b.state == .on)
        if windowMode {
            saved = (core.params.fovWin, core.params.dispGain, core.params.edgeFade, core.params.borderPx)
            setFOV(min(Double(core.params.fovWin), 25))
            core.params.dispGain = 0.90
            core.params.edgeFade = 0.10
            core.params.borderPx = 24
        } else if let sv = saved {
            core.params.fovWin = sv.fov
            core.params.dispGain = sv.gain
            core.params.edgeFade = sv.edge
            core.params.borderPx = sv.border
            if core.params.projMode < 0.5 {
                core.params.zoom = Float(Double(core.params.srcFOV) / Double(sv.fov))
            }
            saved = nil
        }
        syncUI(); updateInfo()
    }

    // 把画面里"最近的一侧"对齐到屏面：用亮度直方图找左右眼的整体平移量
    @objc func alignSubject() {
        guard let r = estimateShift2() else { statusLabel.stringValue = "无法估计（需要静帧或已载入视频帧）"; return }
        core.params.shiftPx = Float(r.0)
        core.params.eyeShiftY = Float(r.1) / Float(VH)
        syncUI(); updateInfo()
    }

    /// 返回 (水平位移 px, 垂直位移 px)，垂直用于右眼对位
    func estimateShift2() -> (Int, Int)? {
        guard let img = grabGray() else { return nil }
        let (l, r, w, h) = img
        guard w > 8, h > 8 else { return nil }
        var bestS = 0, bestY = 0, bestCost = Double.greatestFiniteMagnitude
        let maxS = min(24, w / 4)
        let maxY = min(8, h / 6)
        for s in -maxS...maxS {
            for dy in -maxY...maxY {
                var cost = 0.0, n = 0.0
                for y in stride(from: h/5, to: h*4/5, by: 3) {
                    for x in stride(from: w/5, to: w*4/5 - 1, by: 3) {
                        let xr = x + s, yr = y + dy
                        if xr < 0 || xr >= w || yr < 0 || yr >= h { continue }
                        cost += Double(abs(Int(l[y*w + x]) - Int(r[yr*w + xr]))); n += 1
                    }
                }
                if n > 0 { cost /= n }
                if cost < bestCost { bestCost = cost; bestS = s; bestY = dy }
            }
        }
        return (Int(Double(bestS) * 1440.0 / Double(w)), Int(Double(bestY) * 2560.0 / Double(h)))
    }

    func estimateShift() -> Int? {
        guard let img = grabGray() else { return nil }
        let (l, r, w, h) = img
        guard w > 8, h > 8 else { return nil }
        var bestS = 0, bestCost = Double.greatestFiniteMagnitude
        let maxS = min(24, w / 4)
        for s in -maxS...maxS {
            var cost = 0.0, n = 0.0
            for y in stride(from: h/5, to: h*4/5, by: 2) {
                for x in stride(from: w/5, to: w*4/5 - 1, by: 2) {
                    let xr = x + s
                    if xr < 0 || xr >= w { continue }
                    let a = Int(l[y*w + x]), b = Int(r[y*w + xr])
                    cost += Double(abs(a - b)); n += 1
                }
            }
            if n > 0 { cost /= n }
            if cost < bestCost { bestCost = cost; bestS = s }
        }
        // 下采样 160 宽 -> 面板 1440 宽
        return Int(Double(bestS) * 1440.0 / Double(w))
    }

    // 读回当前帧，左右眼各降采样成灰度
    func grabGray() -> ([UInt8], [UInt8], Int, Int)? {
        let tw = 160, th = 120
        if let cg = core.lastCG {
            let w = cg.width, h = cg.height
            var gray = [UInt8](repeating: 0, count: w*h)
            guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return downsample(gray, w, h, tw, th)
        }
        if let pb = core.lastPB {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            var gray = [UInt8](repeating: 0, count: w*h)
            for y in 0..<h {
                for x in 0..<w {
                    let o = y*stride + x*4
                    gray[y*w + x] = UInt8((Int(p[o]) + Int(p[o+1]) + Int(p[o+2])) / 3)
                }
            }
            return downsample(gray, w, h, tw, th)
        }
        return nil
    }

    func downsample(_ g: [UInt8], _ w: Int, _ h: Int, _ tw: Int, _ th: Int) -> ([UInt8], [UInt8], Int, Int) {
        var l = [UInt8](repeating: 0, count: tw * th)
        var r = [UInt8](repeating: 0, count: tw * th)
        let isSBS = core.params.layout < 0.5
        let isTB = core.params.layout < 1.5
        for y in 0..<th {
            for x in 0..<tw {
                let sx = x * w / tw
                let sy = y * h / th
                var lx = sx, ly = sy, rx = sx, ry = sy
                if isSBS { lx = sx / 2; rx = w / 2 + sx / 2 }
                else if isTB { ly = sy / 2; ry = h / 2 + sy / 2 }
                l[y * tw + x] = g[ly * w + lx]
                r[y * tw + x] = g[ry * w + rx]
            }
        }
        return (l, r, tw, th)
    }

    @objc func toggleSwap(_ b: NSButton) { core.params.swap = b.state == .on ? 1 : 0 }
    @objc func toggleTest(_ b: NSButton) { core.params.testMode = b.state == .on ? 1 : 0; updateInfo() }
    @objc func togglePlay() {
        guard let p = player else { return }
        if p.rate > 0 { p.pause() } else { p.play() }
    }
    @objc func doQuit() { NSApp.terminate(nil) }

    @objc func toggleMute() {
        guard let p = player else { return }
        p.isMuted.toggle()
    }
    @objc func skipBack() { seekRelative(-5) }
    @objc func skipFwd() { seekRelative(5) }
    func seekRelative(_ sec: Double) {
        guard let p = player else { return }
        let t = CMTimeGetSeconds(p.currentTime())
        let d = CMTimeGetSeconds(p.currentItem?.duration ?? CMTime.indefinite)
        var nt = max(0, t + sec)
        if d.isFinite, d > 0 { nt = min(nt, max(0, d - 0.05)) }
        p.seek(to: CMTime(seconds: nt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick()
    }

    @objc func seek(_ s: NSSlider) {
        guard let p = player, let item = p.currentItem else { return }
        let d = CMTimeGetSeconds(item.duration)
        guard d.isFinite, d > 0 else { return }
        p.seek(to: CMTime(seconds: s.doubleValue * d, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func tick() {
        guard let p = player, let item = p.currentItem else { return }
        let d = CMTimeGetSeconds(item.duration)
        let t = CMTimeGetSeconds(p.currentTime())
        guard d.isFinite, d > 0 else { return }
        if progress.cell?.isHighlighted != true {
            progress.doubleValue = min(1, max(0, t / d))
        }
        timeLabel.stringValue = String(format: "%d:%02d / %d:%02d", Int(t) / 60, Int(t) % 60, Int(d) / 60, Int(d) % 60)
        let symbol = (p.rate > 0) ? "pause.fill" : "play.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { playBtn?.image = img }
    }

    @objc func openFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "mp4", "mov", "m4v"]
        if p.runModal() == .OK, let u = p.url { _ = load(path: u.path) }
    }

    func load(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        if isVideo {
            let item = AVPlayerItem(url: url)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary])
            item.add(out)
            videoOut = out
            player = AVPlayer(playerItem: item)
            player?.play()
            progress.doubleValue = 0
        } else {
            guard core.setImage(url) else { fileLabel.stringValue = "图像载入失败"; return false }
            player?.pause(); player = nil; videoOut = nil
            progress.doubleValue = 0
            timeLabel.stringValue = "静帧"
        }
        fileLabel.stringValue = url.lastPathComponent
        updateInfo()
        return true
    }

    func loadTestImage() {
        let w = 1080, h = 960
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for eye in 0..<2 {
            let base = CGFloat(eye) * 540
            ctx.setFillColor(NSColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: base + 220, y: 400, width: 100, height: 100))
            let dx: CGFloat = eye == 0 ? 7 : -7
            ctx.setFillColor(NSColor(red: 0.9, green: 0.35, blue: 0.3, alpha: 1).cgColor)
            ctx.fill(CGRect(x: base + 250 + dx, y: 620, width: 60, height: 120))
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor); ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: base + 6, y: 6, width: 528, height: 948))
        }
        let cg = ctx.makeImage()!
        let loader = MTKTextureLoader(device: core.dev)
        if let t = try? loader.newTexture(cgImage: cg, options: [.SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)]) {
            core.srcTex = t; core.srcSize = CGSize(width: w, height: h); core.params.flipY = 0
            fileLabel.stringValue = "内置测试图（SBS 1080×960）"
        }
    }

    func updateInfo() {
        let p = core.params
        let sw = Int(core.srcSize.width), sh = Int(core.srcSize.height)
        let names = ["直线", "等距柱状180", "等距柱状360", "鱼眼180"]
        let mode = names[min(3, max(0, Int(p.projMode)))]
        let fitNames = ["填满", "适应", "拉伸"]
        let view = p.projMode < 0.5
            ? String(format: "缩放 %.2f (源%.0f° → 窗口%.1f°)", Double(p.zoom), Double(p.srcFOV), Double(p.fovWin))
            : String(format: "FOV %.1f° 偏航 %.1f° 俯仰 %.1f°", Double(p.fovWin),
                     Double(p.yaw) * 180 / .pi, Double(p.pitch) * 180 / .pi)
        statusLabel.stringValue = String(format:
            "源 %d×%d · %@ · %@\n%@\n相位 %.2f · 零视差 %+.0fpx · 视差强度 %.2f · 融合 %.0f%% · 黑边 %.0fpx",
            sw, sh, mode, fitNames[min(2, max(0, Int(p.fitMode)))], view,
            Double(p.deviation), Double(p.shiftPx), Double(p.dispGain),
            Double(p.edgeFade) * 100, Double(p.borderPx))
    }

    func parseArgs() {
        let a = CommandLine.arguments
        var i = 1
        while i < a.count {
            func val() -> String? { i + 1 < a.count ? a[i + 1] : nil }
            switch a[i] {
            case "--file": if let v = val() { _ = load(path: v) }; i += 2
            case "--layout": if let v = val() { core.params.layout = v == "tb" ? 1 : (v == "mono" ? 2 : 0); core.updateSrcAspect() }; i += 2
            case "--proj": if let v = val() { core.params.projMode = v == "eq180" ? 1 : (v == "eq360" ? 2 : (v == "fisheye" ? 3 : 0)) }; i += 2
            case "--fov": if let v = val(), let d = Double(v) { setFOV(d) }; i += 2
            case "--srcfov": if let v = val(), let d = Double(v) { core.params.srcFOV = Float(d) }; i += 2
            case "--yaw": if let v = val(), let d = Double(v) { core.params.yaw = Float(d * .pi / 180) }; i += 2
            case "--pitch": if let v = val(), let d = Double(v) { core.params.pitch = Float(d * .pi / 180) }; i += 2
            case "--deviation": if let v = val(), let d = Double(v) { core.params.deviation = Float(d) }; i += 2
            case "--shift": if let v = val(), let d = Double(v) { core.params.shiftPx = Float(d) }; i += 2
            case "--gain": if let v = val(), let d = Double(v) { core.params.dispGain = Float(d) }; i += 2
            case "--anamorphic": if let v = val(), let d = Double(v) { core.params.anamorphic = Float(d) }; i += 2
            case "--edge": if let v = val(), let d = Double(v) { core.params.edgeFade = Float(d) }; i += 2
            case "--border": if let v = val(), let d = Double(v) { core.params.borderPx = Float(d) }; i += 2
            case "--projcomp": if let v = val(), let d = Double(v) { core.params.projComp = Float(d) }; i += 2
            case "--fit": if let v = val() { core.params.fitMode = v == "letter" ? 1 : (v == "stretch" ? 2 : 0) }; i += 2
            case "--swap": core.params.swap = 1; i += 1
            case "--eyey": if let v = val(), let d = Double(v) { core.params.eyeShiftY = Float(d / eyeHeightPx()) }; i += 2
            case "--eyerot": if let v = val(), let d = Double(v) { core.params.eyeRot = Float(d * .pi / 180) }; i += 2
            case "--eyescale": if let v = val(), let d = Double(v) { core.params.eyeScale = Float(d / 100) }; i += 2
            case "--window":
                core.params.dispGain = 0.90; core.params.edgeFade = 0.10; core.params.borderPx = 24
                core.params.fovWin = 25; core.params.zoom = Float(Double(core.params.srcFOV) / 25.0)
                i += 1
            case "--test": core.params.testMode = 1; i += 1
            case "--testdisp": if let v = val(), let d = Double(v) { core.params.testDispPx = Float(d) }; i += 2
            case "--dump": if let v = val() { dumpPath = v }; i += 2
            case "--autoclose": if let v = val(), let d = Double(v) { autoclose = d }; i += 2
            default: i += 1
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let out = videoOut, let p = player,
           let pb = out.copyPixelBuffer(forItemTime: p.currentTime(), itemTimeForDisplay: nil) {
            core.setPixelBuffer(pb)
        }
        guard let pass = view.currentRenderPassDescriptor,
              let cmd = core.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let tex = core.srcTex {
            enc.setRenderPipelineState(core.pipe)
            enc.setFragmentTexture(tex, index: 0)
            var pp = core.params
            enc.setFragmentBytes(&pp, length: MemoryLayout<P>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        if let d = view.currentDrawable { cmd.present(d) }
        cmd.commit()
    }

    func dump() {
        guard let path = dumpPath, let tex = core.srcTex else { NSApp.terminate(nil); return }
        let d = core.dev
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: VW, height: VH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .managed
        guard let rt = d.makeTexture(descriptor: td) else { NSApp.terminate(nil); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = rt
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let cmd = core.queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(core.pipe)
        enc.setFragmentTexture(tex, index: 0)
        var pp = core.params
        enc.setFragmentBytes(&pp, length: MemoryLayout<P>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let blit = cmd.makeBlitCommandEncoder()!
        blit.synchronize(resource: rt)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()

        var buf = [UInt8](repeating: 0, count: VW * VH * 4)
        rt.getBytes(&buf, bytesPerRow: VW * 4, from: MTLRegionMake2D(0, 0, VW, VH), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let cg = buf.withUnsafeMutableBytes { ptr -> CGImage? in
            CGContext(data: ptr.baseAddress, width: VW, height: VH, bitsPerComponent: 8,
                      bytesPerRow: VW * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
        if let cg, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("dumped \(path)")
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.run()
