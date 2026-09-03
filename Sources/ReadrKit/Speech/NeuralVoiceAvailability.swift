/// Availability rules for neural speech engines that are unsafe on specific
/// Apple OS releases.
public enum NeuralVoiceAvailability {
    /// Returns whether Apple's BNNS runtime can crash the process during
    /// Kokoro inference on this OS version. macOS is affected only on
    /// 26.4–26.5: 26.6 is verified fixed, and FluidAudio 0.15.6 routes its
    /// separate macOS 27 GPU issue to CPU. iOS/iPadOS fails closed for every
    /// version from 26.4 onward, including later major versions, until a device
    /// build is verified safe.
    /// See FluidAudio issues
    /// [#817](https://github.com/FluidInference/FluidAudio/issues/817) and
    /// [#844](https://github.com/FluidInference/FluidAudio/issues/844).
    public static func isCrashProneOS(
        major: Int,
        minor: Int,
        onMacOS: Bool
    ) -> Bool {
        if onMacOS {
            return major == 26 && (4...5).contains(minor)
        }
        return major > 26 || (major == 26 && minor >= 4)
    }
}
