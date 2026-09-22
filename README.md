# EC20 Companion for macOS

A native macOS application and diagnostic suite designed specifically for Apple Silicon Macs and the **Quectel EC20-CE-HDLG** (USB `VID: 0x2c7c`, `PID: 0x0125`) cellular modem.

---

## 1. System Overview & Architecture

### Hardware & Driverless Userspace Design
On modern macOS releases, Qualcomm/Quectel cellular modems connected via USB do not load serial driver nodes (such as `/dev/cu.usb*`), and `system_profiler SPUSBDataType` frequently misreports or omits vendor-specific devices. 

`EC20Companion` circumvents this limitation through a direct userspace USB transport built on `libusb-1.0`:
- **Direct USB Claiming**: Directly opens device `0x2c7c:0x0125` and claims USB **Interface 2** (dedicated AT and URC port).
- **Endpoint Pipeline**: Asynchronous bulk OUT (`0x03`) and bulk IN (`0x84`) transfer engine with automated background read thread.
- **Actor-Isolated Serial Queue**: Ensures that single in-flight AT commands are sequenced safely with strict timeout bounds while allowing Unsolicited Result Codes (URCs) to be demultiplexed in real time.
- **Privacy & Security Masking**: All sensitive identifiers (ICCID, IMSI, IMEI, and telephone numbers) are masked at the presentation and logging layer (`8986************9588`, `+86 138****5678`).

### USB Interface Topology (Quectel EC20-CE)
| Interface | Endpoints | Protocol / Class | Description & State in App |
|---|---|---|---|
| **0** | EP 0x01 OUT, EP 0x81 IN | Vendor (0xFF) | DIAG / DM (Qualcomm QCDM logging) |
| **1** | EP 0x02 OUT, EP 0x82 IN, EP 0x83 INT | Vendor (0xFF) | GNSS / NMEA; Voice over USB PCM stream (`AT+QPCMV=1,0`) |
| **2** | EP 0x03 OUT, EP 0x84 IN, EP 0x85 INT | Vendor (0xFF) | **Primary AT Command & URC Port** (Active Transport) |
| **3** | EP 0x04 OUT, EP 0x86 IN, EP 0x87 INT | Vendor (0xFF) | Modem / PPP Dialup port (Standby) |
| **4** | EP 0x05 OUT, EP 0x88 IN, EP 0x89 INT | Vendor (0xFF) | RMNET / Qualcomm MSM Network Interface |

---

## 2. Requirements & Prerequisites

1. **Hardware**: Apple Silicon Mac (M1/M2/M3/M4) with Quectel EC20-CE-HDLG connected via USB Type-C.
2. **macOS**: Built and verified on the connected Mac. The Swift package targets macOS 13; this bundle links to the locally installed Homebrew `libusb`, so copying the bundle to another Mac requires a compatible `libusb` build.
3. **Swift**: Swift 6.4 (Command Line Tools or Xcode).
4. **libusb**: Installed via Homebrew (`/opt/homebrew/lib/libusb-1.0.dylib`).

---

## 3. Quick Start & Verification Commands

### A. Run Full Test Suite (Offline)
Executes 43 offline checks covering PDU packing and inbox decoding, UCS2, URC parsing, log masking, SMS submission framing, and mock telephony flows:
```bash
swift run ec20-tests
```

### B. Run Real Hardware Diagnostic Probe
Executes a non-destructive hardware probe through `libusb` on Interface 2, querying module identity, SIM state, network registration, signal quality, and audio capabilities:
```bash
./scripts/run_probe.sh
# or directly:
swift run ec20-cli
```

### C. Build the macOS Application (.app)
Generates the native double-clickable `EC20Companion.app` bundle:
```bash
./scripts/build_app.sh
```

### D. Launch GUI Application
```bash
open EC20Companion.app
```

---

## 4. Verification Handoff Matrix

### ✅ Verified on Real EC20 Hardware (`2c7c:0125`)
| Item | AT Command / Method | Live Hardware Result |
|---|---|---|
| **USB Claiming** | `libusb_claim_interface(dev, 2)` | Interface 2 claimed successfully without kernel driver conflict |
| **Basic Communication** | `ATE0`, `AT+CMEE=2` | Echo disabled, verbose error reporting active |
| **Identity & Firmware** | `ATI` | `Quectel EC20F`, `Revision: EC20CEHDLGR08A02M1G` |
| **SIM Card Status** | `AT+CPIN?` | `+CPIN: READY` |
| **CS Domain Network** | `AT+CREG?` | `+CREG: 0,1` (Registered, Home Network) |
| **EPS/LTE Network** | `AT+CEREG?` | `+CEREG: 0,1` (Registered, LTE Home Network) |
| **Cellular Operator** | `AT+COPS?` | `+COPS: 0,0,"CHN-UNICOM",7` (China Unicom LTE) |
| **Signal Quality** | `AT+CSQ` | `+CSQ: 21,99` (-71 dBm, 4/4 bars) |
| **SIM ICCID** | `AT+QCCID` | Read successfully (masked as `8986************9588`) |
| **IMSI** | `AT+CIMI` | Read successfully (masked as `4600*******7957`) |
| **IMEI / Serial** | `AT+GSN` | Read successfully (masked as `8691*******2371`) |
| **URC Port Binding** | `AT+QURCCFG="urcport"` | Verified bound to `"usbat"` (Interface 2) |
| **Caller ID Feature** | `AT+CLIP=1` | Enabled successfully |
| **Voice over USB Query** | `AT+QPCMV=?`, `AT+QPCMV?` | Query supported: `(0,1),(0-2)`. Current non-destructive value: `0,0` |
| **Digital Audio Setting**| `AT+QDAI?` | `+QDAI: 3,0,0,4,0,0,1,1` |

