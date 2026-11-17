# Manufacturer Specific Data

Read PIDs that are not part of the standard, from any module, with a request and a formula.

## Overview

Standard OBD-II only covers emission related data. Gearbox temperature, boost pressure or DPF load are
manufacturer specific, but nearly always follow the same pattern: a request sent to one ECU, and a formula
applied to the answer. That is what a ``CustomCommand`` describes.

```swift
let oilTemperature = OBDCommand.custom(CustomCommand(
    name: "Oil temperature",
    request: "221154",   // UDS ReadDataByIdentifier 0x1154
    formula: "A-40",     // A is the first data byte of the answer, B the second…
    unit: "°C",
    header: "7E0"        // the ECU to ask; omit it to broadcast like a standard PID
))

let values = try await obdService.requestPIDs([oilTemperature, .mode1(.rpm)])
```

Custom commands work wherever standard ones do: requests, streams, Combine and ``OBDDataLogger``.

> Note: Identifiers differ between manufacturers, models and even model years. The library ships the
> mechanism, not a database of manufacturer PIDs.

### Formulas

A ``Formula`` uses the usual Torque syntax:

- bytes `A` to `Z`, then `AA`, `AB`…; single bits with `{A:3}`;
- operators `+ - * / % ^`, bit operators `& | << >>` and parentheses;
- functions `SIGNED(A)`, `SIGNED16(A,B)`, `SIGNED32(…)`, `INT16(A,B)`, `UINT16(A,B)`, `BIT(A,n)`, `ABS`, `MIN`,
  `MAX`.

```swift
let formula = try Formula("(A*256+B)/4")
let rpm = try formula.evaluate([0x1A, 0xF8])   // 1726
```

### Importing PID lists

Community PID lists in the Torque CSV format can be imported as they are:

```swift
let text = try String(contentsOf: csvURL, encoding: .utf8)
let commands = CustomCommand.parseCSV(text).map(OBDCommand.custom)
```

### Addressing other modules

An ``ECUTarget`` describes how to reach a module: its request header, the address of its answers, and any
adapter commands it needs before and after the request (extended addressing, wake-up messages…).

```swift
let abs = ECUTarget(header: "760", receiveAddress: "768")
let answers = try await obdService.request("22F190", to: abs)   // payload starts with 62 F1 90
let codes = try await obdService.scanForTroubleCodes(on: abs)   // UDS service 19
```

``OBDService/request(_:to:)`` returns raw ``Message`` values for anything a formula cannot express. Refused requests
throw ``OBDServiceError/commandFailed(command:error:)``, with ``ELM327Error/negativeResponse(service:code:)`` as
underlying error to tell why.
