#!/usr/bin/env python3
"""Decode the CRSF telemetry stream EdgeTX mirrors to its USB serial port.

On the radio: System, Hardware, Serial ports, set USB-VCP to "Telemetry
Mirror"; plug in USB and choose "USB Serial (VCP)". Then:

    crsf_mirror.py [/dev/ttyACM0] [--seconds 20] [--raw]

Prints every frame type it sees with counts and rates, flags CRC errors,
and decodes the frames the Cerebri firmware sends: GPS (0x02), battery
(0x08), flight mode (0x21) and the Yaapu passthrough words inside the
0x80 custom telemetry frame (0xF2 multi packet and 0xF1 status text).

Requires pyserial.
"""

import argparse
import struct
import sys
import time

import serial

NAMES = {0x02: "gps", 0x07: "vario", 0x08: "battery", 0x09: "baro", 0x0B: "heartbeat",
         0x14: "link_stats", 0x16: "rc_channels", 0x1E: "attitude", 0x21: "flight_mode",
         0x28: "ping", 0x29: "device_info", 0x2B: "param_entry", 0x2C: "param_read",
         0x2D: "param_write", 0x32: "command", 0x3A: "radio_id", 0x80: "ap_custom"}


def crc8(data, poly=0xD5):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def ext(value, offset, length):
    return (value >> offset) & ((1 << length) - 1)


def prep(value, mant_off, exp_off, sign_off=None, mant_bits=7):
    number = ext(value, mant_off, mant_bits) * (10 ** ext(value, exp_off, 1))
    if sign_off is not None and ext(value, sign_off, 1):
        number = -number
    return number


def decode_passthrough(appid, value):
    if appid == 0x5006:
        return (f"roll {(min(ext(value, 0, 11), 1800) - 900) * 0.2:.1f} "
                f"pitch {(min(ext(value, 11, 10), 900) - 450) * 0.2:.1f}")
    if appid == 0x5005:
        return (f"vspeed {prep(value, 1, 0, 8) / 10:.1f} m/s hspeed {prep(value, 10, 9) / 10:.1f} m/s "
                f"yaw {ext(value, 17, 11) * 0.2:.1f}")
    if appid == 0x5001:
        return (f"mode {ext(value, 0, 5)} armed {ext(value, 8, 1)} failsafe {ext(value, 12, 1)} "
                f"throttle {ext(value, 19, 6) * 1.58:.0f}%")
    if appid == 0x5002:
        alt_exp = ext(value, 22, 2)
        alt = ext(value, 24, 7) * (10 ** alt_exp) * (-0.1 if ext(value, 31, 1) else 0.1)
        return (f"sats {ext(value, 0, 4)} fix {ext(value, 4, 2)} hdop {prep(value, 7, 6) / 10:.1f} "
                f"alt {alt:.0f} m")
    if appid == 0x5003:
        return (f"volt {ext(value, 0, 9) / 10:.1f} V curr {prep(value, 10, 9) / 10:.1f} A "
                f"mah {ext(value, 17, 15)}")
    if appid == 0x5004:
        dist = ext(value, 2, 10) * (10 ** ext(value, 0, 2))
        alt = ext(value, 14, 10) * (10 ** ext(value, 12, 2)) * (-0.1 if ext(value, 24, 1) else 0.1)
        return f"home dist {dist} m alt {alt:.1f} m bearing {ext(value, 25, 7) * 3}"
    if appid == 0x5007:
        return f"param id {ext(value, 24, 4)} value {ext(value, 0, 24)}"
    return "value 0x%08x" % value


def decode(ftype, payload):
    if ftype == 0x02 and len(payload) >= 15:
        lat, lon, spd, hdg, alt, sats = struct.unpack(">iiHHHB", payload[:15])
        return f"lat {lat / 1e7:.7f} lon {lon / 1e7:.7f} speed {spd / 10:.1f} km/h hdg {hdg / 100:.2f} alt {alt - 1000} m sats {sats}"
    if ftype == 0x08 and len(payload) >= 8:
        volt, curr = struct.unpack(">HH", payload[:4])
        mah = int.from_bytes(payload[4:7], "big")
        return f"{volt / 10:.1f} V {curr / 10:.1f} A {mah} mAh {payload[7]} %"
    if ftype == 0x21:
        return payload.split(b"\0", 1)[0].decode(errors="replace")
    if ftype == 0x14 and len(payload) >= 10:
        return (f"uplink rssi -{payload[0]} lq {payload[2]} snr {struct.unpack('b', payload[3:4])[0]} "
                f"rf_mode {payload[5]} downlink rssi -{payload[7]} lq {payload[8]}")
    if ftype == 0x80 and payload:
        if payload[0] == 0xF2 and len(payload) >= 2:
            words = []
            for i in range(payload[1]):
                base = 2 + 6 * i
                if base + 6 > len(payload):
                    break
                appid = payload[base] | payload[base + 1] << 8
                value = int.from_bytes(payload[base + 2:base + 6], "little")
                words.append(f"0x{appid:04x} {decode_passthrough(appid, value)}")
            return " | ".join(words)
        if payload[0] == 0xF1 and len(payload) >= 3:
            return f"text sev {payload[1]} '{payload[2:].split(b'\0', 1)[0].decode(errors='replace')}'"
        return "sub 0x%02x" % payload[0]
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port", nargs="?", default="/dev/ttyACM0")
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--raw", action="store_true", help="print every decoded frame")
    args = parser.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    buf = bytearray()
    counts, bad, last = {}, 0, {}
    start = time.time()
    while time.time() - start < args.seconds:
        buf += ser.read(4096)
        while len(buf) >= 4:
            if buf[0] not in (0xC8, 0xEA, 0xEC, 0xEE):
                del buf[0]
                continue
            length = buf[1]
            if length < 2 or length > 62:
                del buf[0]
                continue
            if len(buf) < length + 2:
                break
            frame = bytes(buf[:length + 2])
            if crc8(frame[2:-1]) != frame[-1]:
                bad += 1
                del buf[0]
                continue
            del buf[:length + 2]
            ftype, payload = frame[2], frame[3:-1]
            counts[ftype] = counts.get(ftype, 0) + 1
            text = decode(ftype, payload)
            if text:
                last[ftype] = text
            if args.raw:
                print(f"{time.time() - start:7.3f} {NAMES.get(ftype, '0x%02x' % ftype):12s} {text or payload.hex(' ')}")
    elapsed = time.time() - start
    print(f"\n{elapsed:.1f} s on {args.port}: {sum(counts.values())} frames, {bad} CRC errors")
    for ftype in sorted(counts):
        print(f"  {NAMES.get(ftype, '0x%02x' % ftype):12s} {counts[ftype]:6d}  {counts[ftype] / elapsed:6.2f}/s  {last.get(ftype, '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
