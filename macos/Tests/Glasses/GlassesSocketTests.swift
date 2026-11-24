import Foundation
import Testing
@testable import Ghostty

/// Putting a WebSocket message together from its frames: text as before, and binary for
/// the glasses' sound.
struct GlassesSocketTests {
    private typealias Assembler = PhoneSocket.MessageAssembler

    @Test func aTextFrameIsAMessage() {
        var assembler = Assembler()
        #expect(assembler.add(opcode: 0x1, fin: true, payload: Array("hello".utf8)) == .text("hello"))
        #expect(assembler.add(opcode: 0x1, fin: true, payload: []) == .text(""))
    }

    @Test func aBinaryFrameIsBytes() {
        var assembler = Assembler()
        #expect(assembler.add(opcode: 0x2, fin: true, payload: [0, 255, 7]) == .binary(Data([0, 255, 7])))
        // Bytes that aren't text stay bytes.
        #expect(assembler.add(opcode: 0x2, fin: true, payload: [0xFF, 0xFE]) == .binary(Data([0xFF, 0xFE])))
    }

    @Test func framesOfOneMessageAreJoinedAndKeepItsKind() {
        var assembler = Assembler()
        #expect(assembler.add(opcode: 0x2, fin: false, payload: [1, 2]) == .none)
        #expect(assembler.add(opcode: 0x0, fin: false, payload: [3]) == .none)
        #expect(assembler.add(opcode: 0x0, fin: true, payload: [4]) == .binary(Data([1, 2, 3, 4])))
        #expect(assembler.add(opcode: 0x1, fin: false, payload: Array("he".utf8)) == .none)
        #expect(assembler.add(opcode: 0x0, fin: true, payload: Array("llo".utf8)) == .text("hello"))
        // The next message starts clean.
        #expect(assembler.add(opcode: 0x2, fin: true, payload: [9]) == .binary(Data([9])))
    }

    @Test func framesOutOfOrderAreRefused() {
        var lone = Assembler()
        #expect(lone.add(opcode: 0x0, fin: true, payload: [1]) == .invalid)
        var interrupted = Assembler()
        #expect(interrupted.add(opcode: 0x1, fin: false, payload: [1]) == .none)
        #expect(interrupted.add(opcode: 0x2, fin: true, payload: [2]) == .invalid)
        var other = Assembler()
        #expect(other.add(opcode: 0x3, fin: true, payload: []) == .invalid)
    }

    @Test func aMessageLongerThanTheLimitIsRefusedHoweverItIsSplit() {
        var whole = Assembler()
        #expect(whole.add(opcode: 0x2, fin: true, payload: [UInt8](repeating: 0, count: 9), limit: 8) == .invalid)
        var split = Assembler()
        #expect(split.add(opcode: 0x2, fin: false, payload: [UInt8](repeating: 0, count: 5), limit: 8) == .none)
        #expect(split.add(opcode: 0x0, fin: false, payload: [UInt8](repeating: 0, count: 4), limit: 8) == .invalid)
        var exact = Assembler()
        #expect(exact.add(opcode: 0x2, fin: true, payload: [UInt8](repeating: 0, count: 8), limit: 8) == .binary(Data(count: 8)))
        #expect(PhoneSocket.maxMessage == 1024 * 1024)
    }
}
