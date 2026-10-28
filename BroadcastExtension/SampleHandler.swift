import CoreMedia
import Network
import ReplayKit

// 화면 기록(방송) 확장. 다른 앱에서 나오는 소리만 받아 16kHz 모노 s16le 로 바꿔
// 기기 안 로컬 소켓(127.0.0.1)으로 본 앱에 넘긴다.
// 확장은 본 앱의 설정(Soniox 키)을 읽을 수 없어서(앱 그룹을 안 쓴다) 인식·번역은 본 앱이 한다.

final class SampleHandler: RPBroadcastSampleHandler {
    static let port: UInt16 = 48231

    private let q = DispatchQueue(label: "com.kouga.kemotranslate.broadcast")
    private var conn: NWConnection?
    private var ready = false
    private var finished = false
    private var rs = Resampler()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        q.async { self.connect() }
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        q.sync {
            finished = true
            ready = false
            conn?.cancel()
            conn = nil
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        q.async {
            guard self.ready, let c = self.conn else { return }
            guard let pcm = PCM.mono16k(sampleBuffer, &self.rs), !pcm.isEmpty else { return }
            c.send(content: pcm, completion: .contentProcessed { _ in })
        }
    }

    /// 본 앱이 아직 안 열려 있으면 1초마다 다시 붙어 본다
    private func connect() {
        guard !finished, conn == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let c = NWConnection(host: "127.0.0.1", port: port, using: params)
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c else { return }
            switch st {
            case .ready:
                self.ready = true
            case .failed, .waiting:
                c.cancel()
            case .cancelled:
                if self.conn === c { self.conn = nil; self.ready = false }
                if !self.finished { self.q.asyncAfter(deadline: .now() + 1) { self.connect() } }
            default:
                break
            }
        }
        conn = c
        c.start(queue: q)
    }
}

// MARK: 소리 바꾸기

/// 44.1·48kHz → 16kHz. 구간 평균으로 줄여서 높은 소리가 접혀 들어오는 걸 덜어 낸다.
struct Resampler {
    var acc: Float = 0
    var n: Int = 0
    var phase: Double = 0
}

enum PCM {
    static func mono16k(_ sb: CMSampleBuffer, _ rs: inout Resampler) -> Data? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        if frames <= 0 || asbd.mSampleRate <= 0 { return nil }

        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        if size <= 0 { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        let ch = max(1, Int(asbd.mChannelsPerFrame))
        guard bits == 16 || (bits == 32 && isFloat) || bits == 32 else { return nil }

        func sample(_ buf: AudioBuffer, _ index: Int) -> Float {
            guard let p = buf.mData else { return 0 }
            if bits == 16 {
                var v = p.assumingMemoryBound(to: Int16.self)[index]
                if bigEndian { v = Int16(bigEndian: v) }
                return Float(v) / 32768
            }
            if isFloat {
                var u = p.assumingMemoryBound(to: UInt32.self)[index]
                if bigEndian { u = UInt32(bigEndian: u) }
                return Float(bitPattern: u)
            }
            var v = p.assumingMemoryBound(to: Int32.self)[index]
            if bigEndian { v = Int32(bigEndian: v) }
            return Float(v) / 2147483648
        }

        let step = asbd.mSampleRate / 16000
        var out = [Int16]()
        out.reserveCapacity(Int(Double(frames) / step) + 2)
        for i in 0..<frames {
            var m: Float = 0
            if nonInterleaved {
                let nb = min(ch, abl.count)
                for c in 0..<nb { m += sample(abl[c], i) }
                m /= Float(max(1, nb))
            } else if abl.count > 0 {
                for c in 0..<ch { m += sample(abl[0], i * ch + c) }
                m /= Float(ch)
            }
            rs.acc += m
            rs.n += 1
            rs.phase += 1
            if rs.phase >= step {
                let v = max(-1, min(1, rs.acc / Float(rs.n)))
                out.append(Int16(v * 32767).littleEndian)
                rs.acc = 0; rs.n = 0; rs.phase -= step
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
