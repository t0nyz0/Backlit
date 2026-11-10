import Foundation
import CoreAudio

/// Public Core Audio tap. Private to this process, unmuted, and never installed
/// as the default input/output device. No display/window enumeration occurs.
@available(macOS 14.2, *)
final class ProcessAudioTap {
    private var tap:AudioObjectID=0
    private var aggregate:AudioObjectID=0
    private var procedure:AudioDeviceIOProcID?
    func start(queue:DispatchQueue,consume:@escaping(UnsafePointer<AudioBufferList>,AudioStreamBasicDescription)->Void) throws {
        let description=CATapDescription(monoGlobalTapButExcludeProcesses:[])
        description.name="Backlit music response";description.isPrivate=true;description.muteBehavior = .unmuted
        do {
            try check(AudioHardwareCreateProcessTap(description,&tap),stage:"request system audio")
            var format=AudioStreamBasicDescription()
            var address=AudioObjectPropertyAddress(mSelector:kAudioTapPropertyFormat,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap,&address,0,nil,&size,&format),stage:"read the audio format")
            guard format.mFormatID == kAudioFormatLinearPCM,format.mFormatFlags & kAudioFormatFlagIsFloat != 0,[32,64].contains(format.mBitsPerChannel) else {throw RuntimeServices.failure("This output device uses an unsupported system-audio format.")}
            let settings:[String:Any]=[
                kAudioAggregateDeviceNameKey:"Backlit music response",
                kAudioAggregateDeviceUIDKey:"local.backlit.audio."+UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey:true,
                kAudioAggregateDeviceTapAutoStartKey:true,
                kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:description.uuid.uuidString,kAudioSubTapDriftCompensationKey:true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary,&aggregate),stage:"prepare system audio")
            let streamFormat=format
            try check(AudioDeviceCreateIOProcIDWithBlock(&procedure,aggregate,queue){_,input,_,_,_ in consume(input,streamFormat)},stage:"connect system audio")
            try check(AudioDeviceStart(aggregate,procedure),stage:"start system audio")
        } catch {stop();throw error}
    }
    func stop() {
        if aggregate != 0 {
            if let procedure {_ = AudioDeviceStop(aggregate,procedure);_ = AudioDeviceDestroyIOProcID(aggregate,procedure)}
            procedure=nil;_ = AudioHardwareDestroyAggregateDevice(aggregate);aggregate=0
        }
        if tap != 0 {_ = AudioHardwareDestroyProcessTap(tap);tap=0}
    }
    private func check(_ status:OSStatus,stage:String)throws {
        guard status != noErr else{return}
        throw NSError(domain:"Backlit.Audio",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"Backlit could not \(stage). Allow Backlit in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Backlit and retry. (macOS code \(status))"])
    }
    deinit {stop()}
}

/// Small streaming bass envelope; no PCM buffer is copied, stored, or uploaded.
final class AudioEnergyMeter {
    private let lock=NSLock()
    private var filtered=0.0
    private var energy=0.0
    private var lastUpdate = -Double.infinity
    private var bufferDuration=0.01
    var level:Double {
        lock.lock();defer{lock.unlock()}
        // Audio taps may stop delivering buffers when playback stops. A stale
        // packet must not leave the logo glowing at its last captured level.
        let age=ProcessInfo.processInfo.systemUptime-lastUpdate
        return energy*exp(-max(0,age-max(0.04,bufferDuration*1.5))/0.06)
    }
    func reset(){lock.lock();filtered=0;energy=0;lastUpdate = -Double.infinity;lock.unlock()}
    func consume(_ raw:UnsafeRawPointer,bytes:Int,channels:Int,sampleRate:Double,bits:UInt32) {
        guard sampleRate.isFinite,sampleRate>0,[32,64].contains(bits),channels>0 else{return}
        let width=Int(bits/8),count=bytes/Int(bits/8)
        guard count>0 else{return}
        lock.lock();defer{lock.unlock()}
        let alpha=1-exp(-2*Double.pi*180/sampleRate)
        var square=0.0,frames=0
        for index in stride(from:0,to:count,by:channels) {
            let value=bits == 32 ? Double(raw.load(fromByteOffset:index*width,as:Float.self)) : raw.load(fromByteOffset:index*width,as:Double.self)
            guard value.isFinite else{continue}
            filtered += alpha*(value-filtered);square += filtered*filtered;frames += 1
        }
        guard frames>0 else{energy=0;return}
        let next=min(1,sqrt(square/Double(frames))*12)
        bufferDuration=Double(frames)/sampleRate
        let release=exp(-bufferDuration/0.06)
        energy=next>energy ? next : energy*release+next*(1-release)
        lastUpdate=ProcessInfo.processInfo.systemUptime
    }
}
