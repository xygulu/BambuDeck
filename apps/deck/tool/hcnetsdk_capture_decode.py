#!/usr/bin/env python3
"""Decode an HCNetSDK (EZVIZ) port-8000 capture to recover PTZ command bytes.

Why this exists: the HCNetSDK command-port protocol (login/control framing) is
fully reimplemented in `lib/data/hcnetsdk.dart`, but the *PTZ* `command_id`
(`NET_DVR_PTZControlWithSpeed_Other`) is internal to the native SDK
(libHCCore.so) and absent from every public RE source, including pyEzvizApi
(which delegates PTZ to the native SDK). The one reliable way to recover it is
to watch the EZVIZ app send a PTZ command and read the bytes off the wire.

Capture (run on a machine that is in the LAN path between the EZVIZ app and the
camera, e.g. a Mac doing Internet Sharing for the phone):

    sudo tcpdump -i <iface> -s0 -w /tmp/ezviz_ptz.pcap 'tcp port 8000'

Then trigger one tilt/pan in the EZVIZ app and Ctrl-C. Then:

    python3 tool/hcnetsdk_capture_decode.py /tmp/ezviz_ptz.pcap

Every `0x63` control frame is printed with its `command_id` (header field_12) and
`body_tail` (body bytes after the 16-byte local-ip/session-id/reserved prefix).
The PTZ command is the control frame whose `command_id` is NOT in the known set
and whose tail contains the channel + PTZ command word (21/22/23/24) + speed.

This script is standalone (no deps) and reads pcap or pcapng from tcpdump/wireshark.
"""
from __future__ import annotations

import struct
import sys
from collections import defaultdict

# Known HCNetSDK command_ids reimplemented in hcnetsdk.dart (for "known" labels).
KNOWN_COMMANDS = {
    0x110000: "GET_NET_CFG",
    0x1110C2: "GET_DEVICE_CFG_V40",
    0x110030: "GET_USER_CFG_V30",
    0x20500: "GET_TIME_CFG",
    0x11000: "GetDeviceAbility",
    0x117000: "STDXML",
    0x111040: "play-login",
    0x111096: "GET_CAMERA_PARAM_CFG",
    0x00010000: "login/device-info (0x5A field_12)",
}

LOGIN_FAMILY = 0x5A000000
CONTROL_FAMILY = 0x63000000

# PTZ word values that may appear inside a control body_tail.
PTZ_WORDS = {11, 12, 21, 22, 23, 24, 25, 26, 27, 28, 29, 8, 9, 39}


def _u16(b, o):
    return struct.unpack_from(">H", b, o)[0]


def _u32(b, o):
    return struct.unpack_from(">I", b, o)[0]


def read_packets(path):
    """Yield (src_ip, src_port, dst_ip, dst_port, payload) for TCP segments."""
    data = open(path, "rb").read()
    magic = data[:4]
    if magic == b"\x0a\x0d\x0d\x0a":
        return _read_pcapng(data)
    return _read_pcap(data, magic)


def _read_pcap(data, magic):
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):  # little-endian, incl. ns
        endian = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        raise SystemExit("unsupported pcap magic %r" % magic)
    off = 24  # global header
    while off + 16 <= len(data):
        _ts_sec, _ts_usec, incl_len, orig_len = struct.unpack_from(endian + "IIII", data, off)
        off += 16
        if incl_len == 0 or incl_len > len(data) - off:
            break
        pkt = data[off : off + incl_len]
        off += incl_len
        yield from _parse_ip_packet(pkt)


def _read_pcapng(data):
    # Section Header Block -> Interface Description Block -> Enhanced Packet Block.
    off = 0
    while off + 12 <= len(data):
        block_type, block_len = struct.unpack_from("<II", data, off)
        if block_len < 12 or off + block_len > len(data):
            break
        if block_type == 0x00000006:  # Enhanced Packet Block
            _iface, _ts_hi, _ts_lo, caplen, origlen = struct.unpack_from("<IIIII", data, off + 8)
            if caplen and origlen:
                pkt = data[off + 28 : off + 28 + caplen]
                yield from _parse_ip_packet(pkt)
        off += (block_len + 3) & ~3


