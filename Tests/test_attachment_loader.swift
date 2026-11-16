import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Synthetic files only. Covers path confinement, image and PDF rendering, and refusal of other content.
@main struct Tests {
 static func png(_ width:Int,_ height:Int)->Data {
  let space=CGColorSpaceCreateDeviceRGB()
  let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red:0.2,green:0.5,blue:0.9,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
  let out=NSMutableData();let dest=CGImageDestinationCreateWithData(out,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);_=CGImageDestinationFinalize(dest);return out as Data
 }
 static func pdf(pages:Int)->Data {
  let out=NSMutableData();var box=CGRect(x:0,y:0,width:612,height:792)
  let ctx=CGContext(consumer:CGDataConsumer(data:out)!,mediaBox:&box,nil)!
  for _ in 0..<pages {ctx.beginPDFPage(nil);ctx.setFillColor(CGColor(red:0.9,green:0.9,blue:0.2,alpha:1));ctx.fill(box);ctx.endPDFPage()}
  ctx.closePDF();return out as Data
 }
 static func main() {
  let fm=FileManager.default
  let root=fm.temporaryDirectory.appendingPathComponent("attach-test-\(UUID().uuidString)")
  let dir=root.appendingPathComponent("Attachments/ab/12/GUID")
  try! fm.createDirectory(at:dir,withIntermediateDirectories:true)
  defer{try? fm.removeItem(at:root)}
  try! png(3000,2000).write(to:dir.appendingPathComponent("big.png"))
  try! pdf(pages:5).write(to:dir.appendingPathComponent("map.pdf"))
  try! Data("not an image".utf8).write(to:dir.appendingPathComponent("note.txt"))
  let outside=fm.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png");try! png(10,10).write(to:outside)
  defer{try? fm.removeItem(at:outside)}
  try! fm.createSymbolicLink(at:dir.appendingPathComponent("link.png"),withDestinationURL:outside)

  // Path confinement
  precondition(AttachmentLoader.resolve(storedPath:"~/Library/Messages/Attachments/ab/12/GUID/big.png",folder:root) != nil)
  precondition(AttachmentLoader.resolve(storedPath:"~/Library/Messages/Attachments/ab/../../chat.db",folder:root)==nil)
  precondition(AttachmentLoader.resolve(storedPath:"~/Library/Messages/chat.db",folder:root)==nil)
  precondition(AttachmentLoader.resolve(storedPath:"/etc/passwd",folder:root)==nil)
  precondition(AttachmentLoader.resolve(storedPath:"~/Library/Messages/Attachments/ab/12/GUID/link.png",folder:root)==nil)
  precondition(AttachmentLoader.resolve(storedPath:"~/Library/Messages/Attachments/ab/12/GUID/missing.png",folder:root)==nil)

  func source(_ name:String,_ mime:String?)->LocalAttachmentSource {LocalAttachmentSource(name:name,mimeType:mime,size:nil,storedPath:"~/Library/Messages/Attachments/ab/12/GUID/\(name)")}
  // Image: downscaled JPEG within the size cap
  let image=try! AttachmentLoader.load(source:source("big.png","image/png"),folder:root,maxBytes:15_000_000)
  precondition(image.images.count==1 && image.images[0].count<=AttachmentLoader.maxJPEGBytes && image.images[0].prefix(2)==Data([0xFF,0xD8]))
  let decoded=CGImageSourceCreateWithData(image.images[0] as CFData,nil).flatMap{CGImageSourceCreateImageAtIndex($0,0,nil)}!
  precondition(max(decoded.width,decoded.height)<=AttachmentLoader.maxImageDimension)
  // PDF: page count reported, first pages rendered
  let document=try! AttachmentLoader.load(source:source("map.pdf","application/pdf"),folder:root,maxBytes:15_000_000)
  precondition(document.pageCount==5 && document.images.count==AttachmentLoader.maxPdfPages && document.mimeType=="application/pdf")
  // Unsupported content, even with an image MIME label
  do {_=try AttachmentLoader.load(source:source("note.txt","image/jpeg"),folder:root,maxBytes:15_000_000);preconditionFailure("text accepted")}
  catch AttachmentLoadError.unsupportedType {}
  catch {preconditionFailure("wrong error \(error)")}
  // Size cap and missing file
  do {_=try AttachmentLoader.load(source:source("big.png","image/png"),folder:root,maxBytes:100);preconditionFailure("cap ignored")}
  catch AttachmentLoadError.tooLarge {}
  catch {preconditionFailure("wrong error \(error)")}
  do {_=try AttachmentLoader.load(source:source("link.png","image/png"),folder:root,maxBytes:15_000_000);preconditionFailure("symlink followed")}
  catch AttachmentLoadError.notAvailable {}
  catch {preconditionFailure("wrong error \(error)")}
  print("PASS attachment path confinement, image and PDF rendering, type and size refusal")
 }
}
