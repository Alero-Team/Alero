"""Generates framing.json independently of the Rust core (cross-check, not circular).
Run: py -3 -I generate_framing.py
"""
import json
import struct
from pathlib import Path


def frame(body: bytes) -> str:
    return (struct.pack(">I", len(body)) + body).hex()


def canon(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")


ping = {"type": "pb.ping", "body": {"seq": 1}}
ping_frame = frame(canon(ping))
extra = {"type": "pb.ping", "body": {"seq": 1}, "futureField": True}
extra_body = canon(extra)
max_body = 64 * 1024

cases = [
    {"id": "framing-001-ping-roundtrip", "op": "encode", "input": ping, "expected": {"hex": ping_frame}},
    {"id": "framing-002-ping-decode", "op": "decode", "input": {"hex": ping_frame},
     "expected": {"ok": ping, "consumed": len(ping_frame) // 2}},
    {"id": "framing-003-unknown-fields-kept-and-ignored", "op": "decode", "input": {"hex": frame(extra_body)},
     "expected": {"ok": extra, "consumed": 4 + len(extra_body)}},
    {"id": "framing-004-two-frames-consumes-first-only", "op": "decode", "input": {"hex": ping_frame + ping_frame},
     "expected": {"ok": ping, "consumed": len(ping_frame) // 2}},
    {"id": "framing-005-non-ascii-utf8", "op": "encode",
     "input": {"type": "pb.hello", "body": {"name": "Pixel de Ana"}},
     "expected": {"hex": frame(canon({"type": "pb.hello", "body": {"name": "Pixel de Ana"}}))}},
    {"id": "framing-neg-001-oversize-header-only", "op": "decode",
     "input": {"hex": struct.pack(">I", max_body + 1).hex()}, "expectedError": "PACKET_TOO_LARGE"},
    {"id": "framing-neg-002-max-size-boundary-is-accepted-length", "op": "decode",
     "input": {"hex": struct.pack(">I", max_body).hex()}, "expectedError": "INCOMPLETE"},
    {"id": "framing-neg-003-truncated-header", "op": "decode", "input": {"hex": "0000"}, "expectedError": "INCOMPLETE"},
    {"id": "framing-neg-004-truncated-body", "op": "decode", "input": {"hex": ping_frame[:-2]},
     "expectedError": "INCOMPLETE"},
    {"id": "framing-neg-005-invalid-utf8", "op": "decode", "input": {"hex": "00000002c328"},
     "expectedError": "INVALID_UTF8"},
    {"id": "framing-neg-006-invalid-json", "op": "decode", "input": {"hex": frame(b"{not json")},
     "expectedError": "INVALID_JSON"},
    {"id": "framing-neg-007-empty-body", "op": "decode", "input": {"hex": "00000000"}, "expectedError": "INVALID_JSON"},
    {"id": "framing-neg-008-missing-type", "op": "decode", "input": {"hex": frame(canon({"body": {}}))},
     "expectedError": "MISSING_TYPE"},
    {"id": "framing-neg-009-type-not-string", "op": "decode", "input": {"hex": frame(canon({"type": 7}))},
     "expectedError": "MISSING_TYPE"},
    {"id": "framing-neg-010-encode-missing-type", "op": "encode", "input": {"body": {}},
     "expectedError": "MISSING_TYPE"},
    {"id": "framing-neg-011-encode-oversize", "op": "encode",
     "input": {"type": "pb.x", "body": {"pad": "a" * max_body}}, "expectedError": "PACKET_TOO_LARGE"},
]

doc = {"suite": "framing", "protocolVersion": 1, "vectorsVersion": "0.1.0", "maxBody": max_body, "cases": cases}
out = Path(__file__).with_name("framing.json")
out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
print(f"wrote {out} ({len(cases)} cases)")