def _parse_ip_packet(pkt):
    if len(pkt) < 14:
        return
    ethertype = _u16(pkt, 12)
    # Ethernet II IPv4 = 0x0800; also tolerate VLAN (0x8100) + inner ethertype.
    if ethertype == 0x8100 and len(pkt) >= 18:
        ethertype = _u16(pkt, 16)
        l3 = 18
    else:
        l3 = 14
    if ethertype != 0x0800 or len(pkt) < l3 + 20:
        return
    ip_hdr_len = (pkt[l3] & 0x0F) * 4
    proto = pkt[l3 + 9]
    if proto != 6 or len(pkt) < l3 + ip_hdr_len + 20:
        return
    src_ip = ".".join(map(str, pkt[l3 + 12 : l3 + 16]))
    dst_ip = ".".join(map(str, pkt[l3 + 16 : l3 + 20]))
    tcp = l3 + ip_hdr_len
    src_port = _u16(pkt, tcp)
    dst_port = _u16(pkt, tcp + 2)
    data_off = ((pkt[tcp + 12] >> 4) & 0x0F) * 4
    payload = pkt[tcp + data_off :]
    if payload:
        yield src_ip, src_port, dst_ip, dst_port, payload


class _Stream:
    def __init__(self):
        self.buf = bytearray()

    def feed(self, payload: bytes):
        self.buf += payload


def parse_frames(buf: bytearray):
    """Greedily extract complete HCNetSDK frames (16-byte header + body)."""
    frames = []
    i = 0
    while i + 16 <= len(buf):
        total = _u32(buf, i)
        if total < 16 or total > 16 * 1024 * 1024:
            # Not a frame boundary; drop a byte and resync.
            del buf[0:1]
            i = 0
            continue
        if i + total > len(buf):
            break
        frame = bytes(buf[i : i + total])
        frames.append(frame)
        i += total
    del buf[0:i]
    return frames


def describe(frame: bytes) -> str | None:
    total = _u32(frame, 0)
    f4 = _u32(frame, 4)
    f8 = _u32(frame, 8)
    f12 = _u32(frame, 12)
    body = frame[16:total]

    if f4 == LOGIN_FAMILY:
        return f"LOGIN  len={total} f8=0x{f8:08x} f12=0x{f12:08x} body={_hex(body[:16])}…"
    if f4 == CONTROL_FAMILY:
        tail = body[16:] if len(body) >= 16 else body
        label = KNOWN_COMMANDS.get(f12, "??? (PTZ candidate?)")
        words = []
        for o in range(0, len(tail) - 3, 4):
            w = _u32(tail, o)
            if w in PTZ_WORDS:
                words.append(w)
        ptz_hint = f"  PTZ-WORDS={words}" if words else ""
        return (
            f"CTRL   cmd=0x{f12:08x} [{label}] len={total} "
            f"tail={_hex(tail)}{ptz_hint}"
        )
    # Response frame.
    return f"RESP   len={total} f4=0x{f4:08x} f8=0x{f8:08x} f12=0x{f12:08x} body={_hex(body[:48])}"


def _hex(b: bytes, limit: int = 64) -> str:
    if len(b) > limit:
        return b[:limit].hex() + f"…({len(b)}B)"
    return b.hex() or "(empty)"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]

    streams = defaultdict(_Stream)  # (ip, port) -> stream (client->server direction)
    for src_ip, src_port, dst_ip, dst_port, payload in read_packets(path):
        # Track only port-8000 traffic in either direction.
        if dst_port == 8000:
            streams[(src_ip, src_port)].feed(payload)
        elif src_port == 8000:
            streams[(dst_ip, dst_port)].feed(payload)

    print(f"capture: {path}\nreassembled {len(streams)} client->server stream(s)\n")
    shown = 0
    for (ip, port), s in sorted(streams.items()):
        frames = parse_frames(s.buf)
        for f in frames:
            d = describe(f)
            if d:
                shown += 1
                print(f"[{ip}:{port} -> cam:8000] {d}")
    if shown == 0:
        print("no HCNetSDK frames found — was the capture during a PTZ action? "
              "make sure the app is talking to the camera over LAN (not cloud).")


if __name__ == "__main__":
    main()
