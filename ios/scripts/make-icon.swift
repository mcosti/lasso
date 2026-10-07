import AppKit

// 1024×1024 app icon: an open padlock on a dark background with an orange
// lightning bolt for the shackle gap, i.e. "unlocked, automatically".
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let top = CGColor(srgbRed: 0x2A/255, green: 0x2E/255, blue: 0x34/255, alpha: 1)
let bottom = CGColor(srgbRed: 0x0E/255, green: 0x10/255, blue: 0x12/255, alpha: 1)
let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

let orange = CGColor(srgbRed: 0xFF/255, green: 0x7A/255, blue: 0x1A/255, alpha: 1)

// Lock body.
let body = CGRect(x: 262, y: 150, width: 500, height: 380)
ctx.setFillColor(.white)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.fillPath()

// Keyhole.
ctx.setFillColor(bottom)
ctx.addEllipse(in: CGRect(x: 462, y: 330, width: 100, height: 100))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 492, y: 230, width: 40, height: 130), cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.fillPath()

// Open shackle: an arc on the left, lifted and swung out to the right.
ctx.setStrokeColor(.white)
ctx.setLineWidth(70)
ctx.setLineCap(.round)
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: 345, y: 530))
shackle.addLine(to: CGPoint(x: 345, y: 700))
shackle.addArc(center: CGPoint(x: 512, y: 700), radius: 167, startAngle: .pi, endAngle: 0, clockwise: true)
shackle.addLine(to: CGPoint(x: 679, y: 640))
ctx.addPath(shackle)
ctx.strokePath()

// Bolt.
ctx.setFillColor(orange)
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 760, y: 620))
bolt.addLine(to: CGPoint(x: 660, y: 450))
bolt.addLine(to: CGPoint(x: 730, y: 450))
bolt.addLine(to: CGPoint(x: 690, y: 330))
bolt.addLine(to: CGPoint(x: 830, y: 520))
bolt.addLine(to: CGPoint(x: 760, y: 520))
bolt.addLine(to: CGPoint(x: 790, y: 620))
bolt.closeSubpath()
ctx.addPath(bolt)
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
