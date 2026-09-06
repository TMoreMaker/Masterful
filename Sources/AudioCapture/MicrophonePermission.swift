import AVFoundation
import Foundation
import MasterfulKit

public enum MicrophonePermission {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var isGranted: Bool { status == .authorized }

    /// Shows the system prompt the first time; afterwards resolves immediately
    /// with the standing answer.
    public static func request() async -> Bool {
        if status == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
