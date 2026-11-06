import Foundation
import AppKit
import CoreText

/// Saves a song's lyrics as a clean PDF in Desktop/Lyrics Export, ready to send to the team.
enum LyricsPDF {
    static var folder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Lyrics Export", isDirectory: true)
    }

    static func export(title: String, artist: String?, details: String, lyrics: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let url = folder.appendingPathComponent("\(safe.isEmpty ? "Lyrics" : safe).pdf")

        // Tidy the words: no more than one empty line between verses.
        let body = lyrics.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let text = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle(); titleStyle.paragraphSpacing = 4
        text.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.black, .paragraphStyle: titleStyle]))
        let sub = [artist, details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        if !sub.isEmpty {
            let p = NSMutableParagraphStyle(); p.paragraphSpacing = 18
            text.append(NSAttributedString(string: sub + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray, .paragraphStyle: p]))
        }
        let p = NSMutableParagraphStyle(); p.lineSpacing = 4; p.paragraphSpacing = 2
        text.append(NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black, .paragraphStyle: p]))

        var page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &page, [kCGPDFContextTitle as String: title,
                                                                  kCGPDFContextCreator as String: "Graceful Instruments"] as CFDictionary) else {
            throw NSError(domain: "LyricsPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the PDF file."])
        }
        let setter = CTFramesetterCreateWithAttributedString(text)
        var start = 0, pageNo = 1
        let frameRect = CGRect(x: 60, y: 60, width: 612 - 120, height: 792 - 120)
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            // Small footer with the page number.
            let foot = NSAttributedString(string: "\(title)  ·  page \(pageNo)", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
            let line = CTLineCreateWithAttributedString(foot)
            ctx.textPosition = CGPoint(x: 60, y: 32)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
            start += visible.length
            pageNo += 1
            if visible.length == 0 { break }
        } while start < text.length
        ctx.closePDF()
        return url
    }
}
