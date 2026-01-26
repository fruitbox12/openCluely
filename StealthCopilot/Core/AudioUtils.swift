import Foundation
import AVFoundation
import CoreMedia
import Accelerate

class AudioUtils {
    private static let targetSampleRate: Double = 24000.0
    // We use separate converters for separate streams to avoid state corruption
    private static var micConverter: AVAudioConverter?
    private static var sysConverter: AVAudioConverter?
    
    static func calculateRMS(data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return -100 }
        var sum: Double = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let pointer = buffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let sample = Double(pointer[i]) / 32768.0
                sum += sample * sample
            }
        }
        return 20 * log10(Float(sqrt(sum / Double(sampleCount))) + 1e-9)
    }

    // Generic converter that handles variable inputs (Float32 from System, Int16 from Mic)
    static func convertBuffer(_ buffer: CMSampleBuffer, isSystem: Bool = false) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        
        // Handle odd non-interleaved or weird layouts by forcing standard import
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        
        // Target: 24kHz, Mono, Int16 (OpenAI Requirement)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true) else { return nil }
        
        // Select converter instance
        var converter = isSystem ? sysConverter : micConverter
        
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            if isSystem { sysConverter = converter } else { micConverter = converter }
        }
        
        guard let activeConverter = converter else { return nil }
        
        let numSamples = CMSampleBufferGetNumSamples(buffer)
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(numSamples) * ratio) + 100 // Padding
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return nil }
        
        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return AudioUtils.bufferFrom(sampleBuffer: buffer, format: inputFormat)
        }
        
        activeConverter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let channelData = outputBuffer.int16ChannelData {
            let dataLength = Int(outputBuffer.frameLength) * 2
            return Data(bytes: channelData[0], count: dataLength)
        }
        return nil
    }
    
    private static func bufferFrom(sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples)
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        // Handle Memory Copy for Int16 or Float32 sources
        if let src = dataPointer {
            if format.commonFormat == .pcmFormatFloat32, let dst = buffer.floatChannelData?[0] {
                memcpy(dst, src, totalLength)
            } else if format.commonFormat == .pcmFormatInt16, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, totalLength)
            } else {
                 // Fallback for direct memory bind if formats match exactly (rare)
                 return nil 
            }
        }
        return buffer
    }
}
