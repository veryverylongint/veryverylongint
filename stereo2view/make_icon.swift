import Cocoa

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// 背景：圆角方块 + 冷灰渐变
let outer = CGRect(x: 0, y: 0, width: 1024, height: 1024).insetBy(dx: 32, dy: 32)
let bgPath = CGPath(roundedRect: outer, cornerWidth: 210, cornerHeight: 210, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [rgb(52, 58, 74), rgb(24, 26, 34)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])

// 背景上淡淡的透镜条纹（暗示光栅）
ctx.setBlendMode(.plusLighter)
ctx.setStrokeColor(rgb(255, 255, 255, 0.022))
ctx.setLineWidth(3)
var x: CGFloat = -200
while x < 1224 {
    ctx.move(to: CGPoint(x: x, y: 0))
    ctx.addLine(to: CGPoint(x: x + 260, y: 1024))
    x += 26
}
ctx.strokePath()
ctx.setBlendMode(.normal)
ctx.restoreGState()

// 面板：9:16 竖屏
let pw: CGFloat = 336, ph: CGFloat = 596
let panel = CGRect(x: (1024 - pw)/2, y: (1024 - ph)/2 - 8, width: pw, height: ph)
let bezel = CGPath(roundedRect: panel.insetBy(dx: -16, dy: -16), cornerWidth: 42, cornerHeight: 42, transform: nil)
ctx.saveGState()
ctx.addPath(bezel)
ctx.setFillColor(rgb(78, 84, 98))
ctx.fillPath()
ctx.restoreGState()

// 屏幕
let screen = CGPath(roundedRect: panel, cornerWidth: 26, cornerHeight: 26, transform: nil)
ctx.saveGState()
ctx.addPath(screen); ctx.clip()
ctx.setFillColor(rgb(10, 11, 14))
ctx.fill(panel)

// 屏幕上：透镜细纹
ctx.setStrokeColor(rgb(120, 200, 255, 0.10))
ctx.setLineWidth(2)
var sx = panel.minX
while sx < panel.maxX {
    ctx.move(to: CGPoint(x: sx, y: panel.minY))
    ctx.addLine(to: CGPoint(x: sx, y: panel.maxY))
    sx += 7
}
ctx.strokePath()

// 立体球：暖色主体 + 冷色错位（红青立体感）
let c = CGPoint(x: panel.midX, y: panel.midY + 30)
let r: CGFloat = 108

// 冷色重影
ctx.saveGState()
ctx.setBlendMode(.screen)
ctx.setFillColor(rgb(0, 190, 255, 0.55))
ctx.fillEllipse(in: CGRect(x: c.x - r - 18, y: c.y - r, width: 2*r, height: 2*r))
ctx.setFillColor(rgb(255, 70, 90, 0.55))
ctx.fillEllipse(in: CGRect(x: c.x - r + 18, y: c.y - r, width: 2*r, height: 2*r))
ctx.restoreGState()

// 主体球
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r))
ctx.clip()
let ballGrad = CGGradient(colorsSpace: cs,
                          colors: [rgb(255, 240, 205), rgb(255, 196, 120), rgb(232, 138, 58), rgb(150, 62, 30)] as CFArray,
                          locations: [0, 0.28, 0.62, 1])!
ctx.drawRadialGradient(ballGrad,
                       startCenter: CGPoint(x: c.x - r*0.34, y: c.y + r*0.40), startRadius: 2,
                       endCenter: CGPoint(x: c.x - r*0.1, y: c.y + r*0.1), endRadius: r*1.55,
                       options: [])
ctx.restoreGState()

// 球下方的小方块（第二层深度提示）
let cubeRect = CGRect(x: panel.midX - 46, y: panel.minY + 78, width: 92, height: 92)
ctx.setFillColor(rgb(90, 170, 255, 0.85))
ctx.fill(cubeRect)
ctx.setStrokeColor(rgb(150, 210, 255, 0.9))
ctx.setLineWidth(5)
ctx.stroke(cubeRect)

ctx.restoreGState()

// 屏幕高光
ctx.saveGState()
ctx.addPath(screen); ctx.clip()
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: panel.minX, y: panel.maxY),
                       end: CGPoint(x: panel.maxX - 60, y: panel.midY),
                       options: [])
ctx.restoreGState()

// 底部支架暗示
ctx.setFillColor(rgb(60, 66, 80))
ctx.fill(CGRect(x: 1024/2 - 90, y: panel.minY - 34, width: 180, height: 14))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "/tmp/icon_1024.png"))
print("ok")
