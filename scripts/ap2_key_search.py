#!/usr/bin/env python3
"""Offline search for the AirPlay 2 mirroring media key.

An AP2 screen-mirroring sender completes the FairPlay handshake and the
HomeKit pair-verify, then starts the type-110 video stream without ever
sending the legacy ekey/eiv.  Which derivation turns that session material
into the AES-CTR media seed is not published.

UxPlay (built with the experimental mac-p2p profile) writes every input a
derivation could consume, plus the first encrypted video payloads, to the
file named by UXPLAY_AP2_CAPTURE.  This script replays that capture against a
large space of candidate derivations.  A hit is unambiguous: correctly
decrypted mirroring payloads parse as a chain of length-prefixed H.264 NAL
units, and nothing else does.

    python3 scripts/ap2_key_search.py <capture-file>

Add new guesses in candidate_seeds() / candidate_key_ivs() -- no device
needed to test them.
"""

import hashlib
import hmac
import itertools
import sys

# --------------------------------------------------------------------------
# Minimal AES-128 (encryption only -- CTR needs the forward direction only).
# --------------------------------------------------------------------------

SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76"
    "ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d83115"
    "04c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f84"
    "53d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa8"
    "51a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d1973"
    "60814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479"
    "e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a"
    "703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df"
    "8ca1890dbfe6426841992d0fb054bb16"
)

RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a = (a ^ 0x1B) & 0xFF
    return a


