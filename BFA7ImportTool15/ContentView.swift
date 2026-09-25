import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var transport: ImportBLETransport
    @EnvironmentObject private var media: ImportMediaProbe
    @State private var appKey = ""

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

                Section(header: Text("AP trigger")) {
                    TextField("MIWBT appKey, 16 bytes hex", text: $appKey)
                        .font(.body.monospaced())
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)

                    Button("Write AES-CTR AP trigger") {
                        transport.writeAESCTRAPTrigger(appKeyText: appKey)
                    }
                    .disabled(!transport.canWrite)
                    .buttonStyle(.borderedProminent)

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
            .onAppear {
                if !transport.isScanning {
                    transport.startScan()
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
