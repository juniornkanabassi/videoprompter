// Read-only CoreAudio query. Does not open inputs or request microphone permission.
// Run: swift checks/audio-device-latency.swift [device-name-substring]
import CoreAudio
import Foundation
func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
 var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
 var value = initial; var size = UInt32(MemoryLayout<T>.size)
 let result = withUnsafeMutablePointer(to: &value) { pointer in
   AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer(pointer))
 }
 return result == noErr ? value : nil
}
var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioDeviceID](repeating:0,count:Int(size)/4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
var matches = 0
let filter = CommandLine.arguments.dropFirst().first ?? "ATEM"
for id in ids {
 let name = read(id,kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,Optional<Unmanaged<CFString>>.none).flatMap{$0?.takeUnretainedValue()} as String? ?? "?"
 guard name.localizedCaseInsensitiveContains(filter) else { continue }
 matches += 1
 print("device",id,name)
 for (name,key,scope) in [("bufferFrames",kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal),("deviceLatency",kAudioDevicePropertyLatency,kAudioDevicePropertyScopeInput),("safetyOffset",kAudioDevicePropertySafetyOffset,kAudioDevicePropertyScopeInput)] { print(name,read(id,key,scope,UInt32(0)) as Any) }
 print("sampleRate",read(id,kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,Double(0)) as Any)
 var p = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
 var bytes:UInt32 = 0
 AudioObjectGetPropertyDataSize(id,&p,0,nil,&bytes)
 var streams = [AudioStreamID](repeating:0,count:Int(bytes)/4)
 AudioObjectGetPropertyData(id,&p,0,nil,&bytes,&streams)
 for stream in streams { print("streamLatency",read(stream,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal,UInt32(0)) as Any) }
}
print("devices inspected",ids.count,"matching",matches)
if matches == 0 { print("No matching device connected; hardware latency is NOT MEASURED.") }
