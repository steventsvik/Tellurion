import Foundation
import Testing
@testable import Ghostty

/// The start of a WebSocket frame, read before the phone has said who it is.
struct PhoneSocketFrameTests {
    private let mask: [UInt8] = [1, 2, 3, 4]

    @Test func aShortFrame() {
        let start = PhoneSocket.frameStart([0x81, 0x85] + mask + [0, 0, 0, 0, 0])
        #expect(start == .header(.init(fin: true, opcode: 0x1, offset: 2, length: 5)))
        #expect(PhoneSocket.FrameHeader(fin: true, opcode: 0x1, offset: 2, length: 5).size == 11)
        #expect(PhoneSocket.frameStart([0x01, 0x80]) == .header(.init(fin: false, opcode: 0x1, offset: 2, length: 0)))
        #expect(PhoneSocket.frameStart([0x89, 0xFD]) == .header(.init(fin: true, opcode: 0x9, offset: 2, length: 125)))
    }

    @Test func aTwoByteLength() {
        #expect(PhoneSocket.frameStart([0x81, 0xFE, 0x01, 0x00]) == .header(.init(fin: true, opcode: 0x1, offset: 4, length: 256)))
        #expect(PhoneSocket.frameStart([0x81, 0xFE, 0xFF, 0xFF]) == .header(.init(fin: true, opcode: 0x1, offset: 4, length: 65535)))
        #expect(PhoneSocket.frameStart([0x81, 0xFE, 0x01]) == .incomplete)
    }

    @Test func anEightByteLength() {
        #expect(PhoneSocket.frameStart([0x82, 0xFF, 0, 0, 0, 0, 0, 0x01, 0, 0])
                == .header(.init(fin: true, opcode: 0x2, offset: 10, length: 65536)))
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 0])
                == .header(.init(fin: true, opcode: 0x1, offset: 10, length: 1024 * 1024)))
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0, 0, 0, 0, 0, 0x10, 0]) == .incomplete)
    }

    @Test func aLengthThatWouldBeNegativeIsRefused() {
        // The top bit set: as a signed number this is negative, and used to pass the size check.
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]) == .invalid)
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == .invalid)
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + mask) == .invalid)
    }

    @Test func aHugeLengthIsRefused() {
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == .invalid)
        #expect(PhoneSocket.frameStart([0x81, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 0x01]) == .invalid)
    }

    @Test func anUnmaskedFrameIsRefused() {
        #expect(PhoneSocket.frameStart([0x81, 0x05]) == .invalid)
        #expect(PhoneSocket.frameStart([0x81, 0x7E, 0x01, 0x00]) == .invalid)
        #expect(PhoneSocket.frameStart([0x81, 0x7F, 0, 0, 0, 0, 0, 0, 0, 1]) == .invalid)
    }

    @Test func tooFewBytesWait() {
        #expect(PhoneSocket.frameStart([]) == .incomplete)
        #expect(PhoneSocket.frameStart([0x81]) == .incomplete)
    }
}
