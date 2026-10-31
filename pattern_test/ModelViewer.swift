// ModelViewer — Companion-01 裸眼 3D 屏：标准模型实时查看器
// 编译: swiftc -O ModelViewer.swift -o ModelViewer -framework Metal -framework MetalKit -framework AppKit
// 用法:
//   ./ModelViewer                      控制窗 + 面板输出窗
//   ./ModelViewer --probe              只做显示通路自检(纯色+移动白条), 8 秒退出
//   ./ModelViewer --dump out.png       离屏渲一帧(1440×2560 交织后), 不出窗口
import AppKit
import Metal
import MetalKit
import simd

let PW = 1440, PH = 2560, VW = 540, VH = 960

// MARK: - 着色器

let shaderSrc = """
#include <metal_stdlib>
using namespace metal;

struct VIn { packed_float3 pos; packed_float3 nrm; packed_float3 col; };
struct VOut { float4 pos [[position]]; float3 nrm; float3 col; float3 wp; };

struct U {
    float4x4 mvp;
    float4x4 nm;
    float4   light;     // xyz, w=unused
    float4   eye;
    float4   tint;      // rgb, w = checker scale (0 = 平涂)
    float4   flags;     // x = 高光强度
};

vertex VOut vmain(uint vid [[vertex_id]], constant VIn* verts [[buffer(0)]], constant U& u [[buffer(1)]]) {
    VIn v = verts[vid];
    VOut o;
    float4 p = float4(v.pos, 1.0);
    o.pos = u.mvp * p;
    o.wp  = (u.nm * p).xyz;
    o.nrm = normalize((u.nm * float4(v.nrm, 0.0)).xyz);
    o.col = v.col;
    return o;
}

fragment float4 fmain(VOut in [[stage_in]], constant U& u [[buffer(1)]]) {
    float3 n = normalize(in.nrm);
    float3 L = normalize(u.light.xyz);
    float3 V = normalize(u.eye.xyz - in.wp);
    float3 base = in.col * u.tint.rgb;

    float chk = 1.0;
    if (u.tint.w > 0.0) {
        float2 g = floor(in.wp.xz * u.tint.w);
        chk = fmod(g.x + g.y, 2.0) < 0.5 ? 0.55 : 1.0;
    }
    base *= chk;

    float diff = max(dot(n, L), 0.0);
    float3 h = normalize(L + V);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * u.flags.x;
    float rim = pow(1.0 - max(dot(n, V), 0.0), 3.0) * 0.35;
    float3 lit = base * (0.22 + 0.85 * diff) + float3(spec) + float3(rim) * 0.6;
    return float4(lit, 1.0);
}

// ---- 交织: 输出面板像素 = 3 个子像素各自的视点色平均 ----
struct IU {
    float lineNumber;
    float obliquity;
    float deviation;
    float views;
    float cols;
    float rows;
    float mode;      // 0 = 交织  1 = 预览(中心视点)  2 = 直接看图集
    float invert;    // 1 = 反转视点序
    float phase;     // 用户相位偏移（子像素）
    float autoSnap;  // 低 N 奇数时自动半格，把分界线推到屏幕正中
    float camCount;  // 实际渲染的相机数（图集格数）
    float every;     // 每隔多少槽渲染一台相机（1 = 全渲染）
    float marker;    // 1 = 左上角画立体对齐标记
    float mono;      // 1 = 诊断: 三个子像素取同一视点（消除彩边，检验重影来源）
    float chromaAA;  // 1 = 亮度/色度解耦：保留子像素亮度定向，色度向中心视点收敛
};

struct QOut { float4 pos [[position]]; float2 uv; };

struct MU { float4 rect; float4 color; float side; };   // rect = (cx, cy, rx, ry) 归一化视口坐标

// 半盘标记：side<0.5 → 画左半；否则画右半。两半拼合 = 完整圆盘
fragment float4 fmark(QOut in [[stage_in]], constant MU& m [[buffer(2)]]) {
    // m.side = 该视点的横向视差偏移（uv）：整块标记随视点平移 → 悬浮在屏前
    float2 c = m.rect.xy + float2(m.side, 0.0);
    float2 d = (in.uv - c) / m.rect.zw;
    float rr = length(d);
    if (rr > 1.0) discard_fragment();
    if (rr > 0.78) {                                   // 外环
        float k = smoothstep(0.78, 0.84, rr) * (1.0 - smoothstep(0.94, 1.0, rr));
        return float4(mix(float3(0.03), m.color.rgb, k), 1.0);
    }
    if (rr < 0.22) return float4(m.color.rgb, 1.0);     // 中心点
    discard_fragment();                                 // 中间镂空
}

vertex QOut qmain(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    QOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv  = (p[vid] * float2(0.5, -0.5) + 0.5);
    return o;
}

float2 viewUV(int view, float2 pix, constant IU& u) {
    int c = int(u.cols);
    int col = c - (view % c) - 1;
    int row = view / c;
    if (col < 0) col = 0;
    if (row >= int(u.rows)) row = int(u.rows) - 1;
    return (float2(float(col) * 540.0, float(row) * 960.0) + pix) / float2(4320.0, 4800.0);
}

fragment float4 fsolid(QOut in [[stage_in]], constant U& u [[buffer(1)]]) {
    return float4(u.tint.rgb, 1.0);
}

inline float4 sampleCam(texture2d<float> tex, sampler smp, int cam, float2 pix, constant IU& u) {
    int c = max(1, int(u.cols));
    int col = cam % c, row = cam / c;
    float2 uv = (float2(float(col) * 540.0, float(row) * 960.0) + pix) / float2(4320.0, 4800.0);
    return tex.sample(smp, uv);
}

fragment float4 qfrag(QOut in [[stage_in]], constant IU& u [[buffer(0)]],
                      texture2d<float> quilt [[texture(0)]], sampler smp [[sampler(0)]]) {
    float2 pix = in.uv * float2(540.0, 960.0);
    if (u.mode > 1.5) return quilt.sample(smp, in.uv);          // 直接看图集
    if (u.mode > 0.5) {                                          // 预览: 中心槽位（同样走内插）
        int mid = int(u.views * 0.5);
        int mm = max(1, int(u.every));
        int lastC = max(0, int(u.camCount) - 1);
        int a0 = min(mid / mm, lastC), b0 = min(a0 + 1, lastC);
        float w0 = float(mid - a0 * mm) / float(max(1, mm));
        return mix(sampleCam(quilt, smp, a0, pix, u), sampleCam(quilt, smp, b0, pix, u), w0);
    }
    // 厂家算法: 每个子像素查一个视点, R/G/B 各取一个 —— 不做平均!
    float X = in.uv.x * 1440.0 + 0.5;
    float Y = in.uv.y * 2560.0 + 0.5;      // Metal uv.y=0 在顶部
    float3 rgb;
    float3 centerRGB = float3(0.0);
    int monoChoice = -1;
    if (u.mono > 0.5) {                       // 诊断模式：同一视点取 RGB
        float x1m = (X + Y * u.obliquity) * 3.0 + 1.0;
        float xlm = fmod(x1m + u.deviation + u.phase + u.autoSnap, u.lineNumber);
        if (xlm < 0.0) xlm += u.lineNumber;
        monoChoice = clamp(int(floor(xlm / u.lineNumber * u.views)), 0, int(u.views) - 1);
        if (u.invert > 0.5) monoChoice = int(u.views) - 1 - monoChoice;
    }
    for (int ch = 0; ch < 3; ++ch) {
        float x1 = (X + Y * u.obliquity) * 3.0 + float(ch);
        float xl = fmod(x1 + u.deviation + u.phase + u.autoSnap, u.lineNumber);
        if (xl < 0.0) xl += u.lineNumber;
        int choice = int(floor(xl / u.lineNumber * u.views));
        choice = clamp(choice, 0, int(u.views) - 1);
        if (u.invert > 0.5) choice = int(u.views) - 1 - choice;
        if (monoChoice >= 0) choice = monoChoice;
        // 少量渲染 + 一维内插：choice 槽位 → 最近两台真实相机 (a,b) 与权重 w
        int m = max(1, int(u.every));
        int lastCam = max(0, int(u.camCount) - 1);
        int a = choice / m;
        int b = min(a + 1, lastCam);
        if (a > lastCam) a = lastCam;
        float w = float(choice - a * m) / float(max(1, m));
        if (u.every > 1.5) { w = (w < 0.5) ? 0.0 : 1.0; }     // 降采样期禁用混合，零双影
        float4 ca = sampleCam(quilt, smp, a, pix, u);
        float4 cb = (b == a) ? ca : sampleCam(quilt, smp, b, pix, u);
        rgb[ch] = mix(ca[ch], cb[ch], w);         // R 取 ch0 的红, G 取 ch1 的绿, B 取 ch2 的蓝
        if (ch == 1) centerRGB = mix(ca, cb, w).rgb;   // G 子像素所在视点的完整色彩
    }
    if (u.chromaAA > 0.5 && u.mono < 0.5) {
        // 人眼对色度只有 1/4 的空间分辨率：亮度保留各子像素的严格定向，色度向中心视点收敛
        float lumaSub = dot(rgb, float3(0.299, 0.587, 0.114));
        float lumaCen = dot(centerRGB, float3(0.299, 0.587, 0.114));
        float lumaDiff = clamp(lumaSub - lumaCen, -0.10, 0.10);   // 限幅：抑制旋转时的边缘闪烁
        float3 aligned = clamp(centerRGB + lumaDiff, 0.0, 1.0);
        rgb = mix(rgb, aligned, 0.70);
    }
    return float4(rgb, 1.0);
}
"""

// MARK: - 几何

struct VIn { var pos: (Float, Float, Float); var nrm: (Float, Float, Float); var col: (Float, Float, Float) }

func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - a) / max(1e-6, b - a)))
    return t * t * (3 - 2 * t)
}

