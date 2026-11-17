# ``SwiftOBD2``

Talk to a vehicle through an ELM327 adapter: live data, diagnostics, manufacturer specific data and data logging.

## Overview

SwiftOBD2 connects to an ELM327 compatible OBD-II adapter over Bluetooth Low Energy or Wi-Fi, detects the
protocol of the vehicle and gives you typed, decoded values:

```swift
import SwiftOBD2

let obdService = OBDService(connectionType: .wifi)   // or .bluetooth, or .demo
let info = try await obdService.startConnection()

for try await values in obdService.liveData([.mode1(.rpm), .mode1(.speed)]) {
    print(values[.mode1(.rpm)]?.value ?? 0)
}
```

Everything goes through ``OBDService``. Standard requests are described by ``OBDCommand``; anything else
(manufacturer PIDs, UDS identifiers, other ECUs) by a ``CustomCommand``. ``OBDDataLogger`` records any mix of
them.

The library handles every protocol an ELM327 can speak: SAE J1850 PWM/VPW, ISO 9141-2, ISO 14230-4 (KWP2000),
ISO 15765-4 (CAN, 11 and 29 bit) and user defined CAN. SAE J1939 is available for raw requests only. Vehicles
built before OBD-II (OBD-I) use connectors and protocols an ELM327 cannot speak, so they are out of reach.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Connecting>
- ``OBDService``
- ``OBDConfiguration``
- ``ConnectionType``
- ``ConnectionState``
- ``OBDInfo``

### Reading Data

- <doc:ReadingData>
- ``OBDCommand``
- ``MeasurementResult``
- ``MeasurementUnit``
- ``DecodeResult``

### Diagnostics

- <doc:Diagnostics>
- ``TroubleCode``
- ``TroubleCodeKind``
- ``DiagnosticStatus``
- ``Status``
- ``StatusTest``
- ``FreezeFrame``
- ``Monitor``
- ``MonitorTest``

### Manufacturer Specific Data

- <doc:CustomPIDs>
- ``CustomCommand``
- ``ECUTarget``
- ``Formula``
- ``Message``
- ``ECUID``

### Data Logging

- <doc:DataLogging>
- ``OBDDataLogger``

### Errors

- ``OBDServiceError``
- ``ELM327Error``
- ``CommunicationError``
- ``DecodeError``
- ``FormulaError``

### Migrating

- <doc:Migration>
