import Foundation
import AVFoundation
import Combine

struct BFA7SystemCaptureItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let detail: String

    var isBFA7Candidate: Bool {
        let text = "\(name) \(detail)".lowercased()
        return text.contains("bfa7") || text.contains("xiaomi") || text.contains("ai glasses")
    }
}

@MainActor
final class SystemCaptureProbe: ObservableObject {
    @Published private(set) var videoDevices: [BFA7SystemCaptureItem] = []
    @Published private(set) var audioInputs: [BFA7SystemCaptureItem] = []
    @Published private(set) var audioRouteOutputs: [BFA7SystemCaptureItem] = []
    @Published private(set) var status = "Ожидание"
    @Published private(set) var lastReport = "No system capture report yet."

    func requestPermissionsAndRefresh() async {
        let cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        let micAllowed = await requestMicrophonePermission()
        refresh()
        status = "Camera: \(cameraAllowed ? "allowed" : "denied"), mic: \(micAllowed ? "allowed" : "denied")"
    }

    func refresh() {
        videoDevices = discoverVideoDevices()
        refreshAudioRoute()
        let candidates = (videoDevices + audioInputs + audioRouteOutputs).filter(\.isBFA7Candidate).count
        let externalVideoCount = videoDevices.filter(\.isExternalVideo).count
        status = "Video \(videoDevices.count), external video \(externalVideoCount), audio inputs \(audioInputs.count), route outputs \(audioRouteOutputs.count), BFA7 candidates \(candidates)"
        lastReport = makeReport()
    }

    private func discoverVideoDevices() -> [BFA7SystemCaptureItem] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .external
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        return session.devices.map { device in
            BFA7SystemCaptureItem(
                id: device.uniqueID,
                name: device.localizedName,
                kind: "video",
                detail: "\(device.deviceType.rawValue) / \(positionName(device.position))"
            )
        }
    }

    private func refreshAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            status = "Audio route error: \(error.localizedDescription)"
        }

        audioInputs = (audioSession.availableInputs ?? []).map { input in
            BFA7SystemCaptureItem(
                id: input.uid,
                name: input.portName,
                kind: "audio input",
                detail: input.portType.rawValue
            )
        }

        audioRouteOutputs = audioSession.currentRoute.outputs.map { output in
            BFA7SystemCaptureItem(
                id: output.uid,
                name: output.portName,
                kind: "audio output",
                detail: output.portType.rawValue
            )
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func positionName(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private func makeReport() -> String {
        var lines: [String] = []
        lines.append("BFA7 System Capture Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Status: \(status)")
        lines.append("")
        append("Video", videoDevices, to: &lines)
        append("Audio input", audioInputs, to: &lines)
        append("Audio output", audioRouteOutputs, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func append(_ title: String, _ items: [BFA7SystemCaptureItem], to lines: inout [String]) {
        lines.append("\(title): \(items.count)")
        if items.isEmpty {
            lines.append("  none")
        } else {
            for item in items {
                let marker = item.isBFA7Candidate ? " [BFA7?]" : ""
                lines.append("  \(item.name)\(marker) | \(item.detail)")
            }
        }
        lines.append("")
    }
}

private extension BFA7SystemCaptureItem {
    var isExternalVideo: Bool {
        kind == "video" && detail.localizedCaseInsensitiveContains("external")
    }
}