func sphere(radius: Float, seg: Int = 48, ring: Int = 32, color: (Float, Float, Float)) -> ([VIn], [UInt32]) {
    var v: [VIn] = [], idx: [UInt32] = []
    for r in 0...ring {
        let phi = Float(r) / Float(ring) * .pi
        for s in 0...seg {
            let th = Float(s) / Float(seg) * 2 * .pi
            let n = (sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
            v.append(VIn(pos: (n.0 * radius, n.1 * radius, n.2 * radius), nrm: n, col: color))
        }
    }
    let w = seg + 1
    for r in 0..<ring {
        for s in 0..<seg {
            let a = UInt32(r * w + s), b = UInt32((r + 1) * w + s)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        }
    }
    return (v, idx)
}

func box(size: Float, color: (Float, Float, Float)) -> ([VIn], [UInt32]) {
    let s = size / 2
    let faces: [((Float, Float, Float), [(Float, Float, Float)])] = [
        ((0, 0, 1), [(-s, -s, s), (s, -s, s), (s, s, s), (-s, s, s)]),
        ((0, 0, -1), [(s, -s, -s), (-s, -s, -s), (-s, s, -s), (s, s, -s)]),
        ((1, 0, 0), [(s, -s, s), (s, -s, -s), (s, s, -s), (s, s, s)]),
        ((-1, 0, 0), [(-s, -s, -s), (-s, -s, s), (-s, s, s), (-s, s, -s)]),
        ((0, 1, 0), [(-s, s, s), (s, s, s), (s, s, -s), (-s, s, -s)]),
        ((0, -1, 0), [(-s, -s, -s), (s, -s, -s), (s, -s, s), (-s, -s, s)])
    ]
    var v: [VIn] = [], idx: [UInt32] = []
    for (n, quad) in faces {
        let base = UInt32(v.count)
        for p in quad { v.append(VIn(pos: p, nrm: n, col: color)) }
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    }
    return (v, idx)
}

func torus(R: Float, r: Float, color: (Float, Float, Float)) -> ([VIn], [UInt32]) {
    var v: [VIn] = [], idx: [UInt32] = []
    let seg = 64, ring = 24
    for i in 0...seg {
        let u = Float(i) / Float(seg) * 2 * .pi
        for j in 0...ring {
            let w = Float(j) / Float(ring) * 2 * .pi
            let n = (cos(u) * cos(w), sin(w), sin(u) * cos(w))
            let p = ((R + r * cos(w)) * cos(u), r * sin(w), (R + r * cos(w)) * sin(u))
            v.append(VIn(pos: p, nrm: n, col: color))
        }
    }
    let w = ring + 1
    for i in 0..<seg {
        for j in 0..<ring {
            let a = UInt32(i * w + j), b = UInt32((i + 1) * w + j)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        }
    }
    return (v, idx)
}

func plane(extent: Float) -> ([VIn], [UInt32]) {
    let e = extent
    let v = [VIn(pos: (-e, 0, -e), nrm: (0, 1, 0), col: (1, 1, 1)),
             VIn(pos: (e, 0, -e), nrm: (0, 1, 0), col: (1, 1, 1)),
             VIn(pos: (e, 0, e), nrm: (0, 1, 0), col: (1, 1, 1)),
             VIn(pos: (-e, 0, e), nrm: (0, 1, 0), col: (1, 1, 1))]
    return (v, [0, 1, 2, 0, 2, 3])
}


// MARK: - GoZ

struct GoZResult { var name: String; var pos: [SIMD3<Float>]; var idx: [UInt32]; var col: [SIMD3<Float>] }

func parseGoZ(_ url: URL) -> GoZResult? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GoZResult? in
        let n = raw.count
        func u32(_ o: Int) -> UInt32? { (o >= 0 && o + 4 <= n) ? raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) : nil }
        func u64(_ o: Int) -> UInt64? { (o >= 0 && o + 8 <= n) ? raw.loadUnaligned(fromByteOffset: o, as: UInt64.self) : nil }

        var off = 36
        guard let lenRaw = u32(off) else { return nil }
        let nameLen = Int(lenRaw) - 16
        off += 12
        var name = "GoZ"
        if nameLen > 0 && off + nameLen <= n {
            let sub = raw[off..<off + nameLen]
            name = String(decoding: sub, as: UTF8.self)
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            off += nameLen
        }
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        var col: [SIMD3<Float>] = []
        while off + 4 <= n {
            guard let tag = u32(off) else { break }
            off += 4
            if tag == 0 { break }
            if tag == 0x1389 {
                guard let sz = u32(off), sz >= 8 else { break }
                off += Int(sz) - 4          // 已跳过 tag 的 4 字节
            } else if tag == 0x2711 {
                off += 4
                guard let cnt = u64(off) else { break }
                off += 8
                let c = Int(cnt)
                guard c > 0, off + c * 12 <= n else { break }
                pos.reserveCapacity(c)
                for i in 0..<c {
                    let b = off + i * 12
                    let x = raw.loadUnaligned(fromByteOffset: b, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self)
                    pos.append(SIMD3<Float>(x, y, z))        // 朝向由 flipY/flipZ 控制
                }
                off += c * 12
            } else if tag == 0x88B9 {                     // Polypaint: [B,G,R,flag]
                off += 4
                guard let cnt = u64(off) else { break }
                off += 8
                let c = Int(cnt)
                guard c > 0, off + c * 4 <= n else { break }
                col.reserveCapacity(c)
                for i in 0..<c {
                    let b = off + i * 4
                    let bb = Float(raw.loadUnaligned(fromByteOffset: b, as: UInt8.self)) / 255
                    let gg = Float(raw.loadUnaligned(fromByteOffset: b + 1, as: UInt8.self)) / 255
                    let rr = Float(raw.loadUnaligned(fromByteOffset: b + 2, as: UInt8.self)) / 255
                    col.append(SIMD3<Float>(rr, gg, bb))
                }
                off += c * 4
            } else if tag == 0x4E21 {
                off += 4
                guard let cnt = u64(off) else { break }
                off += 8
                let c = Int(cnt)
                guard c > 0, off + c * 16 <= n else { break }
                idx.reserveCapacity(c * 6)
                for i in 0..<c {
                    let b = off + i * 16
                    let v1 = raw.loadUnaligned(fromByteOffset: b, as: UInt32.self)
                    let v2 = raw.loadUnaligned(fromByteOffset: b + 4, as: UInt32.self)
                    let v3 = raw.loadUnaligned(fromByteOffset: b + 8, as: UInt32.self)
                    let v4 = raw.loadUnaligned(fromByteOffset: b + 12, as: UInt32.self)
                    if v4 == 0xFFFFFFFF {
                        idx += [v1, v2, v3]
                    } else if v4 == 0 {
                        idx += [0, v1, v2, 0, v2, v3]
                    } else {
                        idx += [v1, v2, v3, v1, v3, v4]
                    }
                }
                off += c * 16
            } else {
                guard let sz = u32(off), sz >= 8 else { break }
                off += Int(sz) - 4
            }
        }
        if pos.isEmpty || idx.isEmpty { return nil }
        return GoZResult(name: name, pos: pos, idx: idx, col: col)
    }
}

// MARK: - 渲染状态

struct U { var mvp = matrix_identity_float4x4; var nm = matrix_identity_float4x4
           var light = SIMD4<Float>(0.5, 0.8, 0.6, 0); var eye = SIMD4<Float>(0, 0, 0, 1)
           var tint = SIMD4<Float>(1, 1, 1, 0); var flags = SIMD4<Float>(0.5, 0, 0, 0) }

struct IU { var lineNumber: Float = 19.6349; var obliquity: Float = 0.103813
            var deviation: Float = 3.8456375; var views: Float = 40
            var cols: Float = 8; var rows: Float = 5; var mode: Float = 0; var invert: Float = 0
            var phase: Float = 0; var autoSnap: Float = 0
            var camCount: Float = 1; var every: Float = 1; var marker: Float = 1
            var mono: Float = 0; var chromaAA: Float = 1 }

struct MU { var rect: SIMD4<Float>; var color: SIMD4<Float>; var side: Float }

struct Mesh { var vbuf: MTLBuffer; var ibuf: MTLBuffer; var count: Int }

final class Renderer {
    let dev: MTLDevice, queue: MTLCommandQueue
    let viewPSO: MTLRenderPipelineState, quadPSO: MTLRenderPipelineState
    let solidPSO: MTLRenderPipelineState
    let markPSO: MTLRenderPipelineState
    let quilt: MTLTexture, depth: MTLTexture
    let depthState: MTLDepthStencilState
    let sampler: MTLSamplerState
    var meshes: [Mesh] = []

