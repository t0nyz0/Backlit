import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import CoreAudio

final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stateLock = NSLock()
    private var storedStream: SCStream?
    private var streamGeneration: UInt64 = 0
    private var storedRunning = false
    private var stream: SCStream? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedStream }
        set { stateLock.lock(); storedStream = newValue; streamGeneration &+= 1; stateLock.unlock() }
    }
    private let queue = DispatchQueue(label: "Backlit.Audio", qos: .userInitiated)
    private let meter=AudioEnergyMeter()
    private let lifecycle=NSLock()
    private var native:AnyObject?
    private(set) var running: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedRunning }
        set { stateLock.lock(); storedRunning = newValue; stateLock.unlock() }
    }
    var onFailure: ((String, UInt64) -> Void)?
    func acceptsFailure(_ token: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return token == streamGeneration
    }
    var level:Double {meter.level}

    func start() async throws {
        if #available(macOS 14.2, *) {try startNative();return}
        guard stream == nil else { return }
        let content:SCShareableContent
        do {content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)}
        catch {throw Self.friendly(error)}
        guard let display = content.displays.first else { throw NSError(domain: "Backlit.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display is available for system audio capture."]) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let candidate = SCStream(filter: filter, configuration: config, delegate: self)
        try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = candidate
        do {
            try await candidate.startCapture()
            guard stream === candidate else { throw RuntimeServices.failure("System audio stopped before it was ready.") }
            running = true
        } catch {
            if stream === candidate { stream = nil }
            throw Self.friendly(error)
        }
    }

    @available(macOS 14.2, *) private func startNative()throws {
        lifecycle.lock();defer{lifecycle.unlock()}
        guard native == nil else{return}
        let candidate=ProcessAudioTap()
        try candidate.start(queue:queue){[weak self] input,format in
            guard let self else{return}
            let buffers=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
            for buffer in buffers {
                if let raw=buffer.mData {self.meter.consume(raw,bytes:Int(buffer.mDataByteSize),channels:Int(buffer.mNumberChannels),sampleRate:format.mSampleRate,bits:format.mBitsPerChannel)}
            }
        }
        native=candidate;running=true
    }
    private func stopNative() {
        lifecycle.lock();defer{lifecycle.unlock()}
        if #available(macOS 14.2,*),let tap=native as? ProcessAudioTap {tap.stop()}
        native=nil
    }
    static func friendly(_ error:Error)->Error {
        let value=error as NSError
        if value.code == -3801 || value.localizedDescription.localizedCaseInsensitiveContains("declined TCC") {
            return RuntimeServices.failure("System audio access is off for Backlit. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Backlit and try Start System Audio again. Backlit does not record your screen or microphone.")
        }
        return error
    }
    func stop() async {
        stopNative()
        let previous = stream
        stream = nil
        running = false
        try? await previous?.stopCapture()
        resetLevel()
    }

    private func resetLevel() {meter.reset()}

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        guard stream === storedStream else { stateLock.unlock(); return }
        storedStream = nil; storedRunning = false
        let token = streamGeneration
        stateLock.unlock()
        resetLevel()
        onFailure?(Self.friendly(error).localizedDescription, token)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        var retained: CMBlockBuffer?
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained) == noErr,
              let raw = list.mBuffers.mData else { return }
        meter.consume(raw,bytes:Int(list.mBuffers.mDataByteSize),channels:Int(list.mBuffers.mNumberChannels),sampleRate:format.mSampleRate,bits:format.mBitsPerChannel)
    }
}
