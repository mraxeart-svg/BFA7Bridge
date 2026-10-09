import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var transport: ImportBLETransport
    @EnvironmentObject private var media: ImportMediaProbe
    @State private var pairingToken = ""
    @State private var showingCredentialPicker = false
    @State private var credentialName = ""
    @State private var credentialError = false
    @State private var loadingBTCoreCandidate = false
    @State private var credentialErrorMessage = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Connection")) {
                    Text(transport.bluetoothState)
                    Text("Connected: \(transport.connectedName)")
                    Text("Write target: \(transport.writeTarget)")

                    HStack {
                        Button(transport.isScanning ? "Stop scan" : "Start scan") {
                            if transport.isScanning {
                                transport.stopScan()
                            } else {
                                transport.startScan()
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Disconnect") {
                            transport.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(transport.devices) { device in
                        Button(device.label) {
                            transport.connect(device)
                        }
                    }
                }

                Section(header: Text("Import session")) {
                    Text(transport.authStatus)

                    SecureField(
                        transport.hasSavedToken ? "Pairing token saved" : "Pairing token, hex",
                        text: Binding(get: { pairingToken }, set: {
                            pairingToken = $0
                            credentialName = ""
                        })
                    )
                        .font(.body.monospaced())
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)

                    Button {
                        loadingBTCoreCandidate = false
                        showingCredentialPicker = true
                    } label: {
                        Label("Load device record", systemImage: "doc.badge.plus")
                    }
                    Button {
                        loadingBTCoreCandidate = true
                        showingCredentialPicker = true
                    } label: {
                        Label("Load BTCore token", systemImage: "key")
                    }
                    if !credentialName.isEmpty { Text("Credential: \(credentialName)") }

                    Button("Authenticate and open import Wi-Fi") {
                        transport.authenticateAndOpenWiFi(tokenText: pairingToken)
                    }
                    .disabled(!transport.canAuthenticate)
                    .buttonStyle(.borderedProminent)

                    if transport.canOpenWiFi {
                        Button("Request import Wi-Fi again") {
                            transport.openImportWiFi()
                        }
                        .buttonStyle(.bordered)
                    }

                    if transport.hasSavedToken {
                        Button("Forget saved token", role: .destructive) {
                            transport.clearSavedToken()
                            pairingToken = ""
                            credentialName = ""
                        }
                    }

                    if !transport.wifiSSID.isEmpty {
                        Text("SSID: \(transport.wifiSSID)")
                        Text("Gateway: \(transport.wifiGateway)")
                    }

                    Text("Last write: \(transport.lastWrite)")
                        .font(.caption.monospaced())
                    Text("Last notify: \(transport.lastNotify)")
                        .font(.caption.monospaced())
                }

                Section(header: Text("Wi-Fi probe")) {
                    TextField("Glasses IP", text: $media.host)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)

                    Button("Probe HTTP endpoints") {
                        media.probe()
                    }
                    .buttonStyle(.bordered)

                    Text(media.status)
                    Text(media.lastReport.isEmpty ? "No report" : media.lastReport)
                        .font(.caption.monospaced())
                }

                Section(header: Text("Log")) {
                    ForEach(Array(transport.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("BFA7 Import 15")
            .fileImporter(isPresented: $showingCredentialPicker, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 1_048_577) ?? Data()
                    if loadingBTCoreCandidate {
                        let candidate = try MIWBTCoreTokenCandidate.decode(data)
                        pairingToken = candidate.key.importHexString
                        credentialName = "BTCore token (unverified)"
                    } else {
                        let record = try MIWPairingRecord.decode(data)
                        pairingToken = record.key.importHexString
                        credentialName = record.name
                    }
                } catch {
                    credentialErrorMessage = loadingBTCoreCandidate
                        ? MIWBTCoreTokenCandidate.CandidateError.invalid.localizedDescription
                        : MIWPairingRecord.RecordError.invalid.localizedDescription
                    credentialError = true
                }
            }
            .alert("Credential not loaded", isPresented: $credentialError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(credentialErrorMessage)
            }
            .onAppear {
                if !transport.isScanning {
                    transport.startScan()
                }
            }
            .onChange(of: transport.wifiGateway) { gateway in
                if !gateway.isEmpty {
                    media.host = gateway
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
