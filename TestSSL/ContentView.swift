import SwiftUI
import Network
import Security
import UniformTypeIdentifiers
import CoreLocation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lastLocation: CLLocation?
    private var locationManager = CLLocationManager()

    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        self.locationManager.allowsBackgroundLocationUpdates = true
        self.locationManager.startUpdatingLocation()

        // Request always authorization for location
        self.locationManager.requestAlwaysAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.lastLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

struct ContentView: View {
    @State private var showFilePicker = false
    @State private var connectionStatus = "Not Connected"
    @State private var timer: Timer? = nil
    @ObservedObject var locationManager = LocationManager()
    
    var body: some View {
        VStack {
            Text(connectionStatus)
                .padding()
            
            Button("Pick Client Certificate (.p12)") {
                showFilePicker.toggle()
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    connectToServer(p12URL: url)
                }
            case .failure(let error):
                print("Failed to pick file: \(error.localizedDescription)")
            }
        }
    }
    
    // Function to request permission to access file at the given URL
    func requestFileAccessPermission(for fileURL: URL) {
        log("Requesting permission for file access at URL: \(fileURL)")
        
        // Ensure access to security-scoped URL (if needed for external files)
        connectToServer(p12URL: fileURL)
    }
    
    // Function to log messages (can be extended to send logs to a server or file)
    func log(_ message: String) {
        print("[LOG] \(message)")
        // Optionally, extend this to log to a file or reporting service
    }
    
    func connectToServer(p12URL: URL) {
            log("Starting connection to server with certificate at URL: \(p12URL)")
            
            // Start accessing security-scoped resource
            guard p12URL.startAccessingSecurityScopedResource() else {
                log("Failed to start accessing security-scoped resource")
                return
            }
            defer { p12URL.stopAccessingSecurityScopedResource() }
            
            // Read the .p12 data
            do {
                let p12Data = try Data(contentsOf: p12URL)
                log("Successfully read the .p12 file")
                
                // Hard-coded CA PEM string
                let caPEM = """
                -----BEGIN CERTIFICATE-----
                MIIDbjCCAlagAwIBAgIJANk04aI+Z+WcMA0GCSqGSIb3DQEBCwUAMGQxCzAJBgNV
                ...
                -----END CERTIFICATE-----
                """
                
                let p12Password = "atakatak" // Use the correct password for the .p12
                
                // Create SecureConnection instance
                let secureConnection = SecureConnection(host: "35.209.203.23", port: 8089, caPEM: caPEM, p12Data: p12Data, p12Password: p12Password, locationManager: locationManager)
                
                // Start the connection
                secureConnection.startConnection { status in
                    // Update the connection status
                    DispatchQueue.main.async {
                        connectionStatus = status
                    }
                }
            } catch {
                log("Failed to read the .p12 file: \(error.localizedDescription)")
            }
        }
    
}

func receiveData(connection: NWConnection?) {
    guard let connection = connection else {
        print("Connection is nil, cannot receive data")
        return
    }
    
    // Set up the receive handler
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, context, isComplete, error in
        if let error = error {
            print("Error receiving data: \(error.localizedDescription)")
        }
        
        if let data = data, !data.isEmpty {
            // Log the received data as a string
            let receivedString = String(data: data, encoding: .utf8) ?? "Received non-UTF8 data"
            print("Received data: \(receivedString)")
        }
        
        if isComplete {
            print("Connection closed by the server.")
            connection.cancel()
        } else {
            // Continue receiving more data
            receiveData(connection: connection)
        }
    }
}


enum SomeError: Error {
    case failedToCreateSecIdentity
}

// SecureConnection class implementation
class SecureConnection {
    private var connection: NWConnection?
    private var isConnected = false
    private let host: String
    private let port: UInt16
    private let caPEM: String
    private let p12Data: Data
    private let p12Password: String
    private var reconnectTimer: Timer?
    private var locationManager: LocationManager

    init(host: String, port: UInt16, caPEM: String, p12Data: Data, p12Password: String, locationManager: LocationManager) {
        self.host = host
        self.port = port
        self.caPEM = caPEM
        self.p12Data = p12Data
        self.p12Password = p12Password
        self.locationManager = locationManager
    }

