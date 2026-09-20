import Foundation
import Combine

struct WiFiImportChecklist: Codable, Equatable {
    var ssid = ""
    var glassesIP = ""
    var iphoneIP = ""
    var gateway = ""
    var dns = ""
    var openPorts = ""
    var protocolNotes = ""
    var captureNotes = ""
    var lastUpdated = Date()

    var markdownReport: String {
        """
        # BFA7 Wi-Fi Import Checklist

        Updated: \(lastUpdated.ISO8601Format())

        - SSID: \(ssid.isEmpty ? "unknown" : ssid)
        - BFA7 IP: \(glassesIP.isEmpty ? "unknown" : glassesIP)
        - iPhone IP: \(iphoneIP.isEmpty ? "unknown" : iphoneIP)
        - Gateway: \(gateway.isEmpty ? "unknown" : gateway)
        - DNS: \(dns.isEmpty ? "unknown" : dns)
        - Open TCP/UDP ports: \(openPorts.isEmpty ? "unknown" : openPorts)
        - Protocol/endpoints: \(protocolNotes.isEmpty ? "unknown" : protocolNotes)

        Notes:
        \(captureNotes.isEmpty ? "none" : captureNotes)

        Reminder: USB-C to PC does not expose iPhone <-> BFA7 temporary Wi-Fi traffic. Prefer passive Wi-Fi capture or a controlled intermediary/hotspot experiment.
        """
    }
}

@MainActor
final class WiFiImportLab: ObservableObject {
    @Published var checklist: WiFiImportChecklist {
        didSet { persist() }
    }

    private let key = "BFA7Bridge.wifiImportChecklist.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(WiFiImportChecklist.self, from: data) {
            checklist = decoded
        } else {
            checklist = WiFiImportChecklist()
        }
    }

    func markUpdated() {
        checklist.lastUpdated = Date()
    }

    func reset() {
        checklist = WiFiImportChecklist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(checklist) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
