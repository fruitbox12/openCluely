import Foundation
import CoreMedia
import CoreImage
import AppKit

class VideoUtils {
    private static let ciContext = CIContext()
    static func sampleBufferToJPEG(buffer: CMSampleBuffer) -> String? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]) else { return nil }
        return jpegData.base64EncodedString()
    }
}