### ✅ Verified by Offline Test Suite (`ec20-tests`)
- **PDU 7-Bit GSM**: Septet packing/unpacking conforms to 3GPP TS 23.038.
- **PDU UCS2**: Chinese string encoding (`4F60597D...`), multipart concatenation splitting (UDH IEI `0x00`), and single PDU TPDU generation.
- **PDU Decoder**: Decodes incoming SMS-DELIVER PDU with timestamp, sender number, and message text.
- **URC Parsing**: Verifies parsing for `+CMTI`, `+CLIP`, `RING`, `NO CARRIER`, `+CREG`, `+CEREG`, `+CSQ`.
- **Sensitive Masking**: Rigorous unit tests ensuring ICCID, IMSI, IMEI, and phone numbers are redacted in UI and log traces.
- **Telephony State Machine**: Simulated incoming calls, call answering, and call termination.

### ⏸️ Unverified / Safely Deferred (Requires User-Provided Test Destination)
- **Actual Outgoing SMS Delivery**: Requires the user to authorize a specific destination phone number to avoid accidental SMS costs or unsolicited messages.
- **Actual Outgoing Call Dial-Out**: Requires the user to authorize a specific test number to avoid accidental carrier billing or triggering operator alarms.

---

## 5. Audio & Voice Feasibility & Bridge Implementation

### Clean Verification Evidence (No Buffer Pollution)
An initial ad-hoc probe was polluted by residual output from `AT+QCFG=?`. A subsequent isolated probe drained the receive endpoint before each query and confirmed these responses. The app's regular AT transport does not perform a per-command flush:
- `AT+QPCMV=?` -> `+QPCMV: (0,1),(0-2)` (Confirmed: Hardware supports Voice over USB)
- `AT+QPCMV?`  -> `+QPCMV: 0,0` (Confirmed: Default state is disabled, port 0 / NMEA)
- `AT+QDAI?`   -> `+QDAI: 3,0,0,4,0,0,1,1` (Confirmed: Digital audio interface settings)

### Core Distinction: Call Signaling vs. Voice Audio
A primary requirement of this project is to maintain a strict distinction between **Call Signaling** and **Voice Audio**:
1. **Call signaling is implemented**: The app sends `ATD`, `ATA`, and `ATH`, polls `AT+CLCC`, and handles caller ID events on USB Interface 2. These flows passed mock tests; no live call has been placed.
2. **UAC Sound Card is Absent**: The USB descriptor does not expose a standard USB Audio Class (UAC 1.0/2.0) interface. macOS System Settings therefore does not recognize the EC20 as a microphone or speaker.

### Implemented CoreAudio ↔ USB Interface 1 Audio Bridge
Following the official *Quectel EC2x&EG9x Voice Over USB and UAC Application Note*:
- **Interface 1 (GNSS/NMEA)**: Used as the raw PCM audio channel when `AT+QPCMV=1,0` is issued on Interface 2.
- **Audio Format**: 8000 Hz sample rate, 16-bit Signed Linear PCM, Mono.
- **Buffer Specifications**:
  - Read from Endpoint `0x82`: 640 bytes per 40ms (320 samples).
  - Write to Endpoint `0x02`: 1600 bytes per 100ms (800 samples).
- **Architecture**:
  - `EC20AudioBridge` (`Sources/EC20Transport/EC20AudioBridge.swift`) uses macOS `AudioToolbox.AudioQueue` to capture local microphone audio and route received PCM to system speakers.
  - Enables `AT+QPCMV=1,0` and starts the bridge before dialing or answering, following the Quectel sequence.
  - Automatically deactivates on call termination (`onCallEnded` releases Interface 1 and issues `AT+QPCMV=0`).
  - Includes a standalone **Loopback Self-Test Mode** (Mic ➔ Speaker) in the GUI to verify the CoreAudio audio pipeline independently of carrier calls.

> [!IMPORTANT]
> **Field verification**: The GUI loopback mode started and stopped on this Mac. Audible quality and two-way carrier audio have not been measured. A user-controlled test number is needed for end-to-end SMS and call verification.