    // 场景参数
    var yaw: Float = 0, pitch: Float = 0, dist: Float = 1.55
    var panX: Float = 0, panY: Float = 0
    var modelScale: Float = 1.0
    var budgetPx: Float = 8.0          // 8 视点总视差(视点像素)
    var views: Int = 20
    var every: Int = 1                 // 每隔多少槽渲染一台真实相机（1 = 全渲染）
    var params = IU()
    var lens: Float = 85
    var fanScale: Float = 0.12                 // 兼容保留（IPD 关闭时不再参与计算）
    var targetDisparity: Float = 0.008          // ★ 屏幕视差主控：模型近表面占屏宽比例
    var phaseOffset: Float = 0                  // 用户相位偏移（子像素）
    var eyeOffsetDeg: Float = 0
    var focalOffset: Float = -0.06               // 仅保留作参考（相机不再使用）
    var volCM: Float = 2.2                       // 体积厚度（cm）
    var centerCM: Float = -0.35                  // 模型中心相对屏面（cm，负=入屏）
    var budgetPct: Float = 20.0                  // 内部安全上限（一般不再由用户调）
    var popCM: Float = 1.5                       // ★ 目标出屏距离（cm）
    var extreme = false                          // 极限模式：放宽单格角/扇形角上限
    var rlMul: Float = 1.8
    var focusSlice: Float = -0.25                  // 零视差面位置（模型半径的倍数）
    var rotQ = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))   // 模型姿态（trackball，无极点）
    var modelCenterY: Float = 0.5                       // 瑞利锁倍率（立体强度，1.0 = 6.5px/步）
    var useIPD = false
    var ipdMM: Float = 63
    var zoneDeg: Float = 40.0
    var viewDist: Float = 0.7
    var bands = false
    var needsQuilt = true

    init?() {
        params.invert = 1
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        dev = d; queue = q
        guard let lib = try? d.makeLibrary(source: shaderSrc, options: nil) else { return nil }

        let vd = MTLRenderPipelineDescriptor()
        vd.vertexFunction = lib.makeFunction(name: "vmain")
        vd.fragmentFunction = lib.makeFunction(name: "fmain")
        vd.colorAttachments[0].pixelFormat = .bgra8Unorm
        vd.depthAttachmentPixelFormat = .depth32Float
        guard let vp = try? d.makeRenderPipelineState(descriptor: vd) else { return nil }
        viewPSO = vp

        let qd = MTLRenderPipelineDescriptor()
        qd.vertexFunction = lib.makeFunction(name: "qmain")
        qd.fragmentFunction = lib.makeFunction(name: "qfrag")
        qd.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let qp = try? d.makeRenderPipelineState(descriptor: qd) else { return nil }
        quadPSO = qp

        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.makeFunction(name: "qmain")
        md.fragmentFunction = lib.makeFunction(name: "fmark")
        md.colorAttachments[0].pixelFormat = .bgra8Unorm
        md.depthAttachmentPixelFormat = .depth32Float      // 渲染通道带深度附件，必须声明
        guard let mp = try? d.makeRenderPipelineState(descriptor: md) else { return nil }
        markPSO = mp

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "qmain")
        sd.fragmentFunction = lib.makeFunction(name: "fsolid")
        sd.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let sp = try? d.makeRenderPipelineState(descriptor: sd) else { return nil }
        solidPSO = sp

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: VW * 8, height: VH * 5, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let qt = d.makeTexture(descriptor: td) else { return nil }
        quilt = qt
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: VW * 8, height: VH * 5, mipmapped: false)
        dd.usage = [.renderTarget]
        guard let dt = d.makeTexture(descriptor: dd) else { return nil }
        depth = dt

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true
        guard let ds = d.makeDepthStencilState(descriptor: dsd) else { return nil }
        depthState = ds

        let smp = MTLSamplerDescriptor()
        smp.minFilter = .linear; smp.magFilter = .linear
        smp.sAddressMode = .clampToEdge; smp.tAddressMode = .clampToEdge
        guard let s = d.makeSamplerState(descriptor: smp) else { return nil }
        sampler = s

        buildScene()
    }

    func add(_ geo: ([VIn], [UInt32])) {
        guard let vb = dev.makeBuffer(bytes: geo.0, length: MemoryLayout<VIn>.stride * geo.0.count, options: .storageModeShared),
              let ib = dev.makeBuffer(bytes: geo.1, length: MemoryLayout<UInt32>.stride * geo.1.count, options: .storageModeShared) else { return }
        meshes.append(Mesh(vbuf: vb, ibuf: ib, count: geo.1.count))
    }

    var lastGoZ: String = ""
    var flipY = false
    var axisMode: Int = 0                          // 0=Z-up 1=Y-up 2=Y-up 翻转
    var viewMode: Int = 0                          // 0=B 稳定移动  1=A 跳变突出
    var dbgLastN: Float = -1; var dbgShiftMin: Float = 0; var dbgShiftMax: Float = 0
    var dbgStepPx: Float = 0; var rayleighHit = false
    var effVolTot: Float = 0; var effCenTot: Float = 0; var stepVolDbg: Float = 0
    var flipZ = false
    var gozPos: [SIMD3<Float>] = []
    var gozIdx: [UInt32] = []
    var gozCol: [SIMD3<Float>] = []

    var gozName = ""
    var modelDepthNorm: Float = 0.8
    var modelRadii = SIMD3<Float>(0.25, 0.5, 0.25)   // 10–90% 分位椭球半径
    var fitDist: Float = 1.2

    func loadGoZ(_ url: URL) -> String? {
        guard let g = parseGoZ(url) else { return nil }
        gozName = g.name; gozPos = g.pos; gozIdx = g.idx; gozCol = g.col
        return rebuildGoZ()
    }

    @discardableResult
    func rebuildGoZ() -> String? {
        guard !gozPos.isEmpty else { return nil }
        // ZBrush 坐标是 Z-up（X右 / Y向内 / Z上），场景是 Y-up → 先做轴变换再叠加手动翻转
        let p: [SIMD3<Float>] = gozPos.map { q in
            // 轴约定：ZBrush 通常是 Z-up，但也有 Y-up 的资产
            var v: SIMD3<Float>
            switch axisMode {
            case 1:  v = SIMD3<Float>(q.x, q.y, -q.z)     // Y-up（正面朝 -Z）
            case 2:  v = SIMD3<Float>(q.x, -q.y, -q.z)    // Y-up 上下颠倒
            default: v = SIMD3<Float>(q.x, q.z, -q.y)     // Z-up（ZBrush 默认）
            }
            if flipY { v.y = -v.y }
            if flipZ { v.z = -v.z }
            return v
        }
        var lo = p[0], hi = p[0]
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let size = hi - lo
        let maxDim = max(size.x, max(size.y, size.z))
        modelDepthNorm = maxDim > 0 ? size.z / maxDim : 0.8
        let scl = maxDim > 0 ? 1.0 / maxDim : 1
        _ = (lo, hi)
        // 中位数质心：雕刻模型常一侧顶点密集，AABB 中心会让旋转枢轴明显偏心
        var mx = [Float](), my = [Float](), mz = [Float]()
        mx.reserveCapacity(p.count); my.reserveCapacity(p.count); mz.reserveCapacity(p.count)
        for q in p { mx.append(q.x); my.append(q.y); mz.append(q.z) }
        mx.sort(); my.sort(); mz.sort()
        let center = SIMD3<Float>(mx[mx.count/2], my[my.count/2], mz[mz.count/2])

        var nrm = [SIMD3<Float>](repeating: .zero, count: p.count)
        var i = 0
        while i + 2 < gozIdx.count {
            let a = p[Int(gozIdx[i])], b = p[Int(gozIdx[i+1])], c = p[Int(gozIdx[i+2])]
            let fn = cross(b - a, c - a)
            nrm[Int(gozIdx[i])] += fn; nrm[Int(gozIdx[i+1])] += fn; nrm[Int(gozIdx[i+2])] += fn
            i += 3
        }
        var verts: [VIn] = []
        verts.reserveCapacity(p.count)
        var minY: Float = .greatestFiniteMagnitude
        let hasCol = gozCol.count == p.count
        for k in p.indices {
            let q = (p[k] - center) * scl
            minY = min(minY, q.y)
            let nn = simd_length(nrm[k]) > 1e-9 ? normalize(nrm[k]) : SIMD3<Float>(0, 1, 0)
            let c = hasCol ? gozCol[k] : SIMD3<Float>(0.84, 0.80, 0.76)
            verts.append(VIn(pos: (q.x, q.y, q.z), nrm: (nn.x, nn.y, nn.z), col: (c.x, c.y, c.z)))
        }
        var maxY: Float = 0
        for k in verts.indices { verts[k].pos.1 -= minY; maxY = max(maxY, verts[k].pos.1) }
        modelCenterY = maxY * 0.5
        // 10–90% 分位数椭球半径：滤掉长矛/底座等离群顶点
        var ax = [Float](), ay = [Float](), az = [Float]()
        ax.reserveCapacity(verts.count); ay.reserveCapacity(verts.count); az.reserveCapacity(verts.count)
        for v in verts { ax.append(v.pos.0); ay.append(v.pos.1); az.append(v.pos.2) }
        ax.sort(); ay.sort(); az.sort()
        func qtl(_ a: [Float], _ f: Float) -> Float { a[min(a.count - 1, max(0, Int(Float(a.count - 1) * f)))] }
        modelRadii = SIMD3<Float>(max(0.01, (qtl(ax, 0.9) - qtl(ax, 0.1)) * 0.5),
                                  max(0.01, (qtl(ay, 0.9) - qtl(ay, 0.1)) * 0.5),
                                  max(0.01, (qtl(az, 0.9) - qtl(az, 0.1)) * 0.5))

        guard let vb = dev.makeBuffer(bytes: verts, length: MemoryLayout<VIn>.stride * verts.count, options: .storageModeShared),
              let ib = dev.makeBuffer(bytes: gozIdx, length: MemoryLayout<UInt32>.stride * gozIdx.count, options: .storageModeShared) else { return nil }
        meshes.removeAll()
        meshes.append(Mesh(vbuf: vb, ibuf: ib, count: gozIdx.count))
        lastGoZ = gozName
        let hfov = 2 * atan(18.0 / lens)
        let vfov = 2 * atan(tan(hfov / 2) / (Float(VW) / Float(VH)))
        dist = 1.0 / (0.65 * 2 * tan(vfov / 2))
        fitDist = dist
        panX = 0; panY = 0
        rotQ = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))   // 模型一律正对载入
        return "\(gozName)  \(p.count) 点 / \(gozIdx.count/3) 三角" + (hasCol ? " · 顶点色" : "")
    }

    /// 标定体：一个立方体 + 一个球。Z 正确时立方体看着就是"立方"；
    /// Z 偏大 → 深度轴被压扁（变扁盒）；Z 偏小 → 被拉长（变深盒）。
    @discardableResult
    func buildCalibration() -> String {
        meshes.removeAll()
        var cube = box(size: 0.60, color: (0.82, 0.82, 0.86))
        for i in cube.0.indices { cube.0[i].pos.1 += 0.30 }
        add(cube)
        var sp = sphere(radius: 0.15, color: (0.92, 0.60, 0.28))
        for i in sp.0.indices { sp.0[i].pos.0 += 0.45; sp.0[i].pos.1 += 0.15 }
        add(sp)
        // 指向观察者的长梁（0.08 × 0.08 × 1.2）：深度轴被拉伸/压扁时，长宽比会立刻变样
        var beam = box(size: 0.08, color: (0.35, 0.85, 0.55))
        for i in beam.0.indices {
            beam.0[i].pos.2 *= 15.0                     // 拉成 1.2 长
            beam.0[i].pos.1 += 0.30
            beam.0[i].pos.2 -= 0.60                     // 尾部穿过零视差面
        }
        add(beam)
        modelRadii = SIMD3<Float>(0.42, 0.30, 0.32)
        modelCenterY = 0.30
        // 3/4 视角：正对看立方体只会看到正方形，斜一点才能判断"深"
        rotQ = simd_normalize(simd_quatf(angle: 0.62, axis: SIMD3<Float>(0, 1, 0))
                              * simd_quatf(angle: 0.34, axis: SIMD3<Float>(1, 0, 0)))
        let hfov = 2 * atan(18.0 / lens)
        let vfov = 2 * atan(tan(hfov / 2) / (Float(VW) / Float(VH)))
        dist = 1.0 / (0.65 * 2 * tan(vfov / 2))
        fitDist = dist
        panX = 0; panY = 0
        lastGoZ = "calibration"
        return "标定体：立方体 0.6 + 球 + 前伸条"
    }

    func buildScene() {
        var ball = sphere(radius: 0.30, color: (0.92, 0.82, 0.72))
        for i in ball.0.indices { ball.0[i].pos.1 += 0.32 }
        add(ball)
        var cube = box(size: 0.34, color: (0.55, 0.72, 0.95))
        for i in cube.0.indices { cube.0[i].pos.0 += 0.42; cube.0[i].pos.1 += 0.17 }
        add(cube)
        var ring = torus(R: 0.26, r: 0.085, color: (0.95, 0.62, 0.35))
        for i in ring.0.indices { ring.0[i].pos.0 -= 0.42; ring.0[i].pos.1 += 0.30 }
        add(ring)
    }

    // 每视点相机: 平行相机组, 只做横向平移
    func cameraMatrix(view i: Int, n: Int) -> (simd_float4x4, simd_float4x4) {
        let aspect = Float(VW) / Float(VH)
        let hfov = 2 * atan(18.0 / lens)
        let vfov = 2 * atan(tan(hfov / 2) / aspect)
        let d = dist
        let Tan = tan(vfov / 2) * aspect                 // = 18/f

        // 基向量：所有视点共享（固定朝向，绝不逐视点重瞄）
        let toEye = normalize(SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)))
        let fwd = -toEye
        let right = normalize(cross(fwd, SIMD3<Float>(0, 1, 0)))
        let camUp = cross(right, fwd)

        let halfW_d = d * Tan                            // 模型中心处半宽

        // 各向同性半径（三轴中位数）→ 相机基线恒定，保证刚体旋转
        let sorted = [modelRadii.x, modelRadii.y, modelRadii.z].sorted()
        let rIso  = max(0.02, sorted[1] * modelScale)
        let rBoundRaw = max(rIso, max(modelRadii.x, max(modelRadii.y, modelRadii.z)) * modelScale)
        // 零视差面深度：focusSlice 以模型半径为尺度（-0.25 = 稍前于模型中心）
        let dZero = max(0.05, d + focusSlice * rBoundRaw)
        let halfW_zero = dZero * Tan
        // 视线投影半径 → 只用于安全上限
        let rProj = max(0.02, length(SIMD3(modelRadii.x * fwd.x,
                                           modelRadii.y * fwd.y,
                                           modelRadii.z * fwd.z)) * modelScale)
        let leverIso  = min(12.0, max(0.2, (d - rIso) / rIso))
        let leverProj = min(12.0, max(0.2, (d - rProj) / rProj))
        // 预算必须与视角无关：否则旋转时 dispCap/fanCap 逐帧变化 → 视差跳变闪烁
        let rBound = max(rIso, max(modelRadii.x, max(modelRadii.y, modelRadii.z)) * modelScale)
        let leverBound = min(12.0, max(0.2, (d - rBound) / rBound))

        let ipdDeg = 2 * atan(Double(ipdMM) / 1000.0 / (2 * Double(max(0.05, viewDist)))) * 180 / .pi
        let cells  = max(1.0, Double(n) * ipdDeg / Double(max(1.0, zoneDeg)))

        var off: Float = 0
        var centerShift: Float = 0
        if useIPD {
            // 真实基线模式：两端视点 = 双眼
            let angDeg = (0.5 - Float(i) / Float(max(1, n - 1))) * Float(ipdDeg) + eyeOffsetDeg
            off = d * tan(angDeg * .pi / 180)
        } else {
            let cellsF: Float = Float(cells)
            let n1F: Float = Float(max(1, n - 1))
            // === 正体视（Orthostereoscopic）精确还原 ===
            // 横向比例尺：模型中心半宽 halfW_d = d·Tan
            // 精确解：stepShift = κ · IPD / (D · cells · Tan)，与包围盒/半径估计完全无关
            let kappaF: Float = max(0.05, volCM / 2.2)          // 体积cm 2.2 → 1:1 还原
            let ipdRatio = (Double(ipdMM) * 0.001) / max(0.15, Double(viewDist))
            let subpxPerView = Float(19.6349) / Float(max(1, n))
            // 每视点 ≥3 子像素即摆脱子像素混叠 → 平滑解锁帕农大视差（取代 A/B 硬分支）
            let isoF: Float = smoothstepF(1.2, 3.8, subpxPerView)
            let smoothCap: Float = (extreme ? 0.045 : 0.028) * rlMul
            let popCap: Float = 0.115 * rlMul
            let activeCap: Float = smoothCap + (popCap - smoothCap) * isoF
            let fanCapV: Float = (0.42 + (0.85 - 0.42) * isoF) / max(1.0, n1F)
            let maxStepShift: Float = min(activeCap, fanCapV)
            let rawStepShift: Float = (kappaF / Float(cells)) * Float(ipdRatio) * (lens / 18.0)
            let stepShift: Float = maxStepShift * tanh(rawStepShift / max(1e-5, maxStepShift))
            rayleighHit = stepShift < rawStepShift * 0.97
            effVolTot = rawStepShift; stepVolDbg = stepShift
            // 零视差面自动锚定：出屏量不得超过模型表面视差的 1.15 倍（保证模型始终接触最锐面）
            let rRatio = min(0.35, max(0.08, rBound / max(0.1, d)))
            let modelSurfaceStep = stepShift * rRatio
            let Dcm = Double(viewDist) * 100.0
            let rawCen = Float(0.8873 * (Double(popCM) - 1.0) / max(15.0, Dcm))
            let smoothCenMax = modelSurfaceStep * 1.15
            let maxCenStep = smoothCenMax + (0.06 - smoothCenMax) * isoF
            let stepCen: Float = min(maxCenStep, max(-maxCenStep, Float(2.0 * Double(rawCen) / cells)))
            effCenTot = stepCen * Float(cells) / 2.0
            let unitIdx = Float(i) / Float(max(1, n - 1)) - 0.5
            off = unitIdx * n1F * stepShift * halfW_d                       // 差模：体积（已是屏幕量）
            // 共模：旋转/缩放恒定的中心深度（与 off 同乘 unitIdx，否则只是 2D 横移）
            // 符号：让 centerCM 为负（入屏）时零视差面朝前表面移动（实测标定：-0.35cm → 前 1/3）
            centerShift = -unitIdx * n1F * stepCen
            if i == 0 {
                let r = halfW_d / halfW_zero
                dbgShiftMin =  0.5 * n1F * stepShift * r
                dbgShiftMax = -0.5 * n1F * stepShift * r
                dbgStepPx = stepShift * 720.0
            }
        }
        if dbgLastN != Float(n) {
            dbgLastN = Float(n)
            FileHandle.standardError.write(String(format:
              "[DBG] N=%d M=%d cells=%.2f effVol=%.3f%% effCen=%.3f%% 每步=%.1fpx fan=[%.3f, %.3f]\n",
              n, viewMode, Float(cells), effVolTot*100, effCenTot*100, dbgStepPx, dbgShiftMin, dbgShiftMax).data(using:.utf8)!)
        }

        // ★ 符号：proj 第 3 列乘 z_view（前方为负），必须取负才能抵消相机横移
        var shift = -off / max(1e-6, halfW_d) - centerShift
        shift = max(-1.0, min(1.0, shift))      // 内容不出画      // 符号已正确，剪切只受显式上限约束
        let proj = perspective(fovy: vfov, aspect: aspect, near: 0.02, far: 60, shiftNDC: shift)

        // 平移在相机平面内做，保证拖到哪模型就走到哪（与俯仰角无关）
        let target = SIMD3<Float>(0, 0.45 * modelScale, 0) + right * panX + camUp * panY
        let eye = target + toEye * d + right * off
        let viewM = simd_float4x4(columns:
            (SIMD4<Float>(right.x, camUp.x, -fwd.x, 0),
             SIMD4<Float>(right.y, camUp.y, -fwd.y, 0),
             SIMD4<Float>(right.z, camUp.z, -fwd.z, 0),
             SIMD4<Float>(-dot(right, eye), -dot(camUp, eye), dot(fwd, eye), 1)))
        let modelM = modelMatrix()
        return (proj * viewM * modelM, viewM)
    }

    func modelMatrix() -> simd_float4x4 {
        let cy = modelCenterY
        let s = simd_float4x4(diagonal: SIMD4<Float>(modelScale, modelScale, modelScale, 1))
        let t1 = simd_float4x4(SIMD4<Float>(1,0,0,0), SIMD4<Float>(0,1,0,0),
                               SIMD4<Float>(0,0,1,0), SIMD4<Float>(0, cy, 0, 1))
        let t2 = simd_float4x4(SIMD4<Float>(1,0,0,0), SIMD4<Float>(0,1,0,0),
                               SIMD4<Float>(0,0,1,0), SIMD4<Float>(0, -cy, 0, 1))
        return t1 * simd_float4x4(rotQ) * t2 * s
    }

    func encodeScene(_ enc: MTLRenderCommandEncoder, view i: Int, n: Int) {
        var u = U()
        let (mvp, viewM) = cameraMatrix(view: i, n: n)
        u.mvp = mvp
        u.nm = simd_transpose(simd_inverse(viewM)) * modelMatrix()
        u.light = SIMD4<Float>(normalize(SIMD3<Float>(-0.45, 0.85, 0.55)), 0)
        u.eye = SIMD4<Float>((simd_inverse(viewM) * SIMD4<Float>(0, 0, 0, 1)).xyz, 1)
        u.flags = SIMD4<Float>(0.45, 0, 0, 0)
        for (_, m) in meshes.enumerated() {
            u.tint = SIMD4<Float>(1, 1, 1, 0)          // 地面已删除，不再有暗色网格材质
            enc.setVertexBuffer(m.vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<U>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint32,
                                      indexBuffer: m.ibuf, indexBufferOffset: 0)
        }
    }

    var requestRedraw: (() -> Void)?
    var dragUntil: CFTimeInterval = 0
    var isDragging: Bool { CACurrentMediaTime() < dragUntil }
    func noteInteraction() {
        dragUntil = CACurrentMediaTime() + 0.28
        needsQuilt = true
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.needsQuilt = true
            self?.requestRedraw?()
        }
    }

    func renderQuilt(_ cb: MTLCommandBuffer) {
        if !needsQuilt { return }
        needsQuilt = false
        // 拖动/缩放时每帧只渲 1/4 相机（5 台），停手后自动补一帧满视点
        let m = max(1, min(views, isDragging ? max(every, 2) : every))
        let camCount = (views + m - 1) / m
        let cols = camCount <= 8 ? camCount : 8
        let rows = (camCount + cols - 1) / cols
        params.views = Float(views); params.cols = Float(cols); params.rows = Float(rows)
        params.camCount = Float(camCount); params.every = Float(m)
        params.phase = phaseOffset
        // 屏幕中心 (720.5,1280.5) 的真实相位（G 通道），把最近的视点边界吸附到正中。
        // 厂商 deviation 是相对左上角标定的，中心相位并不是 0.5（实测 ≈0.64）。
        let cx: Float = 720.5, cy: Float = 1280.5
        let pRaw = (cx + cy * params.obliquity) * 3.0 + 1.0 + params.deviation
        let p0 = (pRaw - floor(pRaw / params.lineNumber) * params.lineNumber) / params.lineNumber
        let snapped = (p0 * Float(views)).rounded() / Float(views)
        params.autoSnap = (snapped - p0) * params.lineNumber

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = quilt
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if bands {
            enc.setRenderPipelineState(solidPSO)
            for i in 0..<views {
                let c = i % cols, r = i / cols
                enc.setViewport(MTLViewport(originX: Double(c * VW), originY: Double(r * VH),
                                            width: Double(VW), height: Double(VH), znear: 0, zfar: 1))
                var u = U()
                let h = Double(i) / Double(max(1, views))
                let rgb = hsv(h * 360, 0.95, 0.9)
                u.tint = SIMD4<Float>(rgb.0, rgb.1, rgb.2, 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            return
        }
        enc.setRenderPipelineState(viewPSO)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        for k in 0..<camCount {
            let c = k % cols, r = k / cols
            enc.setViewport(MTLViewport(originX: Double(c * VW), originY: Double(r * VH),
                                        width: Double(VW), height: Double(VH), znear: 0, zfar: 1))
            let slot = min(views - 1, k * m)
            encodeScene(enc, view: slot, n: views)   // 真实相机落在自己的槽位角度
            if params.marker > 0.5 {
                var mu = MU(rect: SIMD4<Float>(0.085, 0.062, 0.075, 0.0422),
                            color: SIMD4<Float>(0.35, 1.0, 0.45, 1),
                            side: (Float(slot) / Float(max(1, views - 1)) - 0.5) * 0.08)   // 加大视差：浮起距离更容易用指尖比对
                enc.setRenderPipelineState(markPSO)
                enc.setDepthStencilState(nil)
                enc.setFragmentBytes(&mu, length: MemoryLayout<MU>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.setRenderPipelineState(viewPSO)
                enc.setDepthStencilState(depthState)
            }
        }
        // 未渲染的空槽由交织 shader 在最近两台真实相机之间线性内插
        enc.endEncoding()
    }

    func drawQuad(_ cb: MTLCommandBuffer, target: MTLTexture?, drawable: CAMetalDrawable?, mode: Float) {
        let rp = MTLRenderPassDescriptor()
        if let d = drawable {
            rp.colorAttachments[0].texture = d.texture
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
        } else {
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var p = params
        p.mode = mode
        enc.setRenderPipelineState(quadPSO)
        enc.setFragmentBytes(&p, length: MemoryLayout<IU>.stride, index: 0)
        enc.setFragmentTexture(quilt, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

// MARK: - 数学

func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Float, Float, Float) {
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
    return (Float(r), Float(g), Float(b))
}

func perspective(fovy: Float, aspect: Float, near: Float, far: Float, shiftNDC: Float = 0) -> simd_float4x4 {
    let y = 1 / tan(fovy * 0.5), x = y / aspect, z = far / (near - far)
    return simd_float4x4(columns: (SIMD4<Float>(x, 0, 0, 0), SIMD4<Float>(0, y, 0, 0),
                                   SIMD4<Float>(shiftNDC, 0, z, -1), SIMD4<Float>(0, 0, z * near, 0)))
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye), s = normalize(cross(f, up)), u = cross(s, f)
    return simd_float4x4(columns: (SIMD4<Float>(s.x, u.x, -f.x, 0), SIMD4<Float>(s.y, u.y, -f.y, 0),
                                   SIMD4<Float>(s.z, u.z, -f.z, 0),
                                   SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
}

extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) } }

// MARK: - 视图

class MetalView: MTKView {
    var role = 0    // 0 = 面板输出, 1 = 控制窗预览
}

final class DropScrollView: NSScrollView {
    var onFile: ((URL) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: .fileURL),
              let u = URL(string: s) else { return false }
        onFile?(u)
        return true
    }
}

/// Blender 风格: 左键/中键拖 = 转视角, Shift+拖 = 平移, 滚轮/双指 = 推拉
final class NavView: MetalView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) { onPan?(e.deltaX, e.deltaY) } else { onOrbit?(e.deltaX, e.deltaY) }
    }
    override func otherMouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) { onPan?(e.deltaX, e.deltaY) } else { onOrbit?(e.deltaX, e.deltaY) }
    }
    override func rightMouseDragged(with e: NSEvent) { onPan?(e.deltaX, e.deltaY) }
    var onZoomPrecise: ((CGFloat, Bool) -> Void)?
    override func scrollWheel(with e: NSEvent) {
        onZoomPrecise?(e.scrollingDeltaY, e.hasPreciseScrollingDeltas)
    }
}

