# Getting Started

Add SwiftOBD2 to an app, declare the permissions it needs and read a first value.

## Overview

### Add the package

In Xcode choose **File › Add Package Dependencies…** and enter the URL of the repository, or add it to the
dependencies of a `Package.swift`:

```swift
.package(url: "https://github.com/kkonteh97/SwiftOBD2", branch: "main")
```

SwiftOBD2 requires iOS 14 or macOS 12 and Swift 5.7.

### Declare the permissions

- **Bluetooth adapters**: add `NSBluetoothAlwaysUsageDescription` to the `Info.plist`. To keep reading data in
  the background, enable the *Uses Bluetooth LE accessories* background mode.
- **Wi-Fi adapters**: add `NSLocalNetworkUsageDescription`. The adapter is reached on its own local network;
  the device must join it first.

### Read a value

```swift
import SwiftOBD2

let obdService = OBDService(connectionType: .bluetooth)

let info = try await obdService.startConnection()
print(info.vin ?? "no VIN", info.obdProtocol?.description ?? "")

let values = try await obdService.requestPIDs([.mode1(.rpm), .mode1(.coolantTemp)])
print(values[.mode1(.rpm)]?.value ?? 0)

obdService.stopConnection()
```

``OBDService/startConnection(preferedProtocol:timeout:)`` connects to the adapter, initialises it, detects the
vehicle protocol and returns an ``OBDInfo``. Values the vehicle does not support are absent from the result.

### Try it without a vehicle

``ConnectionType/demo`` simulates an adapter and a CAN vehicle with an engine and a transmission ECU, trouble
codes and freeze frames. It is ideal for SwiftUI previews and tests.
