import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let input = root.appendingPathComponent("VideoPrompter.png")
let image = NSImage(contentsOf: input)!
let bitmap = NSBitmapImageRep(data: try Data(contentsOf: input))!
let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
// Recover only the border-connected near-black exterior, never the microphone.
var exterior = [Bool](repeating: false, count: w*h)
var queue = [Int](); queue.reserveCapacity(w*h/4)
func visit(_ x: Int, _ y: Int) {
  let i = y*w+x
  guard !exterior[i], let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(c.redComponent,c.greenComponent,c.blueComponent) < 0.18 else { return }
  exterior[i] = true; queue.append(i)
}
for x in 0..<w { visit(x,0); visit(x,h-1) }
for y in 0..<h { visit(0,y); visit(w-1,y) }
var cursor = 0
while cursor < queue.count {
 let i = queue[cursor]; cursor += 1; let x = i%w, y = i/w
 if x>0 { visit(x-1,y) }; if x+1<w { visit(x+1,y) }; if y>0 { visit(x,y-1) }; if y+1<h { visit(x,y+1) }
}
let rgba = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
for y in 0..<h { for x in 0..<w {
 rgba.setColor(exterior[y*w+x] ? NSColor(deviceRed:0,green:0,blue:0,alpha:0) : bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!, atX:x,y:y)
}}
try rgba.representation(using:.png,properties:[:])!.write(to: input)
let set = root.appendingPathComponent("VideoPrompter.iconset")
try FileManager.default.createDirectory(at:set,withIntermediateDirectories:true)
let clean = NSImage(size:NSSize(width:w,height:h)); clean.addRepresentation(rgba)
for size in [16,32,128,256,512] { for scale in [1,2] {
 let n=size*scale
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:n,pixelsHigh:n,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 let context=NSGraphicsContext(bitmapImageRep:rep)!
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
 context.imageInterpolation = .high
 clean.draw(in:NSRect(x:0,y:0,width:n,height:n),from:.zero,operation:.copy,fraction:1)
 NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using:.png,properties:[:])!.write(to:set.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
 assert(rep.colorAt(x:0,y:0)!.alphaComponent == 0)
}}
print("Recovered \(queue.count) transparent exterior pixels; all ten icon sizes have alpha-zero corners")
