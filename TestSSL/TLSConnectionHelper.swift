//import Foundation
//import Network
//import Security
//
//enum SomeError: Error {
//    case failedToCreateSecIdentity
//}
//// SecureConnection class implementation
//class SecureConnection {
//    private var connection: NWConnection?
//    private var isConnected = false
//    private let host: String
//    private let port: UInt16
//    private let caPEM: String
//    private let p12Data: Data
//    private let p12Password: String
//    private var reconnectTimer: Timer?
//
//    init(host: String, port: UInt16, caPEM: String, p12Data: Data, p12Password: String) {
//        self.host = host
//        self.port = port
//        self.caPEM = caPEM
//        self.p12Data = p12Data
//        self.p12Password = p12Password
//    }
//
//    func startConnection(statusUpdate: @escaping (String) -> Void) {
//        do {
//            connection = try createSSLConnection()
//            connection?.stateUpdateHandler = { newState in
//                switch newState {
//                case .ready:
//                    self.isConnected = true
//                    statusUpdate("Connected")
//                    self.startSendingMessages()
//                    self.receiveData()
//                case .waiting(let error):
//                    statusUpdate("Waiting: \(error)")
//                case .failed(let error):
//                    statusUpdate("Failed: \(error)")
//                    self.handleDisconnection()
//                case .cancelled:
//                    statusUpdate("Cancelled")
//                    self.handleDisconnection()
//                default:
//                    break
//                }
//            }
//            connection?.start(queue: .main)
//        } catch {
//            print("Failed to establish connection: \(error.localizedDescription)")
//            statusUpdate("Failed to connect")
//        }
//    }
//
//    private func handleDisconnection() {
//        isConnected = false
//        startReconnectTimer() // Start timer to reconnect
//    }
//
//    private func startReconnectTimer() {
//        reconnectTimer?.invalidate() // Invalidate existing timer
//        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
//            print("Attempting to reconnect...")
//            self?.startConnection(statusUpdate: { status in
//                // You can update the UI status here if needed
//            }) // Attempt to reconnect
//        }
//    }
//
//    private func startSendingMessages() {
//        guard isConnected else { return }
//        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] timer in
//            guard let self = self, self.isConnected else {
//                timer.invalidate() // Stop the timer if not connected
//                return
//            }
//            self.sendCoTMessage()
//        }
//    }
//
//    private func sendCoTMessage() {
//        guard let connection = connection else {
//            print("Connection is nil, cannot send CoT message")
//            return
//        }
//        
//        // Get the current date
//        let currentDate = Date()
//        let currentDateString = ISO8601DateFormatter().string(from: currentDate)
//        let staleDate = currentDate.addingTimeInterval(60)
//        let staleDateString = ISO8601DateFormatter().string(from: staleDate)
//
//        // Construct the CoT message
//        let cotMessage = """
//        <?xml version="1.0" encoding="UTF-8"?>
//        <event version="2.0" uid="COT-1234" type="a-f-G-U-C" how="m-g" time="\(currentDateString)" start="\(currentDateString)" stale="\(staleDateString)">
//              <detail>
//                <__group name="Green" role="Team Member"/>
//                <uid Droid="TAKBack"/>
//                <contact callsign="TAKBack" endpoint="*:-1:stcp" email="rbn1206@gmail.com" phone="1234567890"/>
//            </detail>
//          <point lat="34.052235" lon="-118.243683"/>
//        </event>
//        """
//        
//        // Convert the message to data and send it
//        if let messageData = cotMessage.data(using: .utf8) {
//            connection.send(content: messageData, completion: .contentProcessed({ error in
//                if let error = error {
//                    print("Failed to send CoT message: \(error.localizedDescription)")
//                } else {
//                    print("CoT message sent successfully!")
//                    print(cotMessage)
//                }
//            }))
//        } else {
//            print("Failed to encode CoT message")
//        }
//    }
//
//    private func receiveData() {
//        guard let connection = connection else {
//            print("Connection is nil, cannot receive data")
//            return
//        }
//
//        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
//            if let error = error {
//                print("Error receiving data: \(error.localizedDescription)")
//                self?.handleDisconnection()
//            }
//
//            if let data = data, !data.isEmpty {
//                // Log the received data as a string
//                let receivedString = String(data: data, encoding: .utf8) ?? "Received non-UTF8 data"
//                print("Received data: \(receivedString)")
//            }
//
//            if isComplete {
//                print("Connection closed by the server.")
//                self?.handleDisconnection()
//            } else {
//                // Continue receiving more data
//                self?.receiveData()
//            }
//        }
//    }
//
//    // Add your existing helper functions for extracting identities and loading certificates...
//    private func createSSLConnection() throws -> NWConnection {
//        // Load client certificate and private key from .p12
//        let identity = try extractIdentityFromPKCS12(p12Data: p12Data, password: p12Password)
//        print("Client certificate and private key successfully extracted.")
//
//        let caCertificate = try loadCACertificateFromPEM(caPEM: caPEM)
//        print("CA certificate successfully loaded.")
//        
//        // Create TLS options
//        let tlsOptions = NWProtocolTLS.Options()
//        
//        // Convert SecIdentity to sec_identity_t
//        if let secIdentity = sec_identity_create(identity) {
//            // Set the client identity (client cert + private key)
//            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
//        } else {
//            print("Failed to convert SecIdentity to sec_identity_t.")
//            throw SomeError.failedToCreateSecIdentity
//        }
//        
//        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, trust, completionHandler) in
//            completionHandler(true)
//        }, .global())
//
//        // Create NWParameters with TLS options
//        let parameters = NWParameters(tls: tlsOptions)
//
//        // Create a TCP connection with TLS
//        let connection = NWConnection(
//            host: NWEndpoint.Host(host),
//            port: NWEndpoint.Port(rawValue: port)!,
//            using: parameters
//        )
//
//        return connection
//    }
//
//    // Existing helper functions to extract identity and load CA certificate
//    func extractIdentityFromPKCS12(p12Data: Data, password: String) throws -> SecIdentity {
//        var importResult: CFArray?
//        let options = [kSecImportExportPassphrase as String: password]
//        
//        let status = SecPKCS12Import(p12Data as NSData, options as CFDictionary, &importResult)
//        guard status == errSecSuccess else {
//            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
//        }
//        
//        let items = importResult! as! [[String: Any]]
//        let identity = items[0][kSecImportItemIdentity as String] as! SecIdentity
//        return identity
//    }
//
//    func loadCACertificateFromPEM(caPEM: String) throws -> SecCertificate {
//        let caPEMData = caPEM.data(using: .utf8)!
//        var certificates: [SecCertificate] = []
//        
//        var pemComponents = caPEMData.split(separator: "\n-----END CERTIFICATE-----").map(String.init)
//        for component in pemComponents {
//            if let range = component.range(of: "-----BEGIN CERTIFICATE-----") {
//                let certData = Data(component[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "\n", with: "")
//                let cert = SecCertificateCreateWithData(nil, certData as CFData)
//                if let cert = cert {
//                    certificates.append(cert)
//                }
//            }
//        }
//        
//        guard let caCertificate = certificates.first else {
//            throw NSError(domain: "SecureConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load CA certificate from PEM"])
//        }
//        
//        return caCertificate
//    }
//}
