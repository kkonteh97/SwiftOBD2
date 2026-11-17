# Data Logging

Record standard and custom PIDs during a drive, and export them as CSV or JSON.

## Overview

```swift
let logger = OBDDataLogger(service: obdService)
try logger.start([.mode1(.rpm), .mode1(.speed), oilTemperature], interval: 0.2, fileURL: csvURL)
// … drive …
logger.stop()

let csv = logger.csv()     // timestamp,elapsed_s,RPM (rpm),Vehicle Speed (km/h),Oil temperature (°C)
let json = try logger.json()
```

When a file is given, each sample is appended as it arrives, so nothing is lost if the app is terminated.
``OBDDataLogger/memoryLimit`` bounds the number of samples kept in memory for long recordings.

``OBDDataLogger/isRecording`` and ``OBDDataLogger/sampleCount`` are published for SwiftUI.
``OBDDataLogger/onSample`` receives every sample, and ``OBDDataLogger/onFinish`` is called when the recording
ends, with the error that stopped it, if any.
