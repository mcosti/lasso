# Cowboy 3 BLE protocol and re-unlock policy

A platform-neutral reference for talking to a Cowboy 3 over Bluetooth Low
Energy, and for the policy this app uses to re-unlock a bike that locked
itself mid-ride. It is written so the Android port (or anyone else) can be
implemented from it without reading the Swift code. The iOS implementation
lives in `ios/App/Protocol.swift` (constants, frames, decoder) and
`ios/App/BikeManager.swift` (connection and policy).

Everything below was verified on a real Cowboy 3 running firmware 4.21.5
unless marked otherwise.

## Sources and credit

The protocol was reverse engineered by others first. This document builds on:

- [Bronco Unleashed](https://github.com/runerune/BroncoUnleashed) (runerune):
  lock characteristic, dashboard protobuf (`dashboard.proto`), Modbus over UART.
- [Cowboy Untamed](https://github.com/Imaginous/Cowboy_Untamed) (Imaginous):
  Modbus registers on the main PCB and the motor controller.
- [cowboyunleashed](https://github.com/mmmago/cowboyunleashed) (mmmago):
  further register and pairing notes.

## Discovery and pairing

- The bike advertises with the local name `COWBOY`. It may or may not include
  the service UUIDs below in the advertisement, so match on name or service.
- All characteristics are encrypted. The bike requires an **authenticated LE
  bond** with a 6-digit passkey (MITM protection). Without the bond, reads and
  writes fail with an insufficient authentication / encryption error.
- The passkey and the MAC address come from the Cowboy cloud API:
  `GET /bikes/{id}` returns `passkey` and `mac_address`. Calling it needs the
  owner's Cowboy account credentials. This app does not call the API.
- **iOS:** bonds are stored system-wide. Once the official Cowboy app has
  paired the phone, any app can use the bike without entering the passkey.
  This app relies on that and never asks for it.
- **Android:** bonds are also system-wide. If the official app has already
  paired the phone, nothing else is needed. Otherwise the app must call
  `createBond()` and the user types the passkey in the system dialog (or the
  app supplies it with `setPin` if it knows it).

## Connection model

- The bike accepts **one BLE central connection** at a time.
- iOS multiplexes all apps over one link to a peripheral, so this app and the
  official Cowboy app coexist on the same connection. We even observe the
  official app's UART traffic (its Modbus replies arrive on our TX
  subscription too).
- Android also keeps a single physical GATT link per device and shares it
  between `BluetoothGatt` clients. However, each app manages its own
  `connectGatt`/`disconnect` calls, and the official app may disconnect or
  reconnect in ways that disturb ours. **Risk, to verify on a real device:**
  whether the two apps fight over the connection and whether our
  `autoConnect` client survives the official app closing its client.

## GATT layout

### Cowboy service `C0B0A000-18EB-499D-B266-2F2910744274`

| Characteristic | UUID | Properties | Content |
|---|---|---|---|
| Lock | `C0B0A001-18EB-499D-B266-2F2910744274` | Read, Write, Notify | 1 byte: `0x01` unlocked, `0x00` locked |
| Dashboard | `C0B0A00A-18EB-499D-B266-2F2910744274` | Notify | Protobuf `Dashboard` message, see below |

Lock characteristic:

- Write `0x01` to unlock, `0x00` to lock.
- A write with response is acknowledged in about 60 ms. Writing with response
  is preferred: if the bond is missing you get an error instead of silence.
  Write without response also works (the nRF key fob does this).
- It notifies on every change, whoever caused it (button, official app,
  auto-lock, this app, reboot).
- Reading it right after a connection gives the current state.

### Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

| Characteristic | UUID | Direction | Properties |
|---|---|---|---|
| RX | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | phone to bike | Write Without Response |
| TX | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | bike to phone | Notify |

The payload in both directions is a **Modbus RTU** frame.

## Modbus over UART

| Slave address | Device |
|---|---|
| `0x01` | ASI motor controller |
| `0x0A` | Main (communication) PCB |
| `0x04` | Battery |

Functions used:

- `0x03` read holding register: `slave 03 regHi regLo 00 01 crcLo crcHi`.
  Reply: `slave 03 02 valHi valLo crcLo crcHi`.
- `0x10` write registers, always one register here (count `00 01`, byte
  count `02`): `slave 10 regHi regLo 00 01 02 valHi valLo crcLo crcHi`.
  Reply echoes `slave 10 regHi regLo 00 01 crcLo crcHi`.

CRC: standard Modbus CRC-16. Init `0xFFFF`, reflected polynomial `0xA001`,
computed over all preceding bytes, appended **little-endian** (low byte first).

```python
def crc16(data: bytes) -> bytes:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return bytes([crc & 0xFF, crc >> 8])
```

### Known main PCB (`0x0A`) registers

| Register | Meaning | Values |
|---|---|---|
| `0x0000` | Auto-lock | 1 on, 0 off |
| `0x0001` | Lights | 1 on, 0 off |
| `0x0014` | Auto-unlock | 1 on, 0 off |
| `0x00F2` | Reboot communication PCB | write 1 |

Writing 1 to `0x00F2` restarts the communication PCB. The BLE link drops for
about 3 to 5 seconds and the bike comes back **locked**, with its settings
kept. This is exactly what a battery drop looks like from the phone, so it is
how the re-unlock logic is tested without waiting for a real fault. Expect the
LEDs on the top tube to run back and forth while it reboots.

Reads from the battery slave (`0x04`) return the state of charge in percent.
Which registers exist on the battery is not documented here; we only observed
the official app's reads and their replies.

### Worked examples (CRC computed with the algorithm above)

| Command | Frame |
|---|---|
| Lights on | `0A 10 00 01 00 01 02 00 01 15 71` |
| Lights off | `0A 10 00 01 00 01 02 00 00 D4 B1` |
| Read auto-lock | `0A 03 00 00 00 01 85 71` |
| Read auto-unlock | `0A 03 00 14 00 01 C5 75` |
| Reboot PCB | `0A 10 00 F2 00 01 02 00 01 01 B2` |

Byte by byte, "lights on":

```
0A        slave: main PCB
10        function: write registers
00 01     register 0x0001 (lights)
00 01     register count: 1
02        byte count: 2
00 01     value: 1 (on)
15 71     CRC-16 0x7115, low byte first
```

### Out of scope

Motor-controller register hacks (speed limit, field weakening, and so on)
documented by the projects above stopped working on firmware 4.21.x with
Adaptive Power 2.0. This app does not write to the motor controller. The lock
characteristic is unchanged on 4.21.x.

## Dashboard protobuf

Notified on `C0B0A00A` several times per second while the bike is unlocked.
Each notification is one protobuf message, but **only fields that changed are
present**, so keep the last known value of each field and merge. A missing
field means "unchanged", not zero.

| Field | Wire type | Name | Unit / notes |
|---|---|---|---|
| 1 | varint | tripId | int32. Changes after every reboot / unlock session |
| 2 | varint | duration | seconds since unlock |
| 3 | varint | speed | km/h |
| 4 | varint | power | W |
| 5 | varint | distance | m this trip |
| 6 | varint | battery | % state of charge |
| 7 | varint | assistance | assistance level |
| 8 | varint | lights | 0 off, 1 on |
| 9 | varint | batteryVoltage | mV |
| 10 | varint | unknown | |
| 11 | fixed32 | batteryTemp | IEEE 754 float, units of 0.1 K (celsius = v / 10 - 273.15) |
| 12 to 14 | varint | unknown | |
| 15 | varint | activeDuration | seconds |
| 16 | varint | movingDuration | seconds |
| 17 | varint | pedalTorque | |

The message is small and flat, so a hand-written decoder is enough: read a
varint key, field = key >> 3, wire type = key & 7, then a varint (type 0),
4 bytes little-endian (type 5), 8 bytes (type 1, skip) or a length-prefixed
blob (type 2, skip). Ignore unknown fields.

Example: `18 15 30 36 5D 00 B8 39 45`

```
18 15           field 3 (speed), varint 21 -> 21 km/h
30 36           field 6 (battery), varint 54 -> 54 %
5D 00 B8 39 45  field 11 (batteryTemp), float 2971.5 -> 24.35 C
```

Fields 15 to 17 have two-byte keys (for example field 17 is `88 01`).

"Moving" for the policy below means speed > 0 (this app also counts
power > 0) in the merged dashboard.

## Observed reboot timeline

What a battery drop (or a PCB reboot) looks like from the phone:

1. Dashboard streaming, lock = unlocked, ride in progress.
2. Link drops. On iOS the error is `CBErrorDomain 7` ("The specified device
   has disconnected from us"). On Android expect a GATT status such as
   `0x13` or `0x08`; to be confirmed.
3. About 3 to 5 seconds later the bike advertises again and the pending
   connection completes.
4. Service discovery, then reading the lock gives `0x00` (locked).
5. Unlock write with response is acknowledged in about 60 ms; the lock
   characteristic notifies `0x01`.
6. Dashboard resumes with a **new tripId**.

## Re-unlock policy

Persist the ride state (`rideActive`, `lastDisconnectAt`, `lastMovingAt`)
across process restarts: the OS may kill and relaunch the app mid-ride.

### Modes

**During a ride** (default). Only undo locks the rider did not ask for.

- A ride starts when the bike is seen unlocked (lock read or notification, or
  any dashboard packet while unlocked).
- On disconnect, record `lastDisconnectAt`.
- On reconnect, read the lock. If it is locked, a ride was active, and
  `now - lastDisconnectAt <= reconnectWindow` (default **60 s**), it is a
  reboot: unlock.
- If the lock characteristic notifies "locked" while connected, a ride is
  active, and `now - lastMovingAt <= movingGrace` (default **15 s**), nobody
  did that on purpose: unlock.
- A lock at standstill (outside the moving grace), or a reconnect after the
  window, **ends the ride**. The lock is intentional and is respected.

**Always.** Unlock every time the phone connects and finds the bike locked,
like the official Auto Unlock but without waiting for the bike to be moved.

**Off.** Observe and log only. Manual lock / unlock still work.

A manual lock from this app always ends the ride first, so it is never undone.

### Mechanism knobs

Exposed so alternatives can be tried on a bike without a rebuild:

| Setting | Default | Meaning |
|---|---|---|
| Write with response | on | Lock write type |
| Delay after reconnect | 1 s | Settle time before the unlock; skipped if the bike unlocked meanwhile |
| Retries | 3 | Attempts if the bike does not confirm the unlock |
| Retry interval | 2 s | Wait before reading back and retrying |
| Lock polling | off (0) | Read the lock every N s during a ride, for a bike that does not notify |
| Undo any lock during ride | off | Also revert locks at standstill while a ride is active; lock from this app instead |
| Dry run | off | Log what would be done, do not write |

Presets:

| Preset | Write | Delay | Retries | Interval | Polling | Undo any lock |
|---|---|---|---|---|---|---|
| Default | with response | 1 s | 3 | 2 s | off | off |
| Patient | with response | 3 s | 5 | 3 s | off | off |
| Key fob | without response | 0.5 s | 5 | 1 s | off | off |
| Aggressive | with response | 0.5 s | 6 | 1.5 s | 5 s | on |

### Retry loop

After sending the unlock, wait the retry interval. If no "unlocked"
notification arrived, read the lock; wait 1 s more; if still locked and
attempts remain, send again. Give up and log an error after the last attempt.
A successful unlock within 10 s of our write counts as a re-unlock (used for
the "Bike unlocked again" notification).

## Connection strategy (iOS reference)

- Once the bike is known, issue a connect with no timeout and leave it
  pending. The OS completes it whenever the bike is in range, also in the
  background, and relaunches the app if it was killed (CoreBluetooth state
  restoration, `bluetooth-central` background mode).
- After every disconnect, immediately issue the pending connect again.
- On connect: discover the two services, subscribe to lock, dashboard and
  UART TX notifications, read the lock, then apply the policy.
- Read RSSI once a minute while connected, for the log.

The Android equivalent is a foreground service holding a `BluetoothGatt`
opened with `autoConnect = true`; see `android/README.md`.
