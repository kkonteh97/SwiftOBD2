# Connecting to an Adapter

Choose the transport, tune the adapter settings and follow the connection state.

## Overview

### Bluetooth Low Energy

```swift
let obdService = OBDService(connectionType: .bluetooth)
let info = try await obdService.startConnection()
```

The first compatible adapter found is used. ``OBDService/scanForPeripherals()`` and
``OBDService/connectToPeripheral(peripheral:)`` let you pick one yourself.

### Wi-Fi

Most Wi-Fi adapters create their own network and listen on `192.168.0.10`, port `35000`. Join that network
in the system settings, then:

```swift
let obdService = OBDService(connectionType: .wifi)                    // default address
let other = OBDService(wifiHost: "192.168.4.1", wifiPort: 35000)       // another adapter
```

The address can also be changed later through ``OBDService/configuration``; the connection is then closed.

### Adapter settings

``OBDConfiguration`` gathers the time-outs and polling optimisations:

```swift
var configuration = OBDConfiguration(wifiHost: "192.168.0.10")
configuration.commandTimeout = 3
configuration.maxPIDsPerRequest = 6           // PIDs grouped in a single request on CAN vehicles
configuration.stopsAfterFirstResponse = true  // faster, when a single ECU answers
let obdService = OBDService(connectionType: .wifi, configuration: configuration)
```

### Protocol detection

``OBDService/startConnection(preferedProtocol:timeout:)`` tries the preferred ``PROTOCOL`` first, then lets
the adapter search, then tries every protocol in turn. Passing the protocol of a known vehicle makes the
connection faster.

### Connection state

``OBDService/connectionState`` is published, so SwiftUI views can follow it:

```swift
obdService.$connectionState
    .sink { state in print(state.description) }
    .store(in: &cancellables)
```

When the ignition is off, connecting throws ``OBDServiceError/adapterConnectionFailed(underlyingError:)`` with
``ELM327Error/unableToConnect`` as underlying error.