    func startConnection(statusUpdate: @escaping (String) -> Void) {
        do {
            connection = try createSSLConnection()
            connection?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    self.isConnected = true
                    statusUpdate("Connected")
                    self.startSendingMessages()
                    self.receiveData()
                case .waiting(let error):
                    statusUpdate("Waiting: \(error)")
                case .failed(let error):
                    statusUpdate("Failed: \(error)")
                    self.handleDisconnection()
                case .cancelled:
                    statusUpdate("Cancelled")
                    self.handleDisconnection()
                default:
                    break
                }
            }
            connection?.start(queue: .main)
        } catch {
            print("Failed to establish connection: \(error.localizedDescription)")
            statusUpdate("Failed to connect")
        }
    }

    private func handleDisconnection() {
        isConnected = false
        startReconnectTimer() // Start timer to reconnect
    }

    private func startReconnectTimer() {
        reconnectTimer?.invalidate() // Invalidate existing timer
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            print("Attempting to reconnect...")
            self?.startConnection(statusUpdate: { status in
                // You can update the UI status here if needed
            }) // Attempt to reconnect
        }
    }

    private func startSendingMessages() {
        guard isConnected else { return }
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isConnected else {
                timer.invalidate() // Stop the timer if not connected
                return
            }
            self.sendCoTMessage()
        }
    }

    private func sendCoTMessage() {
        guard let connection = connection else {
            print("Connection is nil, cannot send CoT message")
            return
        }
        
        // Get the current date
        let currentDate = Date()
        let currentDateString = ISO8601DateFormatter().string(from: currentDate)
        let staleDate = currentDate.addingTimeInterval(60)
        let staleDateString = ISO8601DateFormatter().string(from: staleDate)
        
        // Fetch the latest location
        let lat = locationManager.lastLocation?.coordinate.latitude ?? 34.052235
        let lon = locationManager.lastLocation?.coordinate.longitude ?? -118.243683

        // Construct the CoT message with the location
         let cotMessage = """
         <?xml version="1.0" encoding="UTF-8"?>
         <event version="2.0" uid="COT-1234" type="a-f-G-U-C" how="m-g" time="\(currentDateString)" start="\(currentDateString)" stale="\(staleDateString)">
               <detail>
                 <__group name="Green" role="Team Member"/>
                 <uid Droid="TAKBack"/>
                 <contact callsign="TAKBack" endpoint="*:-1:stcp" email="rbn1206@gmail.com" phone="1234567890"/>
             </detail>
           <point lat="\(lat)" lon="\(lon)"/>
         </event>
         """
        
        // Convert the message to data and send it
        if let messageData = cotMessage.data(using: .utf8) {
            connection.send(content: messageData, completion: .contentProcessed({ error in
                if let error = error {
                    print("Failed to send CoT message: \(error.localizedDescription)")
                } else {
                    print("CoT message sent successfully!")
                    print(cotMessage)
                }
            }))
        } else {
            print("Failed to encode CoT message")
        }
    }

    private func receiveData() {
        guard let connection = connection else {
            print("Connection is nil, cannot receive data")
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let error = error {
                print("Error receiving data: \(error.localizedDescription)")
                self?.handleDisconnection()
            }

            if let data = data, !data.isEmpty {
                // Log the received data as a string
                let receivedString = String(data: data, encoding: .utf8) ?? "Received non-UTF8 data"
                print("Received data: \(receivedString)")
            }

            if isComplete {
                print("Connection closed by the server.")
                self?.handleDisconnection()
            } else {
                // Continue receiving more data
                self?.receiveData()
            }
        }
    }

    // Add your existing helper functions for extracting identities and loading certificates...
    private func createSSLConnection() throws -> NWConnection {
        // Load client certificate and private key from .p12
        let identity = try extractIdentityFromPKCS12(p12Data: p12Data, password: p12Password)
        print("Client certificate and private key successfully extracted.")


        print("CA certificate successfully loaded.")
        
        // Create TLS options
        let tlsOptions = NWProtocolTLS.Options()
        
        // Convert SecIdentity to sec_identity_t
        if let secIdentity = sec_identity_create(identity) {
            // Set the client identity (client cert + private key)
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        } else {
            print("Failed to convert SecIdentity to sec_identity_t.")
            throw SomeError.failedToCreateSecIdentity
        }
        
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, trust, completionHandler) in
            completionHandler(true)
        }, .global())

        // Create NWParameters with TLS options
        let parameters = NWParameters(tls: tlsOptions)

        // Create a TCP connection with TLS
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )

        return connection
    }

    // Existing helper functions to extract identity and load CA certificate
    func extractIdentityFromPKCS12(p12Data: Data, password: String) throws -> SecIdentity {
        var importResult: CFArray?
        let options = [kSecImportExportPassphrase as String: password]
        
        let status = SecPKCS12Import(p12Data as NSData, options as CFDictionary, &importResult)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
        
        let items = importResult! as! [[String: Any]]
        let identity = items[0][kSecImportItemIdentity as String] as! SecIdentity
        return identity
    }

}