final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate {
    var renderer: Renderer!
    var panelScreen: NSScreen?
    var panelWin: NSWindow!
    var panelView: NavView!
    var ctrlWin: NSWindow!
    var preview: MetalView!
    var labels: [String: NSTextField] = [:]
    var sliders: [String: NSSlider] = [:]
    var fields: [String: NSTextField] = [:]
    var probe = false
    var frames = 0
    var autoclose: Double = 0
    var savePath: String?
    var captureTex: MTLTexture?
    var dumpPath: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let r = Renderer() else {
            let a = NSAlert(); a.messageText = "Metal 初始化失败"; a.runModal(); NSApp.terminate(nil); return
        }
        renderer = r

        panelScreen = NSScreen.screens.first { Int($0.frame.width) == PW && Int($0.frame.height) == PH }
        FileHandle.standardError.write("[ModelViewer] screens=\(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y))" })\n".data(using: .utf8)!)

        if let i = argv.firstIndex(of: "--goz"), i + 1 < argv.count {
            let u = URL(fileURLWithPath: argv[i + 1])
            if let info = renderer.loadGoZ(u) {
                FileHandle.standardError.write("[ModelViewer] GoZ OK: \(info)\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("[ModelViewer] GoZ 解析失败: \(u.path)\n".data(using: .utf8)!)
            }
        }
        if let i = argv.firstIndex(of: "--focal"), i + 1 < argv.count, let v = Float(argv[i + 1]) {
            renderer.focalOffset = v
        }
        if let i = argv.firstIndex(of: "--pitch"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.pitch = v * .pi / 180 }
        if argv.contains("--mono") { renderer.params.mono = 1 }
        if let i = argv.firstIndex(of: "--axis"), i + 1 < argv.count, let v = Int(argv[i + 1]) { renderer.axisMode = v; if !renderer.gozPos.isEmpty { _ = renderer.rebuildGoZ() } }
        if argv.contains("--cal") { _ = renderer.buildCalibration() }
        if let i = argv.firstIndex(of: "--zone"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.zoneDeg = v }
        if let i = argv.firstIndex(of: "--rot"), i + 1 < argv.count {
            let parts = argv[i + 1].split(separator: ",").compactMap { Float($0) }
            if parts.count == 2 {
                let axis: SIMD3<Float> = parts[0] < 0.5 ? SIMD3(1,0,0) : (parts[0] < 1.5 ? SIMD3(0,1,0) : SIMD3(0,0,1))
                renderer.rotQ = simd_quatf(angle: parts[1] * .pi / 180, axis: axis)
            }
        }
        if let i = argv.firstIndex(of: "--yaw"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.yaw = v * .pi / 180 }
        if let i = argv.firstIndex(of: "--views"), i + 1 < argv.count, let v = Int(argv[i + 1]) { renderer.views = v }
        if let i = argv.firstIndex(of: "--lens"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.lens = v }
        if let i = argv.firstIndex(of: "--disp"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.targetDisparity = v }
        if let i = argv.firstIndex(of: "--dist"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.dist = v }
        if let i = argv.firstIndex(of: "--every"), i + 1 < argv.count, let v = Int(argv[i + 1]) { renderer.every = max(1, v) }
        if let i = argv.firstIndex(of: "--vol"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.volCM = v }
        if let i = argv.firstIndex(of: "--center"), i + 1 < argv.count, let v = Float(argv[i + 1]) { renderer.centerCM = v }
        if let i = argv.firstIndex(of: "--k"), i + 1 < argv.count, let v = Float(argv[i + 1]) {
            renderer.fanScale = v
        }
        if dumpPath != nil { runDump(); return }
        guard let scr = panelScreen else {
            let a = NSAlert(); a.messageText = "找不到 1440×2560 面板"; a.runModal(); NSApp.terminate(nil); return
        }

        panelWin = PanelWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panelWin.setFrame(scr.frame, display: true)
        panelWin.level = .normal
        panelWin.ignoresMouseEvents = false
        panelWin.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        panelView = NavView(frame: NSRect(origin: .zero, size: scr.frame.size), device: renderer.dev)
        panelView.colorPixelFormat = .bgra8Unorm
        panelView.framebufferOnly = false
        panelView.isPaused = false
        panelView.enableSetNeedsDisplay = false
        panelView.preferredFramesPerSecond = 30
        panelView.delegate = self
        panelWin.contentView = panelView
        wireNav(panelView)
        panelWin.orderFrontRegardless()

        if probe { runProbe(); return }

        if autoclose > 0 {
            Timer.scheduledTimer(withTimeInterval: autoclose, repeats: false) { _ in NSApp.terminate(nil) }
        }
        if savePath != nil {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: PW, height: PH, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            captureTex = renderer.dev.makeTexture(descriptor: td)
        }
        buildStatusItem()
        buildControl()
        NSApp.activate(ignoringOtherApps: true)
        ctrlWin.makeKeyAndOrderFront(nil)
        panelWin.orderFrontRegardless()
        FileHandle.standardError.write("[ModelViewer] panel window \(panelWin.frame) visible=\(panelWin.isVisible)\n".data(using: .utf8)!)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            if self.frames == 0 && !self.probe {
                FileHandle.standardError.write("[ModelViewer] 2s 内没有绘制任何帧 -> 自动退出\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }
        if argv.contains("--diag") {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                let occ = self.panelWin.occlusionState.contains(.visible) ? "visible" : "occluded"
                FileHandle.standardError.write("[ModelViewer] diag frames=\(self.frames) windowState=\(occ) drawable=\(self.panelView.currentDrawable != nil)\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }
    }

    // 统一入口: 面板走交织, 控制窗走中心视点预览
    var pending = 2
    func markDirty() {
        renderer.needsQuilt = true
        pending = 2
    }

    func draw(in view: MTKView) {
        guard let mv = view as? MetalView else { return }
        guard pending > 0 else { return }          // 画面没变就完全不动
        pending -= 1
        frames += 1
        guard let cb = renderer.queue.makeCommandBuffer() else { return }
        if probe {
            if let d = view.currentDrawable {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = d.texture
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.85, green: 0.1, blue: 0.75, alpha: 1)
                if let enc = cb.makeRenderCommandEncoder(descriptor: rp) { enc.endEncoding() }
                cb.present(d)
            }
            cb.commit()
            return
        }
        renderer.renderQuilt(cb)
        if let d = view.currentDrawable {
            let mode: Float = mv.role == 0 ? (quiltMode ? 2 : 0) : 1
            renderer.drawQuad(cb, target: nil, drawable: d, mode: mode)
            if let path = savePath, mv.role == 0, let cap = captureTex {
                if let blit = cb.makeBlitCommandEncoder() {
                    blit.copy(from: d.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: PW, height: PH, depth: 1),
                              to: cap, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
                cb.addCompletedHandler { _ in
                    var bytes = [UInt8](repeating: 0, count: PW * PH * 4)
                    cap.getBytes(&bytes, bytesPerRow: PW * 4, from: MTLRegionMake2D(0, 0, PW, PH), mipmapLevel: 0)
                    for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
                    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                    let prov = CGDataProvider(data: Data(bytes) as CFData)!
                    let img = CGImage(width: PW, height: PH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: PW * 4,
                                      space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write("[ModelViewer] saved drawable -> \(path)\n".data(using: .utf8)!)
                    NSApp.terminate(nil)
                }
                self.savePath = nil
            }
            cb.present(d)
        }
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    var statusItem: NSStatusItem?

    func buildStatusItem() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.title = "C1"
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "退出 ModelViewer", action: #selector(quitAll), keyEquivalent: "q"))
        it.menu = m
        statusItem = it
    }

    @objc func quitAll() { NSApp.terminate(nil) }

    func fmtVal(_ key: String, _ v: Double) -> String {
        if key == "视点数" { return String(format: "%.0f", v) }
        if key == "视点偏移" { return String(format: "%.1f", v) }
        if key == "线数" { return String(format: "%.4f", v) }
        if key == "倾斜" { return String(format: "%.6f", v) }
        return String(format: "%.3f", v)
    }

    @objc func valueEdited(_ f: NSTextField) {
        guard let key = f.identifier?.rawValue, let sl = sliders[key] else { return }
        let txt = f.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(txt) else { f.stringValue = fmtVal(key, sl.doubleValue); return }
        let clamped = min(sl.maxValue, max(sl.minValue, v))
        sl.doubleValue = clamped
        apply(key, clamped)
        f.stringValue = fmtVal(key, clamped)
    }
    var gozStatus: NSTextField?
    var autoWatch = true
    var dragInvert = true          // 拖动反向开关（面板/预览共用）
    var lastGoZStamp = ""

    func buildControl() {
        let W = 430.0, H = 900.0
        let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: W, height: H),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "C1 光场预览 · ModelViewer"
        win.minSize = NSSize(width: 380, height: 480)
        ctrlWin = win

        let scroll = DropScrollView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        scroll.onFile = { [weak self] u in
            self?.autoWatch = false
            self?.applyGoZ(u)
        }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        win.contentView = scroll

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        func header(_ t: String) {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            stack.addArrangedSubview(l)
            stack.setCustomSpacing(3, after: l)
        }
        func sliderRow(_ key: String, _ lo: Double, _ hi: Double, _ val: Double) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let l = NSTextField(labelWithString: key)
            l.font = .systemFont(ofSize: 11)
            l.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let sl = NSSlider(value: val, minValue: lo, maxValue: hi, target: self, action: #selector(sliderChanged(_:)))
            sl.identifier = NSUserInterfaceItemIdentifier(key)
            sl.widthAnchor.constraint(equalToConstant: 210).isActive = true
            let f = NSTextField(string: fmtVal(key, val))
            f.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            f.alignment = .right
            f.isBordered = true
            f.bezelStyle = .roundedBezel
            f.controlSize = .small
            f.target = self
            f.action = #selector(valueEdited(_:))
            f.identifier = NSUserInterfaceItemIdentifier(key)
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let v = NSTextField(labelWithString: "")
            v.font = .systemFont(ofSize: 9)
            v.textColor = .secondaryLabelColor
            v.widthAnchor.constraint(equalToConstant: 72).isActive = true
            row.addArrangedSubview(l); row.addArrangedSubview(sl); row.addArrangedSubview(f); row.addArrangedSubview(v)
            labels[key] = v; sliders[key] = sl; fields[key] = f
            stack.addArrangedSubview(row)
        }
        func checkRow(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
            b.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(b)
            return b
        }

        // 预览
        let pv = NavView(frame: NSRect(x: 0, y: 0, width: 180, height: 320), device: renderer.dev)
        pv.colorPixelFormat = .bgra8Unorm
        pv.delegate = self
        pv.role = 1
        pv.isPaused = false
        pv.enableSetNeedsDisplay = false
        pv.preferredFramesPerSecond = 20
        pv.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pv.heightAnchor.constraint(equalToConstant: 320).isActive = true
        wireNav(pv)
        preview = pv
        let pvRow = NSStackView(views: [pv])
        pvRow.alignment = .centerY
        stack.addArrangedSubview(pvRow)

        header("相机")
        sliderRow("视距m", 0.05, 10.0, Double(renderer.dist))

        let camInfo = NSTextField(labelWithString: "")
        camInfo.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        camInfo.textColor = .secondaryLabelColor
        camInfo.identifier = NSUserInterfaceItemIdentifier("camInfo")
        stack.addArrangedSubview(camInfo)

        header("光栅")
        header("深度")
        sliderRow("立体强度", 0.3, 4.0, Double(renderer.rlMul))
        sliderRow("体积cm", 0.2, 6.0, Double(renderer.volCM))
        sliderRow("出屏cm", 0.0, 16.0, Double(renderer.popCM))
        sliderRow("扇区Z°", 5.0, 120.0, Double(renderer.zoneDeg))
        sliderRow("观看距离", 0.15, 2.0, Double(renderer.viewDist))
        header("相机")
        sliderRow("视点数", 2, 40, Double(renderer.views))
        sliderRow("焦距mm", 6, 600, Double(renderer.lens))
        header("交织")
        sliderRow("实渲间隔", 1, 8, Double(renderer.every))
        sliderRow("相位偏移", -9.8, 9.8, Double(renderer.phaseOffset))
        sliderRow("线数", 18.0, 22.0, Double(renderer.params.lineNumber))
        sliderRow("倾斜", 0.05, 0.17, Double(renderer.params.obliquity))
        sliderRow("相位", 0.0, 40.0, Double(renderer.params.deviation))

        header("显示")
        let ipdBtn = checkRow("IPD 基线(两端=双眼)", #selector(toggleIPD(_:)))
        ipdBtn.state = renderer.useIPD ? .on : .off
        let inv = checkRow("反转视点序", #selector(toggleInvert(_:)))
        inv.state = .on
        let mk = checkRow("立体标记(左上角)", #selector(toggleMarker(_:)))
        mk.state = .on
        let ex = checkRow("极限模式(放宽上限)", #selector(toggleExtreme(_:)))
        _ = ex
        let dInv = checkRow("拖动反向", #selector(toggleDragInvert(_:)))
        dInv.state = .on
        let q = checkRow("看图集(排查)", #selector(toggleQuilt(_:)))
        let bd = checkRow("视点色带(排查)", #selector(toggleBands(_:)))
        _ = q; _ = bd

        header("ZBrush GoZ")
        let st = NSTextField(labelWithString: "未载入 · 监听 ZBrush GoZ 导出目录")
        st.font = .systemFont(ofSize: 10)
        st.textColor = .secondaryLabelColor
        st.lineBreakMode = .byTruncatingMiddle
        st.widthAnchor.constraint(equalToConstant: 380).isActive = true
        gozStatus = st
        stack.addArrangedSubview(st)

        let flipRow = NSStackView()
        flipRow.orientation = .horizontal
        flipRow.spacing = 10
        let fy = NSButton(checkboxWithTitle: "上下翻转", target: self, action: #selector(toggleFlipY(_:)))
        let fz = NSButton(checkboxWithTitle: "前后翻转", target: self, action: #selector(toggleFlipZ(_:)))
        let mb = NSButton(checkboxWithTitle: "单视点(诊断)", target: self, action: #selector(toggleMono(_:)))
        mb.font = .systemFont(ofSize: 11)
        fy.font = .systemFont(ofSize: 11); fz.font = .systemFont(ofSize: 11)
        flipRow.addArrangedSubview(fy); flipRow.addArrangedSubview(fz); flipRow.addArrangedSubview(mb)
        stack.addArrangedSubview(flipRow)

        let dirLabel = NSTextField(labelWithString: "监控: " + gozDirs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        dirLabel.font = .systemFont(ofSize: 9)
        dirLabel.textColor = .tertiaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(dirLabel)

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        let b1 = NSButton(title: "载入最新", target: self, action: #selector(loadLatestGoZ))
        let b2 = NSButton(title: "选文件…", target: self, action: #selector(pickGoZ))
        let b4 = NSButton(title: "监控文件夹…", target: self, action: #selector(pickWatchDir))
        let bcal = NSButton(title: "标定体", target: self, action: #selector(loadCalibration))
        let bax = NSButton(title: "轴向 Z/Y/Y′", target: self, action: #selector(cycleAxis))
        let bmode = NSButton(title: "模式 B→A", target: self, action: #selector(switchMode))
        let b3 = NSButton(checkboxWithTitle: "自动监听", target: self, action: #selector(toggleWatch(_:)))
        b3.state = .on
        btnRow.addArrangedSubview(b1); btnRow.addArrangedSubview(b2); btnRow.addArrangedSubview(b4); btnRow.addArrangedSubview(bcal); btnRow.addArrangedSubview(bax); btnRow.addArrangedSubview(bmode); btnRow.addArrangedSubview(b3)
        stack.addArrangedSubview(btnRow)

        let dropHint = NSTextField(labelWithString: "把 .GoZ 文件直接拖进这个窗口也能载入")
        dropHint.font = .systemFont(ofSize: 9)
        dropHint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(dropHint)

        header("操作")
        let foot = NSStackView()
        foot.orientation = .horizontal
        foot.spacing = 8
        foot.addArrangedSubview(NSButton(title: "复位视角", target: self, action: #selector(resetView)))
        foot.addArrangedSubview(NSButton(title: "恢复内置模型", target: self, action: #selector(restoreScene)))
        foot.addArrangedSubview(NSButton(title: "退出", target: self, action: #selector(quitAll)))
        stack.addArrangedSubview(foot)

        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: W, height: max(stack.fittingSize.height, H - 4))
        scroll.documentView = stack

        let def = UserDefaults.standard
        if let saved = def.array(forKey: "gozDirs") as? [String], !saved.isEmpty {
            gozDirs = saved.filter { FileManager.default.fileExists(atPath: $0) }
            let shared = "/Users/Shared/Pixologic/GoZProjects/Default"
            if !gozDirs.contains(shared), FileManager.default.fileExists(atPath: shared) {
                gozDirs.append(shared)          // ZBrush 的实际导出目录
            }
        }
        if gozDirs.isEmpty {
            gozDirs = ["~/Desktop", "~/Downloads", "~/Documents",
                       "~/Documents/ZBrush/GoZProjects/Default",
                       "/Users/Shared/Pixologic/GoZProjects/Default"].map { NSString(string: $0).expandingTildeInPath }
        }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.pollGoZ() }
    }

    var gozDirs: [String] = []

    func newestGoZ() -> (URL, String)? {
        var best: (URL, Date, Int)?
        let fm = FileManager.default
        for d in gozDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for it in items where it.lowercased().hasSuffix(".goz") {
                let u = URL(fileURLWithPath: d).appendingPathComponent(it)
                let st = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
                let m = (st[.modificationDate] as? Date) ?? Date.distantPast
                let sz = (st[.size] as? Int) ?? 0
                if best == nil || m > best!.1 { best = (u, m, sz) }
            }
        }
        guard let b = best else { return nil }
        return (b.0, "\(b.0.lastPathComponent)|\(b.1.timeIntervalSince1970)|\(b.2)")
    }

    var lastSeenSize: Int = -1
    func pollGoZ() {
        guard autoWatch, !loading else { return }
        guard let (u, stamp) = newestGoZ(), stamp != lastGoZStamp else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1
        if size != lastSeenSize {          // 文件还在增长 → 等下一轮
            lastSeenSize = size
            return
        }
        lastGoZStamp = stamp
        applyGoZ(u)
    }

    var loading = false
    func applyGoZ(_ u: URL) {
        guard !loading else { return }
        loading = true
        gozStatus?.stringValue = "载入中… " + u.lastPathComponent
        gozStatus?.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let info = self.renderer.loadGoZ(u)          // 解析 + 法线 + 分位数在后台线程
            DispatchQueue.main.async {
                self.loading = false
                if let info = info {
                    FileHandle.standardError.write("[ModelViewer] GoZ 已载入: \(info) <- \(u.lastPathComponent)\n".data(using: .utf8)!)
                    self.gozStatus?.stringValue = "已载入 " + info
                    self.gozStatus?.textColor = .labelColor
                    self.markDirty()
                } else {
                    self.gozStatus?.stringValue = "解析失败: " + u.lastPathComponent
                    self.gozStatus?.textColor = .systemRed
                }
            }
        }
    }

    @objc func switchMode() {
        // A：N=4 跳变突出（每视点 4.9 子像素，单步可到帕农极限）
        // B：N=20 稳定移动（每步受透镜周期约束）
        renderer.viewMode = renderer.viewMode == 0 ? 1 : 0
        if renderer.viewMode == 1 {
            renderer.views = 4; renderer.volCM = 4.0; renderer.popCM = 8.0   // 强出屏预设
        } else {
            renderer.views = 20; renderer.volCM = 2.2; renderer.popCM = 1.5  // 稳定预设
        }
        gozStatus?.stringValue = renderer.viewMode == 1
            ? "模式 A：N=4 跳变突出（强出屏）"
            : "模式 B：N=20 稳定移动（弱但稳）"
        gozStatus?.textColor = .labelColor
        markDirty()
    }

    @objc func cycleAxis() {
        renderer.axisMode = (renderer.axisMode + 1) % 3
        _ = renderer.rebuildGoZ()
        gozStatus?.stringValue = ["轴向 Z-up", "轴向 Y-up", "轴向 Y-up 翻转"][renderer.axisMode]
        markDirty()
    }

    @objc func loadCalibration() {
        _ = renderer.buildCalibration()
        gozStatus?.stringValue = "标定体：立方体 + 球（判断 Z 用）"
        gozStatus?.textColor = .labelColor
        markDirty(); resetView()
    }

    @objc func loadLatestGoZ() {
        if let (u, stamp) = newestGoZ() { lastGoZStamp = stamp; applyGoZ(u) }
        else { gozStatus?.stringValue = "没找到 .GoZ（先到 ZBrush 里 GoZ 导出一次）" }
    }

    @objc func pickGoZ() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["GoZ", "goz"]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { autoWatch = false; applyGoZ(u) }
    }

    @objc func toggleWatch(_ b: NSButton) { autoWatch = b.state == .on }

    @objc func pickWatchDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            gozDirs = panel.urls.map { $0.path }
            UserDefaults.standard.set(gozDirs, forKey: "gozDirs")
            autoWatch = true
            gozStatus?.stringValue = "监控: " + gozDirs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            gozStatus?.textColor = .secondaryLabelColor
        }
    }
    @objc func toggleFlipY(_ b: NSButton) { renderer.flipY = b.state == .on; _ = renderer.rebuildGoZ() }
    @objc func toggleFlipZ(_ b: NSButton) { renderer.flipZ = b.state == .on; _ = renderer.rebuildGoZ() }
    @objc func toggleMono(_ b: NSButton) { renderer.params.mono = b.state == .on ? 1 : 0; markDirty() }

    @objc func restoreScene() {
        renderer.meshes.removeAll()
        renderer.buildScene()
        gozStatus?.stringValue = "已恢复内置模型"
    }


    var quiltMode = false
    @objc func toggleIPD(_ b: NSButton) { renderer.useIPD = b.state == .on; markDirty(); updateCamInfo() }
    @objc func toggleInvert(_ b: NSButton) { renderer.params.invert = b.state == .on ? 1 : 0; markDirty() }
    @objc func toggleQuilt(_ b: NSButton) { quiltMode = b.state == .on; markDirty() }
    @objc func toggleDragInvert(_ b: NSButton) { dragInvert = b.state == .on }
    @objc func toggleExtreme(_ b: NSButton) { renderer.extreme = b.state == .on; markDirty(); updateCamInfo() }
    @objc func toggleMarker(_ b: NSButton) { renderer.params.marker = b.state == .on ? 1 : 0; markDirty() }
    @objc func toggleBands(_ b: NSButton) { renderer.bands = b.state == .on; markDirty() }

    @objc func resetView() {
        renderer.yaw = 0; renderer.pitch = 0; renderer.dist = renderer.fitDist
        renderer.rotQ = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        renderer.modelScale = 1; renderer.panX = 0; renderer.panY = 0
        markDirty()
    }

    func apply(_ k: String, _ val: Double) {
        switch k {
        case "视距m", "视距": renderer.dist = Float(val)
        case "模型缩放": renderer.modelScale = Float(val)
        case "视差%": renderer.targetDisparity = Float(max(0.001, val / 100.0))
        case "相位偏移": renderer.phaseOffset = Float(val)
        case "视点数": renderer.views = Int(val.rounded())
        case "实渲间隔": renderer.every = max(1, Int(val.rounded()))
        case "视点偏移": renderer.eyeOffsetDeg = Float(val)
        case "焦平面": renderer.focalOffset = Float(val)
        case "体积cm": renderer.volCM = Float(val)
        case "中心cm": renderer.centerCM = Float(val)
        case "预算%": renderer.budgetPct = Float(val)
        case "出屏cm": renderer.popCM = Float(val)
        case "立体强度": renderer.rlMul = Float(val); markDirty()
        case "观看距离": renderer.viewDist = Float(val)
        case "扇区Z°": renderer.zoneDeg = Float(val)
        case "透视比":
            let dz = Double(renderer.modelDepthNorm * renderer.modelScale)
            let r = max(1.02, val)
            let D = dz * (r + 1) / (2 * (r - 1))      // 由透视比反解距离
            renderer.dist = Float(max(0.03, min(10.0, D)))
            renderer.lens = Float(max(6, min(600, 50.0 * D / 1.2)))   // 同步焦距保持构图
            sliders["视距m"]?.doubleValue = Double(renderer.dist)
            fields["视距m"]?.stringValue = fmtVal("视距m", Double(renderer.dist))
            sliders["焦距mm"]?.doubleValue = Double(renderer.lens)
            fields["焦距mm"]?.stringValue = fmtVal("焦距mm", Double(renderer.lens))
        case "焦距mm": renderer.lens = Float(max(6, min(600, Float(val))))
        case "线数": renderer.params.lineNumber = Float(val)
        case "倾斜": renderer.params.obliquity = Float(val)
        case "相位": renderer.params.deviation = Float(val)
        default: break
        }
        markDirty()
        updateCamInfo()
        if k == "视点数" {
            labels[k]?.stringValue = String(format: "%.2f子/视点", 19.6349 / max(1, val))
        } else {
            labels[k]?.stringValue = ""
        }
    }

    func wireNav(_ v: NavView) {
        renderer.requestRedraw = { [weak self] in self?.markDirty() }
        v.onOrbit = { [weak self] dx, dy in
            guard let r = self?.renderer else { return }
            // trackball：绕屏幕平面的轴旋转模型，无极点、无翻转、无角度上限
            let sgn: Float = (self?.dragInvert ?? true) ? -1 : 1
            let dxf = Float(dx), dyf = Float(dy)
            let len = sqrt(dxf * dxf + dyf * dyf)
            if len > 0.0001 {
                let axis = simd_normalize(SIMD3<Float>(dyf * sgn, dxf * sgn, 0))
                let q = simd_quatf(angle: len * 0.008, axis: axis)
                r.rotQ = simd_normalize(q * r.rotQ)
            }
            r.noteInteraction()
            self?.markDirty()
        }
        v.onPan = { [weak self] dx, dy in
            guard let r = self?.renderer else { return }
            let k = 0.0050 * r.dist
            r.panX -= Float(dx) * k          // 抓住物体：拖动方向与画面移动同向
            r.panY += Float(dy) * k
            r.noteInteraction()
            self?.markDirty()
        }
        v.onZoomPrecise = { [weak self] dy, precise in
            guard let r = self?.renderer else { return }
            let k: Float = precise ? 0.010 : 0.040
            let step = max(-25.0, min(25.0, Float(dy)))          // 单次事件限幅，防止猛跳
            r.dist = min(10.0, max(0.03, r.dist * exp(-step * k)))
            r.noteInteraction()
            self?.markDirty()
        }
    }

    func updateCamInfo() {
        guard let l = ctrlWin?.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first?.documentView?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "camInfo" }) else { return }
        let dz = Double(renderer.modelDepthNorm) * Double(renderer.modelScale)
        let d = Double(renderer.dist)
        let ratio = d > dz / 2 ? (d + dz / 2) / (d - dz / 2) : 9.99
        let vd = Double(renderer.viewDist)
        let sorted = [renderer.modelRadii.x, renderer.modelRadii.y, renderer.modelRadii.z].sorted()
        let rIso = Double(max(0.02, sorted[1] * renderer.modelScale))
        let leverIso = min(12.0, max(0.2, (d - rIso) / rIso))
        let Dcm = vd * 100.0
        let effVol = min(0.8873 * (0.5 * Double(renderer.volCM)) / max(10.0, Dcm + 0.5 * Double(renderer.volCM)), 0.035)
        let effCen = 0.8873 * Double(renderer.centerCM) / max(10.0, Dcm - Double(renderer.centerCM))
        let z0 = d / (1.0 + (effVol > 0 ? -effCen / (effVol * leverIso) : 0))   // 零视差面
        let sharpFrac = min(1.0, max(0.0, (z0 - (d - rIso)) / (2 * rIso)))
        let fx: Float = -sin(renderer.yaw) * cos(renderer.pitch)
        let fy: Float = -sin(renderer.pitch)
        let fz: Float = -cos(renderer.yaw) * cos(renderer.pitch)
        let rr: SIMD3<Float> = renderer.modelRadii * renderer.modelScale
        let rx: Float = rr.x * fx, ry: Float = rr.y * fy, rz: Float = rr.z * fz
        let rProj: Float = sqrt(rx * rx + ry * ry + rz * rz)
        let rModel: Double = max(0.02, Double(rProj))
        let lever = min(10.0, max(0.2, (d - rModel) / rModel))
        let eyeDegNow = 2 * atan(Double(renderer.ipdMM) / 1000.0 / (2 * max(0.05, vd))) * 180 / .pi
        let cellsNow = max(1.0, Double(renderer.views) * eyeDegNow / Double(max(1.0, renderer.zoneDeg)))
        let zoomComp = min(3.0, max(0.3, Double(renderer.fitDist) / max(0.03, d)))
        let disp = Double(renderer.targetDisparity) * 100
        let dispEff = min(5.0, disp * zoomComp)
        let rSurf = max(0.05, rModel)
        let frontFactor = max(0.1, (rSurf + Double(renderer.focalOffset)) / rSurf)
        let dispFront = dispEff * frontFactor
        let zN = max(0.02, d - dz / 2), zF = d + dz / 2
        var dn = 1 / zN - 1 / z0, df = 1 / zF - 1 / z0
        if renderer.params.invert > 0.5 { dn = -dn; df = -df }
        let state: String
        if dn > 0 && df > 0 { state = "全出屏" }
        else if dn < 0 && df < 0 { state = "全入屏" }
        else { state = "跨屏面" }
        let fanDeg = renderer.useIPD
            ? 2 * atan(Double(renderer.ipdMM) / 1000.0 / (2 * vd)) * 180 / .pi
            : 40.0 * Double(renderer.fanScale)
        let vw = Double(renderer.zoneDeg) / Double(max(1, renderer.views))            // 一个视点的角宽
        let eyeDeg = 2 * atan(Double(renderer.ipdMM) / 1000.0 / (2 * vd)) * 180 / .pi   // 双眼分离角
        let span = eyeDeg / max(0.001, vw)
        let tanCap: Double = 0.12278                       // tan(7°)：单格相机角上限
        let capPct: Double = tanCap * cellsNow / (2.0 * lever * (18.0 / Double(renderer.lens))) * 100.0
        let effTot = effVol + abs(effCen)
        let dispMM = effTot * 71.0
        let popCM = vd * 1000.0 * dispMM / (Double(renderer.ipdMM) + dispMM) / 10.0
        let depthCM = 2.254 * vd * effTot      // ΔZ_total ≈ 2.254·D_view·effDisp（cm，W=7.1cm/IPD=6.3cm）
        l.stringValue = String(format: "透视比 %.2f · D %.2fm · f %.0fmm · 视点宽 %.2f° 跨格 %.2f · 杠杆 %.2f · 零视差面 %.2fm · %@ · 出屏 %.1fcm 体积 %.1fcm → 视差 %.2f%%%.2f%% · 最锐面 %.0f%%",
                              ratio, d, Double(renderer.lens), vw, cellsNow, leverIso, z0, state as NSString,
                              Double(renderer.popCM), Double(renderer.volCM), effCen * 100, effVol * 100, sharpFrac * 100)
        // 彩边：每个视点步长的屏幕视差 → 像素 / 透镜周期
        let stepNDC = 2.0 * effVol / max(0.001, cellsNow)
        let fringePx = stepNDC * 720.0
        let fringePer = fringePx / 6.545
        l.stringValue += String(format: " · 每步 %.1fpx(%.1f周期) 彩边 %.0fpx", renderer.dbgStepPx, renderer.dbgStepPx / 6.545, fringePx)
        if renderer.rayleighHit { l.stringValue += " · 瑞利锁生效" }
        // 标记的理论浮起距离（若 Z = 40/60/90）——用指尖比对即可反推真实 Z
        let mkS: Double = 0.08 * 35.5          // 标记每视点位移 = 0.08 NDC × 35.5 mm
        let ipdDegNow = 2.0 * atan(Double(renderer.ipdMM) / 1000.0 / (2.0 * vd)) * 180.0 / .pi
        func mz(_ Z: Double) -> Double {
            let c = max(1.0, Double(renderer.views) * ipdDegNow / Z)
            let pm = c * mkS
            return vd * 1000.0 * pm / (Double(renderer.ipdMM) + pm)
        }
        l.stringValue += String(format: " · 标记浮起 Z40/60/90 = %.1f/%.1f/%.1f mm", mz(40), mz(60), mz(90))
        let nRec = max(2, Int((Double(renderer.zoneDeg) / eyeDegNow).rounded()))
        // 甜点覆盖：相邻视点的眼区间距 vs 瞳距。间距 ≥ 瞳距 → 中间有"丢立体"的空档
        let cellDeg = Double(renderer.zoneDeg) / Double(max(1, renderer.views))
        let spacingMM = 2.0 * vd * tan(cellDeg * .pi / 360.0) * 1000.0
        let coverOK = spacingMM <= Double(renderer.ipdMM)
        if capPct < disp { l.stringValue += String(format: " · 单格角上限 → 视差被压到 %.2f%%", capPct) }
        // 谁在限制视差：预算 / 单格角 / 扇形角
        let tanCell: Double = renderer.extreme ? 0.2679 : 0.12278
        let tanFan: Double = renderer.extreme ? 1.0000 : 0.7002
        let leverP = min(12.0, max(0.2, (d - rModel) / rModel))
        let capCell = tanCell * cellsNow / (2 * leverP * (18.0 / Double(renderer.lens)))
        let capFan = tanFan * cellsNow / (Double(max(1, renderer.views - 1)) * leverP * (18.0 / Double(renderer.lens)))
        let bud = Double(renderer.budgetPct) / 100.0
        let limiter: String
        if bud <= min(capCell, capFan) { limiter = String(format: "预算%.1f%%", bud * 100) }
        else if capCell <= capFan { limiter = String(format: "单格角%.1f%%", capCell * 100) }
        else { limiter = String(format: "扇形角%.1f%%", capFan * 100) }
        l.stringValue += String(format: " · 限制:%@ · 建议N %d · 眼区间距 %.0fmm/瞳距%.0fmm %@",
                                limiter as NSString, nRec, spacingMM, Double(renderer.ipdMM), coverOK ? "连续" : "有空档")
        l.textColor = (span > 3.0 || dispEff > 2.5 || capPct < disp) ? .systemOrange : .secondaryLabelColor
    }
    @objc func sliderChanged(_ s: NSSlider) {
        guard let k = s.identifier?.rawValue else { return }
        apply(k, s.doubleValue)
        fields[k]?.stringValue = fmtVal(k, s.doubleValue)
    }
    // 显示通路自检: 纯色 + 移动白条, 直接画进 drawable
    func runProbe() {
        probe = true
        panelView.delegate = self
        panelView.isPaused = false
        panelView.enableSetNeedsDisplay = false
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in NSApp.terminate(nil) }
    }

    func runDump() {
        let W = PW, H = PH
        let quiltOut = (dumpPath ?? "").contains("quilt")
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let out = renderer.dev.makeTexture(descriptor: td),
              let cb = renderer.queue.makeCommandBuffer() else { return }
        renderer.renderQuilt(cb)
        if !quiltOut { renderer.drawQuad(cb, target: out, drawable: nil, mode: 0) }
        cb.commit(); cb.waitUntilCompleted()

        let src = quiltOut ? renderer.quilt : out
        let tw = quiltOut ? 4320 : W, th = quiltOut ? 4800 : H
        var bytes = [UInt8](repeating: 0, count: tw * th * 4)
        // 用 blit 通道把纹理拷到共享缓冲，避免 getBytes 在私有纹理上读到空数据
        if let stg = renderer.dev.makeBuffer(length: tw * th * 4, options: .storageModeShared),
           let bcb = renderer.queue.makeCommandBuffer(),
           let bl = bcb.makeBlitCommandEncoder() {
            bl.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: tw, height: th, depth: 1),
                    to: stg, destinationOffset: 0, destinationBytesPerRow: tw * 4, destinationBytesPerImage: tw * th * 4)
            bl.endEncoding(); bcb.commit(); bcb.waitUntilCompleted()
            memcpy(&bytes, stg.contents(), tw * th * 4)
        }
        // BGRA -> RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let img = CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4,
                          space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dumpPath!))
            print("wrote \(dumpPath!) \(tw)x\(th) views=\(renderer.views) quilt=\(quiltOut)")
        }
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

let argv = CommandLine.arguments
let app = NSApplication.shared
let dg = AppDelegate()
if let i = argv.firstIndex(of: "--dump"), i + 1 < argv.count { dg.dumpPath = argv[i + 1] }
if argv.contains("--probe") { dg.probe = true }
if let i = argv.firstIndex(of: "--saveframe"), i + 1 < argv.count { dg.savePath = argv[i + 1] }
if let i = argv.firstIndex(of: "--autoclose"), i + 1 < argv.count, let s = Double(argv[i + 1]) { dg.autoclose = s }
app.delegate = dg
app.setActivationPolicy(.regular)
app.run()
