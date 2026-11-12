import CoreAudio
import XCTest
import MixBarDSP

/// The render path on plain sample buffers, as the IO callback sees them.
final class DSPTests: XCTestCase {
    /// Renders interleaved `input` (with `inChannels`) into `outChannels` interleaved output.
    private func render(_ state: OpaquePointer, _ input: [Float], inChannels: UInt32, outChannels: UInt32, outFrames: Int? = nil) -> [Float] {
        var input = input
        let frames = outFrames ?? input.count / Int(inChannels)
        var output = [Float](repeating: 0, count: frames * Int(outChannels))
        input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: inChannels, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: outChannels, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                mb_render(state, &inList, &outList)
            }
        }
        return output
    }

    private func state(rate: Double = 1000, gain: Float = 1) -> OpaquePointer {
        let state = mb_render_state_create(rate, gain)!
        addTeardownBlock { mb_render_state_destroy(state) }
        return state
    }

    func testTwoHundredPercentOfFullScaleNeverExceedsFullScale() {
        let s = state(gain: 2)
        let full = (0..<64).flatMap { _ in [Float(1), Float(-1)] }
        let out = render(s, full, inChannels: 2, outChannels: 2)
        XCTAssertTrue(out.allSatisfy { abs($0) <= 1 }, "limited to full scale")
        XCTAssertTrue(out.allSatisfy { abs($0) > 0.99 }, "still loud: the knee approaches full scale")
        XCTAssertEqual(out[0], -out[1], "symmetric")
    }

    func testLimiterIsTransparentBelowThresholdAndMonotonicAbove() {
        for x: Float in [0, 0.1, -0.5, 0.9, -0.9] { XCTAssertEqual(mb_soft_limit(x), x) }
        var previous: Float = 0.9
        for step in 1...200 {
            let y = mb_soft_limit(0.9 + Float(step) * 0.01)
            XCTAssertGreaterThan(y, previous - 1e-7); XCTAssertLessThanOrEqual(y, 1)
            previous = y
        }
        XCTAssertEqual(mb_soft_limit(.nan), 0)
        XCTAssertEqual(mb_soft_limit(.infinity), 1)
        XCTAssertEqual(mb_soft_limit(-.infinity), -1)
    }

    func testHalfGainHalvesQuietSignal() {
        let s = state(gain: 0.5)
        let out = render(s, [0.4, -0.4, 0.2, -0.2], inChannels: 2, outChannels: 2)
        XCTAssertEqual(out, [0.2, -0.2, 0.1, -0.1])
    }

    func testGainChangeRampsInsteadOfJumping() {
        // 1000 Hz and a 20 ms ramp: 0.05 per frame, so 1 → 0 takes 20 frames.
        let s = state(rate: 1000, gain: 1)
        mb_set_target_gain(s, 0)
        let out = render(s, [Float](repeating: 0.5, count: 40), inChannels: 1, outChannels: 1)
        for i in 1..<out.count { XCTAssertLessThanOrEqual(abs(out[i] - out[i - 1]), 0.5 * 0.05 + 1e-5, "no step bigger than one ramp step at frame \(i)") }
        XCTAssertEqual(out[0], 0.5 * 0.95, accuracy: 1e-5)
        XCTAssertEqual(out[19], 0, accuracy: 1e-5, "ramp complete after 20 frames")
        XCTAssertEqual(out.last, 0)
        XCTAssertEqual(mb_current_gain(s), 0)
    }

    func testRampContinuesAcrossCallbacks() {
        let s = state(rate: 1000, gain: 1)
        mb_set_target_gain(s, 2)
        _ = render(s, [Float](repeating: 0.1, count: 10), inChannels: 1, outChannels: 1)
        XCTAssertEqual(mb_current_gain(s), 1.5, accuracy: 1e-4)
        _ = render(s, [Float](repeating: 0.1, count: 30), inChannels: 1, outChannels: 1)
        XCTAssertEqual(mb_current_gain(s), 2)
    }

    func testTargetGainIsClamped() {
        let s = state()
        mb_set_target_gain(s, 5); XCTAssertEqual(mb_target_gain(s), 2)
        mb_set_target_gain(s, -1); XCTAssertEqual(mb_target_gain(s), 0)
        mb_set_target_gain(s, .nan); XCTAssertEqual(mb_target_gain(s), 0)
    }

    func testMonoInputFeedsEveryOutputChannelAndStereoFoldsToMono() {
        let mono = render(state(), [0.25, 0.5], inChannels: 1, outChannels: 2)
        XCTAssertEqual(mono, [0.25, 0.25, 0.5, 0.5])
        let folded = render(state(), [0.2, 0.4, -0.2, 0], inChannels: 2, outChannels: 1)
        XCTAssertEqual(folded[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(folded[1], -0.1, accuracy: 1e-6)
    }

    func testExtraOutputChannelsStaySilent() {
        let out = render(state(), [0.1, 0.2], inChannels: 2, outChannels: 4)
        XCTAssertEqual(out, [0.1, 0.2, 0, 0])
    }

    func testDisabledInputStreamsAreSkippedAndShortInputLeavesTheRestZeroed() {
        // Two input buffers: a disabled device stream (NULL) and the tap's stereo stream.
        var tap: [Float] = [0.3, -0.3]
        var output = [Float](repeating: 0, count: 4)
        let s = state()
        tap.withUnsafeMutableBytes { tapBytes in
            output.withUnsafeMutableBytes { outBytes in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: nil)
                list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                mb_render(s, list.unsafePointer, &outList)
            }
        }
        XCTAssertEqual(output, [0.3, -0.3, 0, 0], "tap channels used, missing frames stay as the HAL zeroed them")
        XCTAssertEqual(mb_frames_rendered(s), 2)
    }

    func testSignalDetectionAndProgress() {
        let s = state()
        _ = render(s, [0, 0, 0, 0], inChannels: 2, outChannels: 2)
        XCTAssertFalse(mb_saw_signal(s), "digital silence is not proof of capture")
        XCTAssertEqual(mb_frames_rendered(s), 2)
        _ = render(s, [0, 0.001, 0, 0], inChannels: 2, outChannels: 2)
        XCTAssertTrue(mb_saw_signal(s))
        XCTAssertEqual(mb_frames_rendered(s), 4)
    }

    func testMutedTapStillLearnsSignal() {
        let s = state(gain: 0)
        let out = render(s, [0.5, 0.5], inChannels: 2, outChannels: 2)
        XCTAssertEqual(out, [0, 0])
        XCTAssertTrue(mb_saw_signal(s))
    }

    func testNilBuffersAreHarmless() {
        let s = state()
        mb_render(s, nil, nil)
        XCTAssertEqual(mb_frames_rendered(s), 0)
    }
}
