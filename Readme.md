![Header](https://github.com/kkonteh97/SwiftOBD2/blob/main/Sources/Assets/github-header-image.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/kkonteh97/SwiftOBD2/blob/main/LICENSE) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com) ![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20-lightgrey) ![Swift Version](https://img.shields.io/badge/swift-5.0-orange) ![iOS Version](https://img.shields.io/badge/iOS-^14.0-blue) ![macOS Version](https://img.shields.io/badge/macOS-11.0%20%7C%2012.0-blue)

[![GitHub stars](https://img.shields.io/github/stars/kkonteh97/SwiftOBD2?style=social)](https://github.com/kkonteh97/SwiftOBD2/stargazers) [![GitHub forks](https://img.shields.io/github/forks/kkonteh97/SwiftOBD2?style=social)](https://github.com/kkonteh97/SwiftOBD2/network/members)

## 🌟 Show Your Support

**⭐ Star this repo** if you find SwiftOBD2 useful! Your support helps the project grow and reach more developers.

[![GitHub contributors](https://img.shields.io/github/contributors/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/graphs/contributors) [![GitHub issues](https://img.shields.io/github/issues/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/issues) [![GitHub last commit](https://img.shields.io/github/last-commit/kkonteh97/SwiftOBD2)](https://github.com/kkonteh97/SwiftOBD2/commits/main)

------------

SwiftOBD2 is a Swift package designed to simplify communication with vehicles using an ELM327 OBD2 adapter. It provides a straightforward and powerful interface for interacting with your vehicle's onboard diagnostics system, allowing you to retrieve real-time data, perform diagnostics, and monitor raw CAN bus frames. [Sample App](https://github.com/kkonteh97/SwiftOBD2App).

## 🚗 See It In Action

> **Demo coming soon!** We're preparing a comprehensive demo video showcasing real-time vehicle data retrieval, DTC scanning, and more.

### Screenshots
- Real-time RPM, Speed, and Engine Load monitoring
- Diagnostic Trouble Code (DTC) scanning and clearing
- Live sensor data visualization
- Bluetooth and USB Serial connection management

*Screenshots and demo GIF will be added in the next release*

## ⚡ Quick Start

Get up and running in 2 minutes:

```swift
import SwiftOBD2

let obdService = OBDService(connectionType: .bluetooth)
let obd2Info = try await obdService.startConnection()

obdService.startContinuousUpdates([.mode1(.rpm), .mode1(.speed)])
    .sink { measurements in
        print("RPM: \(measurements[.mode1(.rpm)]?.value ?? 0)")
    }
```

### Requirements

- iOS 14.0+ / macOS 11.0+
- Xcode 13.0+
- Swift 5.0+

---

## Key Features

### Connection Management

- Connects to ELM327 adapters via **Bluetooth LE**, **Wi-Fi (TCP)**, or **USB Serial**.
- Handles full adapter initialisation (reset, echo off, header on, auto-protocol) and vehicle handshake automatically.
- Manages connection states: `disconnected`, `connecting`, `connectedToAdapter`, `connectedToVehicle`, `error`.
- Exposes both `@Published` Combine properties and lightweight Swift closure callbacks so integrators can choose the reactive model that suits them.

### USB Serial Support

Two platform-native serial backends have been added, replacing the previous demo mode placeholder:

**iOS — MFi USB Serial (`SerialManager`)**

Connects to MFi-certified USB OBD adapters (e.g. OBDLink EX) using Apple's ExternalAccessory framework over the `com.scantool.stnobd` protocol string. The adapter must be physically connected via USB-C or Lightning before calling `startConnection`. No scanning step is required — the adapter is enumerated directly from the list of connected accessories.

**macOS — POSIX Serial (`MacSerialManager`)**

Connects to any USB-to-serial OBD adapter exposed as a `/dev/tty.*` device, using POSIX file descriptors and `termios` directly. The device path is read from `ConfigurationService.shared.serialPath`. On connect the manager automatically probes baud rates in the order 115200 → 38400 → 57600 → 9600, confirming each by checking whether the adapter returns printable ASCII. The first rate that produces a valid response is used and logged; the connection fails cleanly if none does. Both backends feed into the same `ELM327` initialisation flow as BLE and Wi-Fi.

### Wi-Fi Improvements

- Host and port are now fully configurable via `ConfigurationService.shared.wifiHost` and `.wifiPort` rather than being hardcoded. The defaults remain `192.168.0.10` and `35000`.
- `ATZ` (adapter reset) is handled specially: the command is sent fire-and-forget, the TCP connection is cancelled, the manager waits 1.5 seconds for the adapter to reboot, then reconnects transparently and returns a synthetic `ELM327 v2.1` so the init sequence continues without error. This fixes a class of timeout failures seen with common Wi-Fi ELM327 clones that drop the TCP socket on reset.
- The TCP receive loop now accumulates multiple chunks until the ELM327 `>` prompt arrives, fixing truncation on responses that span more than one TCP segment.
- A `ResumeOnce` gate ensures that exactly one resume fires even when the 15-second hard-deadline timeout races with a normal receive callback.

### CAN Bus Monitor Mode

`sendMonitorCommand(_ command: String, duration: TimeInterval)` is a new method on `OBDService` that puts the ELM327 into streaming monitor mode (e.g. `AT MA` — monitor all, or `AT MT hh` — monitor for header `hh`) for a fixed duration and returns all captured CAN frames as an array of hex strings. Each transport handles this differently:

- **BLE**: sets a `monitorMode` flag on the message processor so that a timeout returns accumulated data instead of throwing. After the duration a bare carriage return is sent to stop monitoring and the resulting `STOPPED>` acknowledgment is drained before returning, preventing it from corrupting the next regular command.
- **Wi-Fi**: performs a single send-and-receive with a generous timeout.
- **Serial**: reads from the file descriptor until the duration expires.

This capability enables passive CAN bus observation and forms the foundation for proprietary protocol work where raw frame capture is needed alongside standard OBD diagnostics.

### Protocol Switching

`switchProtocol(_ proto: PROTOCOL)` switches the ELM327 to a different CAN protocol (sends `ATSPn` and reasserts `ATH1`) without dropping the Bluetooth or serial connection. This is useful when a vehicle has multiple CAN buses operating on different protocols — the app layer can switch mid-session to target a specific bus.

### UDS Diagnostic Trouble Codes (Service $19)

`scanForUDSDTCs(header: String)` sends UDS Service $19 subfunction $02 (Read DTC by Status Mask, all statuses) to a specific ECU identified by its 11-bit or 29-bit CAN header. This extends DTC coverage beyond the standard OBD Mode 03 to manufacturer-specific ECUs that respond to UDS but not OBD. The response is parsed as 4-byte DTC groups (two DTC bytes, one status byte, one filler) and returned as the same `TroubleCode` type used by the standard scan. A new `ECUID.becm` case (raw value `0x04`) has been added to the ECU identifier enumeration for Battery ECU targeting.

### Expanded Mode 1 PID Coverage

Mode 1 now covers the full SAE J1979 PID space from `0x00` through `0xC8`. The additions include:

- **PID group D (0x60–0x7F)**: driver and actual engine torque, reference torque, turbocharger RPM and temperatures, boost pressure control, VGT, wastegate, exhaust pressure, charge air cooler temperature, exhaust gas temperature (EGT) banks 1 and 2, DPF differential pressure, DPF status and temperature, NOx NTE and PM NTE control area status, total engine run time.
- **PID group E (0x80–0x9F)**: AECD run-time counters (up to 20 entries), NOx sensor concentration, manifold surface temperature, NOx reagent system, PM sensor banks 1 and 2, intake manifold pressure (secondary), SCR inducement system, diesel aftertreatment, wide-range O2 sensor, throttle position G, engine friction torque, WWH-OBD vehicle information and counters, fuel system control, NOx warning and inducement system.
- **PID group F / G (0xA0–0xC8)**: NOx sensor corrected concentrations, per-cylinder fuel rate, evap system pressure (alternate), transmission actual gear, commanded DEF dosing, odometer, NOx sensor concentrations at banks 3 and 4, ABS disable switch, fuel level inputs A and B, exhaust particulate diagnostics, fuel pressure A and B, particulate control status, distance since ECU reflash, NOx/PM warning lamp state.

All new PIDs carry the appropriate `CommandProperties` entries (mode byte, description, expected byte count, decoder type, and a flag indicating whether the PID needs vehicle-running conditions).

### Decoder Reliability Improvements

- **`minBytes` guard on UAS multi-byte decoders**: many vehicles return a single-byte default response (`0x11`) for unsupported Mode 1 PIDs. All UAS decoder entries for physically meaningful quantities that require at least 2 bytes (RPM, speed, voltage, duration, resistance, temperature, pressure, angle, ratio, frequency, distance) now carry `minBytes: 2` and return `.failure(.noData)` instead of decoding the garbage byte as a real value.
- **Safe subscript extension**: a `subscript(safe:)` extension on `Collection` prevents out-of-bounds crashes when bit-array operations or decoder index arithmetic runs against unexpectedly short responses.
- **`CVNDecoder`**: a new decoder for Mode 9 Calibration Verification Numbers (CVN), used to verify ECU software integrity.
- **`UAS` entry 0x34**: adds `UnitDuration.minutes` support for elapsed-time quantities that return values in minutes.
- **`CommandProperties.decode`**: the spurious `.dropFirst()` that was stripping the first payload byte before decoding has been removed. All decoders now receive the full data slice.
- **`FuelTypeDecoder` and `MaxMafDecoder`**: now use the safe subscript rather than direct index access to guard against empty response data.
- **`MonitorDecoder`**: converts `Data` to `[UInt8]` before indexed access, avoiding `Data` index-offset pitfalls.

### BLE Reliability Improvements

**Scan and connection lifecycle**

- `ConnectionState` now conforms to `Equatable`, enabling a `removeDuplicates()` operator in the Combine state publisher so consumers do not receive redundant state updates on reconnect cycles.
- Bluetooth power-on no longer auto-connects to a previously seen peripheral. Scanning is now always initiated explicitly by the caller, giving the app layer full control over when peripheral discovery begins.
- A new `connectionInProgress` guard prevents stacking a second connection attempt on top of one already in flight; the attempt throws `BLEManagerError.connectionInProgress` immediately rather than silently racing.
- State restoration (CoreBluetooth background reconnect) no longer promotes a restored peripheral to the managed slot automatically. Instead, restored peripherals are added to the discovered list so they appear in the UI, and the user chooses whether to connect. This prevents silent reconnects to a previously paired adapter the user may have switched away from.
- `peripheralManager.reset()` is now called on connection failure to clear the peripheral delegate and any pending completion handlers, so a retry starts from a clean baseline.

**Device Information Service**

On GATT service discovery the handler now reads all characteristics from the standard Bluetooth Device Information Service (UUID `0x180A`). Manufacturer name, model number, serial number, hardware revision, firmware revision, software revision, system ID, and IEEE certification are all decoded and published via the `adapterInfoUpdated` delegate callback and the `adapterInfo: [String: String]` published property on `OBDService`. Binary characteristics (System ID and IEEE cert) are formatted as colon-separated or space-separated hex.

**ISSC/Microchip Transparent UART**

The ISSC service (UUID `49535343-FE7D-...`) and its TX/RX characteristics are now explicitly recognised and gracefully skipped rather than generating unknown-characteristic warnings. This removes spurious log noise when connecting to adapters based on RN4870 or ISP1807 Bluetooth modules.

**Concurrent command assertion**

The assertion that guards against concurrent BLE commands is now handled through Swift's structured concurrency task cancellation handler, which correctly resolves the continuation when a task is cancelled rather than leaving it dangling.

### Logging System

A structured logging pipeline has been added end-to-end:

- `OBDServiceDelegate` gains a `logMessage(_ message: String)` method with a default no-op implementation so existing conformances don't need to change.
- `OBDService` exposes an `onLog: ((String) -> Void)?` closure for apps that do not adopt the delegate pattern.
- Every step of the ELM327 initialisation sequence (`ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH1`, `ATSP0`) emits a log message with the raw response.
- Protocol detection emits messages at each stage: preferred protocol test, ATSP0, 0100, ATDPN query, and final result (including whether the detected protocol passed the 0100 validation test).
- All OBD commands can be logged via `ConfigurationService.shared.obdCommandLogging = true`, which causes every `sendCommand` call to emit `CMD <cmd> → <response>` to both the system log and the `onLog` callback.
- Serial verbose logging is gated separately via `ConfigurationService.shared.serialVerboseLogging`.

This makes it straightforward to surface a live connection log in the UI, which is particularly valuable during development and for diagnosing adapter compatibility issues with unfamiliar vehicles.

### `ConfigurationService` Expanded

`ConfigurationService.shared` is now `public static let` (was `static var`) and all properties are public. New settings:

| Property | Key | Default | Description |
|---|---|---|---|
| `wifiHost` | `wifiHost` | `192.168.0.10` | Wi-Fi adapter IP address |
| `wifiPort` | `wifiPort` | `35000` | Wi-Fi adapter TCP port |
| `serialPath` | `serialPath` | `""` | macOS serial device path (e.g. `/dev/tty.usbserial-110`) |
| `serialVerboseLogging` | `serialVerboseLogging` | `false` | Log every byte read/written on serial |
| `obdCommandLogging` | `obdCommandLogging` | `false` | Log every OBD command and response |

All values are persisted in `UserDefaults.standard`.

### `OBDService` New Public API

**Published properties**

- `peripherals: [CBPeripheral]` — updated in real time as BLE discovery finds adapters. Drives any adapter picker UI directly.
- `adapterInfo: [String: String]` — key/value map of device information characteristics read from the connected adapter's GATT Device Information Service.

**Closure callbacks**

In addition to the `OBDServiceDelegate` protocol, `OBDService` now exposes plain Swift closures for integrators that prefer a callback model over delegation:

- `onConnectionStateChanged: ((ConnectionState) -> Void)?`
- `onPeripheralsUpdated: (([CBPeripheral]) -> Void)?`
- `onScanningChanged: ((Bool) -> Void)?`
- `onAdapterInfoUpdated: (([String: String]) -> Void)?`
- `onLog: ((String) -> Void)?`

**New methods**

- `startConnection(preferedProtocol:timeout:peripheral:)` — the `peripheral` parameter lets the caller connect directly to a specific `CBPeripheral` (e.g. one chosen from a scan list) rather than relying on the default scan-and-first-found behaviour.
- `switchProtocol(_ proto: PROTOCOL)` — switches the ELM327 CAN protocol mid-session without disconnecting.
- `scanForUDSDTCs(header: String)` — reads DTCs from a specific ECU using UDS Service $19.
- `sendMonitorCommandInternal(_ command: String, duration: TimeInterval)` — exposes the monitor-mode capture path.

**`VINInfo`** gains an optional `Trim` field decoded from the NHTSA VIN lookup response.

### `CommProtocol` Refactored

The `CommProtocol` protocol and `CommunicationError` enum have been moved from `wifiManager.swift` into their own file (`CommProtocol.swift`). The protocol now includes:

- `sendMonitorCommand(_ command: String, duration: TimeInterval)` — monitor mode capture.
- `reset()` — returns the transport to a clean disconnected state, aborting any in-flight continuation.

All four transports (BLE, Wi-Fi, iOS Serial, macOS Serial) conform to the updated protocol.

### Swift Concurrency (`Sendable`) Conformance

`OBDCommand` and all its sub-enumerations (`General`, `Protocols`, `Mode1`, `Mode3`, `Mode6`, `Mode9`) now conform to `Sendable`. `OBDService` and `ConfigurationService` carry `@unchecked Sendable` to satisfy Swift 5.10 strict concurrency checks. These additions eliminate data-race warnings when using `OBDCommand` values across actor boundaries and enable the library to be used cleanly in `async` contexts.

---

## Setting Up a Project

1. **Create a New Swift Project**  
   Open Xcode and start a new iOS or macOS project.

2. **Add the SwiftOBD2 Package**  
   In Xcode navigate to File > Add Packages... and enter this repository's URL: `https://github.com/kkonteh97/SwiftOBD2/`

3. **Permissions and Capabilities**

   - **Bluetooth**: add `NSBluetoothAlwaysUsageDescription` to `Info.plist` and enable **Uses Bluetooth LE Accessories** under the Background Modes capability.
   - **USB Serial (iOS, MFi)**: add `com.scantool.stnobd` to the `UISupportedExternalAccessoryProtocols` array in `Info.plist`. The MFi entitlement is also required for App Store distribution.
   - **USB Serial (macOS)**: no entitlement is needed for `termios`/POSIX serial access. The user selects the `/dev/tty.*` path in your preferences UI and assigns it to `ConfigurationService.shared.serialPath`.

---

## Key Concepts

- **`OBDService`**: the primary entry point. Manages the selected transport, drives ELM327 initialisation, and exposes all vehicle interaction APIs.
- **`ConfigurationService`**: persists connection settings (type, Wi-Fi host/port, serial path, logging flags) to `UserDefaults`.
- **`CommProtocol`**: the internal transport abstraction. Implemented by `BLEManager`, `WifiManager`, `SerialManager` (iOS), `MacSerialManager` (macOS), and `MOCKComm`. Not part of the public API surface but useful to understand when building custom transports.
- **`OBDServiceDelegate`**: protocol for receiving connection state changes, peripheral list updates, adapter info, and log messages. Default no-op implementations are provided so conformances only need to implement the callbacks they care about.
- **`OBDCommand`**: typed enumeration of all supported OBD commands organised by mode. Each case carries a `CommandProperties` struct that encodes the wire bytes, human-readable description, expected response length, decoder, and whether running-engine conditions are required.
- **`ConnectionState`**: value describing the current transport state. Conforms to `Sendable` and `Equatable`.

---

## Usage

### 1. Configure Connection Type

Set the desired connection type and any required settings before connecting:

- For Wi-Fi, set `ConfigurationService.shared.wifiHost` and `.wifiPort` to match your adapter.
- For macOS Serial, set `ConfigurationService.shared.serialPath` to the `/dev/tty.*` device.
- For iOS USB Serial, ensure the adapter is physically connected; no path configuration is needed.

### 2. Observing Connection State

Subscribe to `obdService.$connectionState` (Combine) or assign `obdService.onConnectionStateChanged` to react to state transitions without adopting the delegate protocol.

### 3. Starting the Connection

Call `startConnection(preferedProtocol:timeout:peripheral:)`. The optional `peripheral` argument connects directly to a specific BLE device from a prior scan. The call returns `OBDInfo` containing the detected OBD protocol, a list of supported PIDs, and vehicle identification data.

### 4. Scanning for BLE Adapters

Call `scanForPeripherals()` to populate `obdService.peripherals`. Present the list in your UI and pass the chosen `CBPeripheral` to `startConnection(peripheral:)`.

### 5. Requesting Real-Time Data

Use `startContinuousUpdates(_ pids:)` to poll a set of PIDs at a regular interval. The returned publisher emits a `[OBDCommand: MeasurementResult]` dictionary on each update cycle. Use `addPID(_:)` and `removePID(_:)` to adjust the active set without restarting the update loop.

### 6. Scanning for Trouble Codes

- `scanForTroubleCodes()` reads standard OBD Mode 03 DTCs.
- `scanForUDSDTCs(header:)` reads manufacturer-specific DTCs from an ECU identified by its CAN header, using UDS Service $19.
- `clearTroubleCodes()` sends Mode 04 to erase stored DTCs.

### 7. CAN Bus Monitoring

Call `sendMonitorCommandInternal("AT MA", duration: 5.0)` to capture 5 seconds of raw CAN frames from all IDs. Use `"AT MT hh"` to monitor a specific header. The returned array contains raw hex frame strings as reported by the ELM327.

### 8. Switching Protocols Mid-Session

Use `switchProtocol(_ proto:)` to move between CAN buses (e.g. from `protocol6` ISO 15765-4 11-bit 500kbps to `protocol9` ISO 15765-4 29-bit 500kbps) without disconnecting from the adapter.

### 9. Reading Adapter Information

After connecting, `obdService.adapterInfo` contains a dictionary of GATT Device Information Service fields (`"Manufacturer"`, `"Model"`, `"Firmware Revision"`, etc.) read directly from the BLE adapter. Subscribe via `obdService.$adapterInfo` or the `onAdapterInfoUpdated` closure.

### 10. Logging

Enable `ConfigurationService.shared.obdCommandLogging = true` during development to see every OBD command and raw response. Assign `obdService.onLog` to route messages to your app's log view or console.

---

## Code Example

```swift
class ViewModel: ObservableObject {
    @Published var measurements: [OBDCommand: MeasurementResult] = [:]
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectionLogs: [String] = []

    var cancellables = Set<AnyCancellable>()
    let obdService = OBDService(connectionType: .bluetooth)

    init() {
        obdService.$connectionState.assign(to: &$connectionState)
        obdService.onLog = { [weak self] msg in
            DispatchQueue.main.async { self?.connectionLogs.append(msg) }
        }
    }

    func startConnection() async throws {
        let info = try await obdService.startConnection(preferedProtocol: .protocol6)
        print(info)
        obdService.startContinuousUpdates([.mode1(.rpm), .mode1(.speed)])
            .sink { _ in } receiveValue: { self.measurements = $0 }
            .store(in: &cancellables)
    }

    func stopConnection() {
        cancellables.removeAll()
        obdService.stopConnection()
    }

    func getTroubleCodes() async {
        let dtcs = try? await obdService.scanForTroubleCodes()
        print(dtcs ?? "nil")
    }

    func getUDSDTCs(ecuHeader: String) async {
        let dtcs = try? await obdService.scanForUDSDTCs(header: ecuHeader)
        print(dtcs ?? "nil")
    }

    func monitorCANBus() async {
        let frames = try? await obdService.sendMonitorCommandInternal("AT MA", duration: 5.0)
        print(frames ?? [])
    }
}
```

---

## Supported Connection Types

| Type | Platform | Adapter Examples |
|---|---|---|
| Bluetooth LE | iOS, macOS | OBDLink MX+, BAFX, Veepeak BLE |
| Wi-Fi TCP | iOS, macOS | Veepeak Mini WiFi, most clone adapters |
| USB Serial (MFi) | iOS only | OBDLink EX |
| USB Serial (POSIX) | macOS only | Any USB-to-serial adapter at a `/dev/tty.*` path |

---

## Supported OBD Modes and Commands

| Mode | Description |
|---|---|
| Mode 01 | Real-time data — PIDs 0x00–0xC8 (full SAE J1979 range) |
| Mode 03 | Stored DTCs |
| Mode 04 | Clear DTCs |
| Mode 06 | On-board monitoring test results (MIDs A–M) |
| Mode 09 | Vehicle information (VIN, calibration IDs, CVN) |
| UDS $19 | Manufacturer-specific DTCs via header targeting |

A complete list of Mode 1 PID cases is in `OBDCommand.Mode1`. Each case maps directly to its SAE J1979 PID byte.

---

## 🛠️ Troubleshooting

### Common Issues

**Q: Bluetooth connection fails immediately**
- Ensure `NSBluetoothAlwaysUsageDescription` is in `Info.plist`.
- Make sure Bluetooth is on and permissions granted in iOS Settings.
- Verify your ELM327 adapter is powered (OBD port has ignition on).
- Try calling `scanForPeripherals()` first and passing the resulting peripheral to `startConnection(peripheral:)` rather than relying on auto-discovery.

**Q: Wi-Fi adapter times out during protocol detection**
- Some adapters take longer than 7 seconds on `SEARCHING...`. Increase the `timeout` parameter to `startConnection` (15–20 seconds is safe).
- Confirm host and port match your adapter — set them via `ConfigurationService.shared`.
- If connection works but `ATZ` causes a disconnect, this is handled automatically by the Wi-Fi reconnect logic in this release.

**Q: macOS serial adapter not found**
- Run `ls /dev/tty.*` in Terminal after connecting the adapter to find the device path.
- Assign the path to `ConfigurationService.shared.serialPath` before calling `startConnection`.
- The baud auto-probe will try four rates; if none produces a valid response, check the cable and that the adapter is ELM327-compatible.

**Q: iOS USB Serial adapter not detected**
- Confirm the adapter carries the `com.scantool.stnobd` MFi protocol string (OBDLink EX does; most clone adapters do not).
- Add `UISupportedExternalAccessoryProtocols` with `com.scantool.stnobd` to `Info.plist`.
- The adapter must be physically connected before calling `startConnection`.

**Q: PIDs return zero or garbage values on some vehicles**
- Enable `ConfigurationService.shared.obdCommandLogging = true` and inspect the raw responses via `onLog`.
- Single-byte default responses (e.g. `0x11`) from unsupported PIDs now return `.failure(.noData)` rather than a decoded value — this is correct behaviour and means the vehicle ECU does not support that PID.

**Q: No data received from vehicle**
- Confirm the vehicle is OBD2 compatible (1996+ in the US).
- Some PIDs require the engine to be running — check the `requiresRunningEngine` flag on `CommandProperties`.
- Try connecting without a preferred protocol first (omit `preferedProtocol`) to let auto-detection run.

### Hardware Compatibility

✅ **Tested ELM327 Adapters:**
- BAFX Products Bluetooth OBD2
- OBDLink MX+ Bluetooth
- OBDLink EX USB (iOS serial)
- VEEPEAK Mini WiFi OBD2
- Generic ELM327 BLE clones (FFE0/FFF0/18F0 GATT profiles)

⚠️ **Known Limitations:**
- Cheap ELM327 clones may drop the Wi-Fi TCP connection on ATZ; the automatic reconnect handles this transparently.
- iOS USB serial requires MFi certification — generic USB OBD adapters without the `com.scantool.stnobd` protocol string will not enumerate.

### Getting Help

- 📋 [Open an issue](https://github.com/kkonteh97/SwiftOBD2/issues) for bug reports
- 💡 [Start a discussion](https://github.com/kkonteh97/SwiftOBD2/discussions) for questions
- 📱 Check out the [sample app](https://github.com/kkonteh97/SwiftOBD2App) for implementation examples

---

## Important Considerations

- **Permissions**: Bluetooth requires `NSBluetoothAlwaysUsageDescription` in `Info.plist` and the Background Modes capability. USB serial on iOS additionally requires MFi entitlements.
- **Error Handling**: implement robust error handling — adapter timeouts, unsupported PIDs, and CAN bus errors all surface as typed Swift errors.
- **Thread Safety**: `OBDService` is `ObservableObject` and marshals `@Published` updates to the main thread. The `onLog` and other closures are also dispatched to the main queue.
- **Background Updates**: if your app needs OBD data in the background, enable the **Uses Bluetooth LE Accessories** background mode and handle the CoreBluetooth state restoration path (peripherals are now restored to the scan list rather than auto-connected).

---

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
