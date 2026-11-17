# Reading Live Data

Request values once, stream them, or follow them with Combine.

## Overview

### One request

```swift
let values = try await obdService.requestPIDs([.mode1(.rpm), .mode1(.speed)], unit: .metric)
```

On CAN vehicles, up to ``OBDConfiguration/maxPIDsPerRequest`` PIDs are sent in a single request, with an
automatic fallback for ECUs that do not support it. Use ``MeasurementUnit/imperial`` for mph, °F and psi.

### A stream

``OBDService/liveData(_:unit:interval:)`` polls the vehicle as long as the stream is iterated:

```swift
for try await values in obdService.liveData([.mode1(.rpm), .mode1(.speed)], interval: 0.2) {
    rpm = values[.mode1(.rpm)]?.value ?? 0
}
```

### Combine

``OBDService/startContinuousUpdates(_:unit:interval:)`` publishes the same dictionaries on the main queue.
Polling stops when the subscription is cancelled, and transient errors do not end it.
``OBDService/addPID(_:)`` and ``OBDService/removePID(_:)`` change the polled PIDs while it runs.

### Values that are not numbers

``OBDService/sendCommand(_:unit:)`` returns a ``DecodeResult``, whatever the command returns:

```swift
let fuelType = try await obdService.sendCommand(.mode1(.fuelType)).get().stringResult
let vin = try await obdService.sendCommand(.mode9(.VIN)).get().stringResult
```

### Supported commands

After connecting, ``OBDInfo/supportedPIDs`` lists the service 01 commands the vehicle implements.
``OBDCommand/properties`` gives the description and the expected range of any command, for gauges.
