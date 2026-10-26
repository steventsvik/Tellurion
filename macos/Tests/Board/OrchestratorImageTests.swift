import AppKit
import Testing
@testable import Ghostty

/// Pictures pasted into an orchestrator's command: read off a pasteboard, kept as PNG no
/// larger than the models read, and handed to Claude Code in its prompt or to Codex as files.
struct OrchestratorImageTests {
    private func picture(_ width: Int, _ height: Int) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private var pngSignature: [UInt8] { [0x89, 0x50, 0x4E, 0x47] }

    @Test func pictureOnPasteboardBecomesAPNGAttachment() throws {
        let pasteboard = pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([picture(40, 30)])
        let images = ImageAttachment.read(from: pasteboard)
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.pixelSize == CGSize(width: 40, height: 30))
        #expect(Array(image.png.prefix(4)) == pngSignature)
        #expect(ImageAttachment.mayHoldImages(pasteboard))
    }

    @Test func imageFileOnPasteboardIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shot.png")
        try #require(ImageAttachment.png(picture(24, 24))).0.write(to: file)
        let pasteboard = pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        let images = ImageAttachment.read(from: pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.pixelSize == CGSize(width: 24, height: 24))
    }

    @Test func textAloneIsNoPicture() {
        let pasteboard = pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("just words", forType: .string)
        #expect(ImageAttachment.read(from: pasteboard).isEmpty)
        #expect(!ImageAttachment.mayHoldImages(pasteboard))
    }

    @Test func bigPicturesAreScaledToWhatTheModelsRead() throws {
        let image = try #require(ImageAttachment(image: picture(4000, 1000)))
        #expect(image.pixelSize == CGSize(width: 1568, height: 392))
        let small = try #require(ImageAttachment(image: picture(300, 200)))
        #expect(small.pixelSize == CGSize(width: 300, height: 200))
    }

    @Test func claudeGetsPicturesInAStreamedMessage() throws {
        let plain = HeadlessAgent.arguments(.claude, instructions: "i", schema: "{}", session: nil)
        #expect(!plain.contains("--input-format"))
        #expect(plain.contains("json"))
        let file = URL(fileURLWithPath: "/tmp/one.png")
        let streamed = HeadlessAgent.arguments(.claude, instructions: "i", schema: "{}", session: "s", images: [file])
        #expect(streamed.contains("--input-format"))
        #expect(streamed.contains("stream-json"))
        #expect(!streamed.contains("json"))
        #expect(streamed.contains("--resume"))

        let png = try #require(ImageAttachment.png(picture(8, 8))).0
        let input = HeadlessAgent.input(.claude, prompt: "What is this?", images: [png])
        let json = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "What is this?")
        #expect(content[1]["type"] as? String == "image")
        let source = try #require(content[1]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(Data(base64Encoded: try #require(source["data"] as? String)) == png)
        #expect(input.last == 0x0A)

        #expect(HeadlessAgent.input(.claude, prompt: "Hi", images: []) == Data("Hi".utf8))
        #expect(HeadlessAgent.input(.codex, prompt: "Hi", images: [png]) == Data("Hi".utf8))
    }

    @Test func codexGetsPicturesAsFiles() {
        let one = URL(fileURLWithPath: "/tmp/one.png"), two = URL(fileURLWithPath: "/tmp/two.png")
        let fresh = HeadlessAgent.arguments(.codex, instructions: "i", schema: "{}", session: nil, images: [one, two])
        #expect(fresh.first == "exec")
        #expect(fresh.last == "-")
        let joined = fresh.joined(separator: " ")
        #expect(joined.contains("-i /tmp/one.png -i /tmp/two.png"))
        let resumed = HeadlessAgent.arguments(.codex, instructions: "i", schema: "{}", session: "thread", images: [one])
        #expect(resumed.prefix(2) == ["exec", "resume"])
        #expect(resumed.suffix(2) == ["thread", "-"])
        #expect(resumed.joined(separator: " ").contains("-i /tmp/one.png"))
        #expect(!HeadlessAgent.arguments(.codex, instructions: "i", schema: "{}", session: nil).contains("-i"))
    }

    @Test func claudesStreamedAnswerIsItsResultLine() throws {
        let stream = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"StructuredOutput","input":{"say":"Hi"}}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"{\\"say\\":\\"Hi\\"}","structured_output":{"say":"Hi","actions":[],"done":true},"session_id":"abc"}
        """
        let parsed = HeadlessAgent.parseClaude(AgentTools.Result(status: 0, output: stream, error: ""))
        #expect(parsed.session == "abc")
        #expect(parsed.error == nil)
        let reply = try JSONDecoder().decode(OrchestratorReply.self, from: try #require(parsed.json))
        #expect(reply.say == "Hi")
        #expect(reply.done == true)

        let whole = #"{"type":"result","structured_output":{"say":"Yo","actions":[],"done":false},"session_id":"def"}"#
        let single = HeadlessAgent.parseClaude(AgentTools.Result(status: 0, output: whole, error: ""))
        #expect(single.session == "def")
        #expect(single.json != nil)

        let broken = HeadlessAgent.parseClaude(AgentTools.Result(status: 1, output: "not json\n{\"type\":\"other\"}", error: "boom"))
        #expect(broken.json == nil)
        #expect(broken.error?.contains("boom") == true)
    }

    @Test func savedPicturesAreFilesAndOldOnesGo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(ImageAttachment(image: picture(10, 10)))
        let now = Date()
        let first = ImageAttachment.save([image], in: folder, now: now.addingTimeInterval(-3 * 86_400))
        #expect(first.count == 1)
        let old = try #require(first.first)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        let second = ImageAttachment.save([image], in: folder, now: now)
        #expect(second.count == 1)
        let kept = try #require(second.first)
        #expect(kept.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(Array(try Data(contentsOf: kept).prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(ImageAttachment.save([], in: folder, now: now).isEmpty)
    }
}
