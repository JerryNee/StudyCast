/*
 * Session-material capture for the experimental HomeKit/AP2 mirroring path.
 *
 * AirPlay 2 screen-mirroring senders complete the FairPlay handshake and the
 * HomeKit pair-verify, then start the type-110 video stream without ever
 * sending the legacy ekey/eiv.  The derivation that turns that session
 * material into the AES-CTR media seed is not published, so it has to be
 * recovered experimentally.
 *
 * Rather than guessing one derivation per physical mirroring session, dump
 * everything a derivation could possibly consume plus the first encrypted
 * video packets.  A single capture then supports an unlimited offline search
 * (see scripts/ap2_key_search.py), because a correctly decrypted packet is
 * self-evident: it parses as a chain of length-prefixed H.264 NAL units.
 *
 * Enabled only when UXPLAY_AP2_CAPTURE names an output file.
 */

#ifndef AP2_CAPTURE_H
#define AP2_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Idempotent; reads UXPLAY_AP2_CAPTURE. Returns 1 when capture is active. */
int ap2_capture_enabled(void);

void ap2_capture_str(const char *key, const char *value);
void ap2_capture_u64(const char *key, uint64_t value);
void ap2_capture_hex(const char *key, const unsigned char *data, size_t len);

/* Records at most AP2_CAPTURE_MAX_PACKETS encrypted video payloads. */
void ap2_capture_packet(const unsigned char *payload, size_t len);

void ap2_capture_close(void);

#ifdef __cplusplus
}
#endif

#endif /* AP2_CAPTURE_H */