def _expand_key(key):
    assert len(key) == 16
    words = [list(key[i * 4:i * 4 + 4]) for i in range(4)]
    for i in range(4, 44):
        temp = list(words[i - 1])
        if i % 4 == 0:
            temp = temp[1:] + temp[:1]
            temp = [SBOX[b] for b in temp]
            temp[0] ^= RCON[i // 4 - 1]
        words.append([words[i - 4][j] ^ temp[j] for j in range(4)])
    return [bytes(itertools.chain.from_iterable(words[r * 4:r * 4 + 4]))
            for r in range(11)]


def _encrypt_block(round_keys, block):
    state = bytearray(x ^ y for x, y in zip(block, round_keys[0]))
    for rnd in range(1, 11):
        state = bytearray(SBOX[b] for b in state)
        # ShiftRows (state is column-major: index = 4*col + row)
        shifted = bytearray(16)
        for col in range(4):
            for row in range(4):
                shifted[4 * col + row] = state[4 * ((col + row) % 4) + row]
        state = shifted
        if rnd != 10:
            mixed = bytearray(16)
            for col in range(4):
                a = state[4 * col:4 * col + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                for row in range(4):
                    mixed[4 * col + row] = (
                        a[row] ^ t ^ _xtime(a[row] ^ a[(row + 1) % 4]))
            state = mixed
        state = bytearray(x ^ y for x, y in zip(state, round_keys[rnd]))
    return bytes(state)


def aes_ctr(key, iv, data):
    """AES-128-CTR with a full 128-bit big-endian counter, matching OpenSSL."""
    round_keys = _expand_key(key)
    counter = int.from_bytes(iv, "big")
    out = bytearray()
    for offset in range(0, len(data), 16):
        block = _encrypt_block(
            round_keys, (counter % (1 << 128)).to_bytes(16, "big"))
        chunk = data[offset:offset + 16]
        out.extend(x ^ y for x, y in zip(chunk, block))
        counter += 1
    return bytes(out)


def _self_test():
    # FIPS-197 C.1 known-answer test.
    key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    plain = bytes.fromhex("00112233445566778899aabbccddeeff")
    expect = bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")
    got = _encrypt_block(_expand_key(key), plain)
    if got != expect:
        raise SystemExit("AES self-test failed: %s" % got.hex())


# --------------------------------------------------------------------------
# HKDF-SHA512, matching pair_ap's hkdf_extract_expand.
# --------------------------------------------------------------------------

def hkdf_sha512(ikm, salt, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha512).digest()
    out = b""
    block = b""
    counter = 1
    while len(out) < length:
        block = hmac.new(
            prk, block + info + bytes([counter]), hashlib.sha512).digest()
        out += block
        counter += 1
    return out[:length]


# --------------------------------------------------------------------------
# Capture file
# --------------------------------------------------------------------------

def load_capture(path):
    values = {}
    packets = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.startswith("packet"):
                packets.append(bytes.fromhex(value))
            else:
                values[key] = value
    return values, packets


def blob(values, key):
    raw = values.get(key)
    return bytes.fromhex(raw) if raw else None


# --------------------------------------------------------------------------
# Oracle: a correctly decrypted mirroring payload is a chain of
# 4-byte-big-endian-length-prefixed NAL units covering the payload exactly.
# --------------------------------------------------------------------------

def looks_like_nalus(payload):
    offset = 0
    count = 0
    while offset < len(payload):
        if offset + 4 > len(payload):
            return False
        nalu_len = int.from_bytes(payload[offset:offset + 4], "big")
        if nalu_len <= 0 or nalu_len > len(payload) - offset - 4:
            return False
        header = payload[offset + 4]
        if header & 0x80:
            return False
        if not 1 <= (header & 0x1F) <= 23:
            return False
        offset += 4 + nalu_len
        count += 1
    return count > 0


def prefix_plausible(first16, total_len):
    """Cheap prefilter: only the first AES block is needed to reject a key."""
    nalu_len = int.from_bytes(first16[:4], "big")
    if nalu_len <= 0 or nalu_len > total_len - 4:
        return False
    header = first16[4]
    return not (header & 0x80) and 1 <= (header & 0x1F) <= 23


# --------------------------------------------------------------------------
# Candidate generation
# --------------------------------------------------------------------------

SALTS = [
    "Control-Salt", "Events-Salt", "DataStream-Salt", "Media-Salt",
    "MediaStream-Salt", "Video-Salt", "Screen-Salt", "Mirroring-Salt",
    "AirPlay-Salt", "MirroringStream-Salt", "Pair-Verify-Encrypt-Salt",
]

INFOS = [
    "Control-Write-Encryption-Key", "Control-Read-Encryption-Key",
    "Events-Write-Encryption-Key", "Events-Read-Encryption-Key",
    "DataStream-Output-Encryption-Key", "DataStream-Input-Encryption-Key",
    "MediaStream-Write-Encryption-Key", "MediaStream-Read-Encryption-Key",
    "Video-Write-Encryption-Key", "Video-Read-Encryption-Key",
    "Screen-Write-Encryption-Key", "Mirroring-Write-Encryption-Key",
    "AirPlayStreamKey", "AirPlayStreamIV",
]


def truncations(name, data):
    for size in (16, 32, 64):
        if len(data) >= size:
            yield "%s[:%d]" % (name, size), data[:size]
    if len(data) not in (16, 32, 64):
        yield name, data


def candidate_seeds(values, scid):
    """Seeds fed through UxPlay's AirPlayStreamKey/IV hashing."""
    fp_key = blob(values, "fairplay_session_key")
    keymsg = blob(values, "fairplay_keymsg")
    hkp = blob(values, "hkp_shared_secret")

    named = {}
    if fp_key:
        named["fp_key"] = fp_key
    if hkp:
        named["hkp"] = hkp
    if keymsg:
        # The trailing 20 bytes are the part the receiver echoes in fp-setup 4.
        named["keymsg_tail20"] = keymsg[-20:]
        named["keymsg_tail16"] = keymsg[-16:]
    for key, value in values.items():
        if key.startswith("hkp_ch"):
            named[key] = bytes.fromhex(value)

    for name, data in list(named.items()):
        yield from truncations(name, data)
        yield from truncations("sha512(%s)" % name, hashlib.sha512(data).digest())

    # The legacy AP2 shape: sha512(fairplay aeskey || ecdh secret)[:16].
    # With no ekey the FairPlay session key is the natural stand-in.
    if fp_key and hkp:
        for label, combined in (
            ("fp_key||hkp", fp_key + hkp),
            ("hkp||fp_key", hkp + fp_key),
        ):
            yield from truncations(label, combined)
            yield from truncations(
                "sha512(%s)" % label, hashlib.sha512(combined).digest())

    if hkp:
        scid_bytes = str(scid).encode()
        for salt in SALTS:
            for info in INFOS:
                for salt_text in {salt, salt + str(scid)}:
                    label = "hkdf(hkp,%s,%s)" % (salt_text, info)
                    yield label, hkdf_sha512(
                        hkp, salt_text.encode(), info.encode(), 32)
        for label, extra in (
            ("hkp||scid", hkp + scid_bytes),
            ("scid||hkp", scid_bytes + hkp),
        ):
            yield from truncations(
                "sha512(%s)" % label, hashlib.sha512(extra).digest())


def candidate_key_ivs(values, scid):
    """Materials used directly as (key, iv), bypassing the AirPlayStream hash."""
    hkp = blob(values, "hkp_shared_secret")
    fp_key = blob(values, "fairplay_session_key")

    pool = {}
    if hkp:
        pool["hkp"] = hkp
    for key, value in values.items():
        if key.startswith("hkp_ch"):
            pool[key] = bytes.fromhex(value)
    if hkp and fp_key:
        pool["sha512(fp_key||hkp)"] = hashlib.sha512(fp_key + hkp).digest()

    for name, data in pool.items():
        if len(data) >= 32:
            yield "direct:%s" % name, data[:16], data[16:32]
    if hkp:
        for salt in SALTS:
            for info in INFOS:
                material = hkdf_sha512(
                    hkp, (salt + str(scid)).encode(), info.encode(), 32)
                yield ("direct:hkdf(hkp,%s%s,%s)" % (salt, scid, info),
                       material[:16], material[16:32])


def stream_key_iv(seed, scid):
    key = hashlib.sha512(
        ("AirPlayStreamKey%d" % scid).encode() + seed).digest()[:16]
    iv = hashlib.sha512(
        ("AirPlayStreamIV%d" % scid).encode() + seed).digest()[:16]
    return key, iv


# --------------------------------------------------------------------------

def main():
    _self_test()

    if len(sys.argv) != 2:
        raise SystemExit("usage: ap2_key_search.py <capture-file>")

    values, packets = load_capture(sys.argv[1])
    if not packets:
        raise SystemExit("capture contains no encrypted packets")
    if "stream_connection_id" not in values:
        raise SystemExit("capture is missing stream_connection_id")

    scid = int(values["stream_connection_id"])
    packet = packets[0]
    probe = packet[:16]

    print("stream_connection_id = %d" % scid)
    print("captured packets     = %d (first is %d bytes)"
          % (len(packets), len(packet)))
    for key in sorted(values):
        if key != "stream_connection_id":
            print("  %-22s %s" % (key, values[key]))
    print()

    candidates = []
    for label, seed in candidate_seeds(values, scid):
        key, iv = stream_key_iv(seed, scid)
        candidates.append((label, key, iv))
    for label, key, iv in candidate_key_ivs(values, scid):
        candidates.append((label, key, iv))

    print("testing %d candidate derivations..." % len(candidates))

    survivors = []
    for label, key, iv in candidates:
        if prefix_plausible(aes_ctr(key, iv, probe), len(packet)):
            survivors.append((label, key, iv))

    if not survivors:
        print("\nNo candidate produced a plausible first NAL unit.")
        print("Extend candidate_seeds()/candidate_key_ivs() and re-run --")
        print("the capture is reusable, no device session needed.")
        return 1

    print("\n%d candidate(s) passed the first-block filter; "
          "validating in full:" % len(survivors))
    # UxPlay runs one continuous CTR stream across the whole session: each
    # packet resumes the keystream exactly where the previous one stopped.
    # Decrypt the concatenation, then split it back apart.
    joined = b"".join(packets)
    hit = False
    for label, key, iv in survivors:
        plain = aes_ctr(key, iv, joined)
        offset = 0
        results = []
        for encrypted in packets:
            results.append(
                looks_like_nalus(plain[offset:offset + len(encrypted)]))
            offset += len(encrypted)
        ok = all(results)
        print("  [%s] %s  (%d/%d packets valid)\n      key=%s iv=%s"
              % ("MATCH" if ok else "partial", label,
                 sum(results), len(results), key.hex(), iv.hex()))
        hit = hit or ok

    return 0 if hit else 1


if __name__ == "__main__":
    sys.exit(main())
