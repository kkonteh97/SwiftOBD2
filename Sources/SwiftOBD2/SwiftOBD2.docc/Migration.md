# Migrating from Earlier Versions

The changes that may require updating existing code.

## Overview

### New enumeration cases

- ``OBDCommand`` gained ``OBDCommand/custom(_:)``.
- ``OBDServiceError`` gained ``OBDServiceError/notSupported(_:)``.
- ``ELM327Error`` gained cases for the adapter errors (`NO DATA`, `UNABLE TO CONNECT`, negative responses…).

Exhaustive `switch` statements over these types need a new case, or a `default` clause.

### Behaviour changes

- ``OBDService/startContinuousUpdates(_:unit:interval:)`` delivers its values on the main queue, and no longer
  ends on the first transient error (an unsupported PID, a slow answer).
- Trouble codes and values coming from several ECUs are merged instead of the last answer overwriting the
  others.
- In the simulator, ``ConnectionType/wifi`` uses the real Wi-Fi transport. Use ``ConnectionType/demo`` for the
  simulated vehicle.
