import Foundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Reads one attachment file from inside the granted Messages folder and turns it into
// something a model can use: a downscaled JPEG for images, extracted text plus the first
// page images for PDFs. Raw files and filesystem paths never leave this process.
enum AttachmentLoadError: Error, Equatable { case notAvailable, tooLarge, unsupportedType, unreadable }

struct LoadedAttachment {
 let mimeType:String          // type of the original file
 let byteCount:Int            // size of the original file
 let text:String?             // PDF text, if any
 let pageCount:Int?           // PDF pages
 let images:[Data]            // JPEG data, in display order
}

enum AttachmentLoader {
 static let maxTextCharacters = 20_000
 static let maxPdfPages = 3
 static let maxImageDimension = 1_568
 static let maxJPEGBytes = 700 * 1_024

 // Maps the path stored by Messages ("~/Library/Messages/Attachments/..") to a file inside the
 // granted folder. Anything outside "Attachments/", with "..", or through a symlink is refused.
 static func resolve(storedPath:String,folder:URL)->URL? {
  var relative=storedPath
  for prefix in ["~/Library/Messages/","/Library/Messages/"] where relative.hasPrefix(prefix) {relative=String(relative.dropFirst(prefix.count));break}
  if let range=relative.range(of:"/Library/Messages/") {relative=String(relative[range.upperBound...])}
  guard relative.hasPrefix("Attachments/"),!relative.utf8.contains(0),relative.utf8.count<=1_024 else {return nil}
  let parts=relative.split(separator:"/",omittingEmptySubsequences:false)
  guard parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {return nil}
  var url=folder
  for part in parts {url.appendPathComponent(String(part))}
  guard let real=realpath(url.path,nil) else {return nil}
  defer {free(real)}
  guard let base=realpath(folder.path,nil) else {return nil}
  defer {free(base)}
  let resolved=String(cString:real),root=String(cString:base)
  guard resolved.hasPrefix(root+"/Attachments/") else {return nil}
  return URL(fileURLWithPath:resolved)
 }

 static func load(source:LocalAttachmentSource,folder:URL,maxBytes:Int)throws->LoadedAttachment {
  guard let stored=source.storedPath,let url=resolve(storedPath:stored,folder:folder) else {throw AttachmentLoadError.notAvailable}
  let fd=open(url.path,O_RDONLY|O_NOFOLLOW)
  guard fd>=0 else {throw AttachmentLoadError.notAvailable}
  defer {close(fd)}
  var info=stat()
  guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG else {throw AttachmentLoadError.notAvailable}
  guard info.st_size>0,info.st_size<=Int64(maxBytes) else {throw AttachmentLoadError.tooLarge}
  guard let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd(),data.count==Int(info.st_size) else {throw AttachmentLoadError.unreadable}
  return try render(data:data,declaredMime:source.mimeType,fileName:url.lastPathComponent)
 }

 // Kind is decided from the file content first (PDF header, image decoder), the stored
 // MIME type only as a hint, so a mislabeled file cannot reach a decoder it was not meant for.
 static func render(data:Data,declaredMime:String?,fileName:String)throws->LoadedAttachment {
  if data.prefix(5)==Data("%PDF-".utf8) {return try renderPDF(data)}
  if let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)>0,
     let jpeg=downscaledJPEG(source) {
   let mime=(CGImageSourceGetType(source) as String?).flatMap{UTType($0)?.preferredMIMEType} ?? declaredMime ?? "image/*"
   return LoadedAttachment(mimeType:mime,byteCount:data.count,text:nil,pageCount:nil,images:[jpeg])
  }
  throw AttachmentLoadError.unsupportedType
 }

 static func downscaledJPEG(_ source:CGImageSource)->Data? {
  let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxImageDimension]
  guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else {return nil}
  return jpeg(image)
 }

 static func jpeg(_ image:CGImage)->Data? {
  for quality in [0.8,0.65,0.5,0.35] {
   let out=NSMutableData()
   guard let dest=CGImageDestinationCreateWithData(out,UTType.jpeg.identifier as CFString,1,nil) else {return nil}
   CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
   guard CGImageDestinationFinalize(dest) else {return nil}
   if out.length<=maxJPEGBytes {return out as Data}
  }
  return nil
 }

 static func renderPDF(_ data:Data)throws->LoadedAttachment {
  guard let document=PDFDocument(data:data),!document.isLocked,document.pageCount>0 else {throw AttachmentLoadError.unreadable}
  var text=document.string ?? ""
  if text.count>maxTextCharacters {text=String(text.prefix(maxTextCharacters))+"\n[text truncated]"}
  var images:[Data]=[]
  for index in 0..<min(document.pageCount,maxPdfPages) {
   guard let page=document.page(at:index) else {continue}
   let bounds=page.bounds(for:.mediaBox)
   guard bounds.width>0,bounds.height>0 else {continue}
   let scale=min(Double(maxImageDimension)/Double(max(bounds.width,bounds.height)),3)
   let size=CGSize(width:bounds.width*scale,height:bounds.height*scale)
   let thumbnail=page.thumbnail(of:size,for:.mediaBox)
   if let cg=thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil),let jpegData=jpeg(cg) {images.append(jpegData)}
  }
  let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
  return LoadedAttachment(mimeType:"application/pdf",byteCount:data.count,text:trimmed.isEmpty ? nil:trimmed,pageCount:document.pageCount,images:images)
 }
}
