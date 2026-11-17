# Diagnostics and Trouble Codes

Read and clear trouble codes, check the readiness monitors, and read freeze frames and on-board test results.

## Overview

### Trouble codes

```swift
let stored = try await obdService.scanForTroubleCodes()            // confirmed codes (service 03)
let pending = try await obdService.scanForTroubleCodes(.pending)   // not confirmed yet (service 07)
let all = try await obdService.scanForAllTroubleCodes()            // stored, pending and permanent

for (ecu, codes) in all {
    for code in codes { print(ecu, code.code, code.kind, code.description) }
}

try await obdService.clearTroubleCodes()                           // service 04
```

Codes are grouped by ``ECUID``. Permanent codes (service 0A) cannot be cleared: the vehicle removes them once
the fault is repaired and the monitor has run again.

### Status since the codes were cleared

``OBDService/getStatusSinceDTCCleared(unit:)`` returns a ``DiagnosticStatus``: malfunction lamp, number of
codes, readiness of every monitor, and the distance, time and warm-ups since the codes were cleared.

```swift
let report = try await obdService.getStatusSinceDTCCleared()
print(report.status.MIL, report.status.isReadyForInspection)
print(report.status.incompleteMonitors.map(\.title))
```

### Freeze frames

``OBDService/getFreezeFrame(_:frame:unit:)`` reads the conditions the ECU recorded when the fault occurred:

```swift
if let frame = try await obdService.getFreezeFrame() {
    print(frame.troubleCode.code, frame.values[.mode1(.rpm)]?.value ?? 0)
}
```

### On-board tests

``OBDService/getMonitorTestResults(unit:)`` returns the results of the tests the vehicle runs on itself
(catalyst, oxygen sensors, EGR…), with their limits. It requires a CAN vehicle (service 06).
``OBDService/requestOnBoardTest(_:data:)`` asks the vehicle to run a test, such as the evaporative system leak
test (service 08).

### Other modules

Non-emission modules (ABS, airbag, body…) usually speak UDS. Describe them with an ``ECUTarget`` and use
``OBDService/scanForTroubleCodes(on:statusMask:)`` and ``OBDService/clearTroubleCodes(on:)``. See
<doc:CustomPIDs>.
