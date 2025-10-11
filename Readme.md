![Header](https://github.com/kkonteh97/SwiftOBD2/blob/main/Sources/Assets/github-header-image.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/kkonteh97/SwiftOBD2/blob/main/LICENSE) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com) ![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20-lightgrey) ![Swift Version](https://img.shields.io/badge/swift-5.0-orange) ![iOS Version](https://img.shields.io/badge/iOS-^14.0-blue) ![macOS Version](https://img.shields.io/badge/macOS-11.0%20%7C%2012.0-blue)

[![GitHub stars](https://img.shields.io/github/stars/kkonteh97/SwiftOBD2?style=social)](https://github.com/kkonteh97/SwiftOBD2/stargazers) [![GitHub forks](https://img.shields.io/github/forks/kkonteh97/SwiftOBD2?style=social)](https://github.com/kkonteh97/SwiftOBD2/network/members)

## 🌟 Show Your Support

**⭐ Star this repo** if you find SwiftOBD2 useful! Your support helps the project grow and reach more developers.

[![GitHub contributors](https://img.shields.io/github/contributors/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/graphs/contributors) [![GitHub issues](https://img.shields.io/github/issues/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/issues) [![GitHub last commit](https://img.shields.io/github/last-commit/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/commits/main)

------------


SwiftOBD2 is a Swift package designed to simplify communication with vehicles using an ELM327 OBD2 adapter. It provides a straightforward and powerful interface for interacting with your vehicle's onboard diagnostics system, allowing you to retrieve real-time data and perform diagnostics. [Sample App](https://github.com/kkonteh97/SwiftOBD2App).

## 🚗 See It In Action

> **Demo coming soon!** We're preparing a comprehensive demo video showcasing real-time vehicle data retrieval, DTC scanning, and more.

### Screenshots
- Real-time RPM, Speed, and Engine Load monitoring
- Diagnostic Trouble Code (DTC) scanning and clearing
- Live sensor data visualization
- Bluetooth connection management

*Screenshots and demo GIF will be added in the next release*

## ⚡ Quick Start

Get up and running in 2 minutes:

```swift
// 1. Add to your project via Swift Package Manager
// File > Add Packages... > https://github.com/kkonteh97/SwiftOBD2

// 2. Import and connect
import SwiftOBD2

let obdService = OBDService(connectionType: .bluetooth)
let obd2Info = try await obdService.startConnection()

// 3. Get real-time data
obdService.startContinuousUpdates([.mode1(.rpm), .mode1(.speed)])
    .sink { measurements in
        print("RPM: \(measurements[.mode1(.rpm)]?.value ?? 0)")
        print("Speed: \(measurements[.mode1(.speed)]?.value ?? 0)")
    }
```

**Expected Output:**
```
RPM: 2150.0 
Speed: 65.0
```

### Requirements

- iOS 14.0+ / macOS 11.0+
- Xcode 13.0+
- Swift 5.0+

### Key Features

* Connection Management:
    * Establishes connections to the OBD2 adapter via Bluetooth or Wi-Fi.
    * Handles the initialization of the adapter and the vehicle connection process.
    * Manages connection states (disconnected, connectedToAdapter, connectedToVehicle).
    
* Command Interface:
    * Send and receive OBD2 commands for powerful interaction with your vehicle.
    
* Data Retrieval:
    * Supports requests for real-time vehicle data (RPM, speed, etc.) using standard OBD2 PIDs (Parameter IDs).
    * Provides functions to continuously poll and retrieve updated measurements.
    * Can get a list of supported PIDs from the vehicle.
    
* Diagnostics:
    * Retrieves and clears diagnostic trouble codes (DTCs).
    * Gets the overall status of the vehicle's onboard systems.
    
* Sensor Monitoring:
    * Retrieve and view data from various vehicle sensors in real time.
    
* Adaptability and Configuration
    * Can switch between Bluetooth and Wi-Fi communication seamlessly.
    * Allows for testing and development with a demo mode.
    

### Roadmap

- [x] Connect to an OBD2 adapter via Bluetooth Low Energy (BLE) 
- [x] Retrieve error codes (DTCs) stored in the vehicle's OBD2 system
- [x] Retrieve various OBD2 Parameter IDs (PIDs) for monitoring vehicle parameters
- [x] Retrieve real-time vehicle data (RPM, speed, etc.) using standard OBD2 PIDs
- [x] Get supported PIDs from the vehicle
- [x] Clear error codes (DTCs) stored in the vehicle's OBD2 system
- [ ] Run tests on the OBD2 system
- [ ] Retrieve vehicle status since DTCs cleared
- [ ] Connect to an OBD2 adapter via WIFI
- [ ] Add support for custom PIDs
    
    
### Setting Up a Project

1. Create a New Swift Project:
    * Open Xcode and start a new iOS project (You can use a simple "App" template).

2. Add the SwiftOBD2 Package:
    * In Xcode, navigate to File > Add Packages...
    * Enter this repository's URL: https://github.com/kkonteh97/SwiftOBD2/
    * Select the desired dependency rule (version, branch, or commit).

3. Permissions and Capabilities:
    * If your app will use Bluetooth, you need to request the appropriate permissions and capabilities:
        * Add NSBluetoothAlwaysUsageDescription to your Info.plist file with a brief description of why your app needs to use Bluetooth.
        * Navigate to the Signing & Capabilities tab in your project settings and add the Background Modes capability. Enable the Uses Bluetooth LE Accessories option.
        
### Key Concepts

* SwiftUI & Combine: Your code leverages the SwiftUI framework for building the user interface and Combine for reactive handling of updates from the OBDService.
* OBDService: This is the core class within the SwiftOBD2 package. It handles communication with the OBD-II adapter and processes data from the vehicle.
* OBDServiceDelegate: This protocol is crucial for receiving updates about the connection state and other events from the OBDService.
* OBDCommand: These represent specific requests you can make to the vehicle's ECU (Engine Control Unit) for data.

### Usage

1. Import and Setup
    * Begin by importing the necessary modules:


```Swift
import SwiftUI
import SwiftOBD2
import Combine
```

2. ViewModel
    * Create a ViewModel class that conforms to the ObservableObject protocol. This allows your SwiftUI views to observe changes in the ViewModel.
    * Inside the ViewModel:
        * Define a @Published property measurements to store the collected data.
        * Initialize an OBDService instance, setting the desired connection type (e.g., Bluetooth, Wi-Fi).

3. Connection Handling
    * Implement the connectionStateChanged method from the OBDServiceDelegate protocol. Update the UI based on connection state changes (disconnected, connected, etc.) or handle any necessary logic.
    
4. Starting the Connection
    * Create a startConnection function (ideally using async/await) to initiate the connection process with the OBD-II adapter. The OBDService's startConnection method will return useful OBDInfo about the vehicle. Like the Supported PIDs, Protocol, etc.
    
5. Stopping the Connection
    * Create a stopConnection function to cleanly disconnect the service.
    
6. Retrieving Information
    * Use the OBDService's methods to retrieve data from the vehicle, such as getting the vehicle's status, scanning for trouble codes, or requesting specific PIDs.
        * getTroubleCodes: Retrieve diagnostic trouble codes (DTCs) from the vehicle's OBD-II system.
        * getStatus: Retrieves Status since DTCs cleared.

7. Continuous Updates
    * Use the startContinuousUpdates method to continuously poll and retrieve updated measurements from the vehicle. This method returns a Combine publisher that you can subscribe to for updates.
    * Can also add PIDs to the continuous updates using the addPID method.
    
### Code Example
```Swift
class ViewModel: ObservableObject {
    @Published var measurements: [OBDCommand: MeasurementResult] = [:]
    @Published var connectionState: ConnectionState = .disconnected

    var cancellables = Set<AnyCancellable>()
    var requestingPIDs: [OBDCommand] = [.mode1(.rpm)] {
        didSet {
            addPID(command: requestingPIDs[-1])
        }
    }
    
    init() {
        obdService.$connectionState
            .assign(to: &$connectionState)
    }

    let obdService = OBDService(connectionType: .bluetooth)

    func startContinousUpdates() {
        obdService.startContinuousUpdates([.mode1(.rpm)]) // You can add more PIDs
            .sink { completion in
                print(completion)
            } receiveValue: { measurements in
                self.measurements = measurements
            }
            .store(in: &cancellables)
    }

    func addPID(command: OBDCommand) {
        obdService.addPID(command)
    }

    func stopContinuousUpdates() {
        cancellables.removeAll()
    }

    func startConnection() async throws  {
        let obd2info = try await obdService.startConnection(preferedProtocol: .protocol6)
        print(obd2info)
    }

    func stopConnection() {
        obdService.stopConnection()
    }

    func switchConnectionType() {
        obdService.switchConnectionType(.wifi)
    }

    func getStatus() async {
        let status = try? await obdService.getStatus()
        print(status ?? "nil")
    }

    func getTroubleCodes() async {
        let troubleCodes = try? await obdService.scanForTroubleCodes()
        print(troubleCodes ?? "nil")
    }
}

struct ContentView: View {
    @ObservedObject var viewModel = ViewModel()
    var body: some View {
        VStack(spacing: 20) {
            Text("Connection State: \(viewModel.connectionState.rawValue)")
            ForEach(viewModel.requestingPIDs, id: \.self) { pid in
                Text("\(pid.properties.description): \(viewModel.measurements[pid]?.value ?? 0) \(viewModel.measurements[pid]?.unit.symbol ?? "")")
            }
            Button("Connect") {
                Task {
                    do {
                        try await viewModel.startConnection()
                        viewModel.startContinousUpdates()
                    } catch {
                        print(error)
                    }
                }
            }
            .buttonStyle(.bordered)

            Button("Stop") {
                viewModel.stopContinuousUpdates()
            }
            .buttonStyle(.bordered)

            Button("Add PID") {
                viewModel.requestingPIDs.append(.mode1(.speed))
            }
        }
        .padding()
    }
}

```

### Supported OBD2 Commands

A comprehensive list of supported OBD2 commands will be available in the full documentation (coming soon).

## 🛠️ Troubleshooting

### Common Issues

**Q: Bluetooth connection fails**
- Ensure Bluetooth permissions are granted in iOS Settings
- Verify your ELM327 adapter is in pairing mode
- Try restarting Bluetooth on your device

**Q: No data received from vehicle**
- Check that your vehicle is OBD2 compatible (1996+ in US)
- Ensure the ELM327 adapter is properly connected to the OBD2 port
- Verify the vehicle is running (some data requires engine on)

**Q: App crashes on connection**
- Update to the latest version of SwiftOBD2
- Check that you've added required Bluetooth permissions to Info.plist

### Hardware Compatibility

✅ **Tested ELM327 Adapters:**
- BAFX Products Bluetooth OBD2
- OBDLink MX+ Bluetooth
- VEEPEAK Mini WiFi OBD2

⚠️ **Known Issues:**
- Some cheap ELM327 clones may have connectivity issues
- WiFi adapters require network configuration

### Getting Help

- 📋 [Open an issue](https://github.com/kkonteh97/SwiftOBD2/issues) for bug reports
- 💡 [Start a discussion](https://github.com/kkonteh97/SwiftOBD2/discussions) for questions
- 📱 Check out the [sample app](https://github.com/kkonteh97/SwiftOBD2App) for implementation examples

### Important Considerations

* Ensure you have a compatible ELM327 OBD2 adapter.
* Permissions: If using Bluetooth, your app may need to request Bluetooth permissions from the user.
* Error Handling:  Implement robust error handling mechanisms to gracefully handle potential communication issues.
* Background Updates (Optional): If your app needs background OBD2 data updates, explore iOS background fetch capabilities and fine-tune your library and app to work effectively in the background.


## Contributing

This project welcomes your contributions! Feel free to open issues for bug reports or feature requests. To contribute code:

1. Fork the repository.
2. Create your feature branch.
3. Commit your changes with descriptive messages.
4. Submit a pull request for review.

## License

The Swift OBD package is distributed under the MIT license. See the [LICENSE](https://github.com/kkonteh97/SwiftOBD2/blob/main/LICENSE) file for more details.

---

## 💖 Support the Project

Love SwiftOBD2? Here's how you can help:

- ⭐ **Star this repository** - It really makes a difference!
- 🐛 **Report bugs** - Help us improve by reporting issues
- 💡 **Suggest features** - Share your ideas for new functionality  
- 🔀 **Contribute code** - Submit PRs for fixes and enhancements
- 📢 **Spread the word** - Share with other iOS/Swift developers

**Current Stars: 106+ and growing! 🚀**

[![Star History Chart](https://api.star-history.com/svg?repos=kkonteh97/SwiftOBD2&type=Date)](https://star-history.com/#kkonteh97/SwiftOBD2&Date)

### Related Projects

- [SwiftOBD2App](https://github.com/kkonteh97/SwiftOBD2App) - Sample iOS app demonstrating SwiftOBD2
- Want your project listed here? Open a PR!
