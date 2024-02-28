###SwiftOBD2

A Swift package for interfacing with vehicles using the ELM327 OBD2 adapter on macOS, iPadOS, and iOS.

##Key Features

Connection Management: Establish reliable connections with your ELM327 adapter over Bluetooth or Wi-Fi.
Command Interface: Send and receive OBD2 commands for powerful interaction with your vehicle.
Trouble Code Scanning: Detect and read diagnostic trouble codes (DTCs) to identify potential issues.
Sensor Monitoring: Retrieve and view data from various vehicle sensors in real time.
Cross-Platform Compatibility: Seamless operation across macOS, iPadOS, and iOS devices.
Installation

The Swift OBD package can be easily integrated into your project using the Swift Package Manager:

In Xcode, navigate to File > Add Packages...
Enter this repository's URL: https://github.com/kkonteh97/SwiftOBD2/
Select the desired dependency rule (version, branch, or commit).
Usage Example

```Swift
import SwiftOBD
import Combine

let obdService = OBDService(connectionType: .bluetooth)

Task {
    do {
        let (protocol, vin) = try await obdService.startConnection()
        print("Connected using protocol: \(protocol), VIN: \(vin ?? "Not Available")")

        // Example of retrieving vehicle speed:
        let speedCommand = OBDCommand.supportedPID(pid: .vehicleSpeed)
        let response = try await obdService.requestPIDs([speedCommand])

        if let speed = response.first?.value {
            print("Current vehicle speed: \(speed)")
        }

        obdService.stopConnection()

    } catch {
        print("Connection error: \(error)")
    }
}
```
##Supported OBD2 Commands

A comprehensive list of supported OBD2 commands will be available in the full documentation (coming soon).

##Contributing

This project welcomes your contributions! Feel free to open issues for bug reports or feature requests. To contribute code:

Fork the repository.
Create your feature branch.
Commit your changes with descriptive messages.
Submit a pull request for review.
License

The Swift OBD package is distributed under the MIT license. See the LICENSE file for more information.



