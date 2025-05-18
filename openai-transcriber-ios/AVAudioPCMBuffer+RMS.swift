import AVFoundation
import Accelerate

extension AVAudioPCMBuffer {
    /// バッファの RMS (Root Mean Square) を 0.0〜1.0 で返す
    func rmsMagnitude() -> Float {
        guard let chData = floatChannelData else { return 0 }
        let n = Int(frameLength)
        var rms: Float = 0
        vDSP_rmsqv(chData[0], 1, &rms, vDSP_Length(n))
        return rms
    }
}
