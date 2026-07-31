/*
 * See ap2_capture.h for why this exists.
 */

#include "ap2_capture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "threads.h"

#define AP2_CAPTURE_MAX_PACKETS 8

static mutex_handle_t capture_mutex;
static FILE *capture_file;
static int capture_state; /* 0 = unchecked, 1 = active, -1 = disabled */
static int capture_packets;

static FILE *
capture_stream(void)
{
    if (capture_state == 0) {
        /*
         * Racing initialization is not a concern: the first writer is the
         * RTSP thread recording key material, well before the mirroring
         * thread starts producing packets.
         */
        const char *path = getenv("UXPLAY_AP2_CAPTURE");
        capture_state = -1;
        if (path && path[0]) {
            capture_file = fopen(path, "w");
            if (capture_file) {
                MUTEX_CREATE(capture_mutex);
                capture_state = 1;
                fprintf(capture_file, "# uxplay ap2 capture v1\n");
                fflush(capture_file);
            } else {
                fprintf(stderr,
                        "AP2 capture: unable to open %s for writing\n", path);
            }
        }
    }
    return capture_state == 1 ? capture_file : NULL;
}

int
ap2_capture_enabled(void)
{
    return capture_stream() != NULL;
}

void
ap2_capture_str(const char *key, const char *value)
{
    FILE *out = capture_stream();
    if (!out || !key || !value) {
        return;
    }
    MUTEX_LOCK(capture_mutex);
    fprintf(out, "%s=%s\n", key, value);
    fflush(out);
    MUTEX_UNLOCK(capture_mutex);
}

void
ap2_capture_u64(const char *key, uint64_t value)
{
    FILE *out = capture_stream();
    if (!out || !key) {
        return;
    }
    MUTEX_LOCK(capture_mutex);
    fprintf(out, "%s=%llu\n", key, (unsigned long long) value);
    fflush(out);
    MUTEX_UNLOCK(capture_mutex);
}

static void
write_hex(FILE *out, const unsigned char *data, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        fprintf(out, "%02x", data[i]);
    }
}

void
ap2_capture_hex(const char *key, const unsigned char *data, size_t len)
{
    FILE *out = capture_stream();
    if (!out || !key || !data || !len) {
        return;
    }
    MUTEX_LOCK(capture_mutex);
    fprintf(out, "%s=", key);
    write_hex(out, data, len);
    fprintf(out, "\n");
    fflush(out);
    MUTEX_UNLOCK(capture_mutex);
}

void
ap2_capture_packet(const unsigned char *payload, size_t len)
{
    FILE *out = capture_stream();
    if (!out || !payload || !len) {
        return;
    }
    MUTEX_LOCK(capture_mutex);
    if (capture_packets < AP2_CAPTURE_MAX_PACKETS) {
        fprintf(out, "packet%d=", capture_packets);
        write_hex(out, payload, len);
        fprintf(out, "\n");
        fflush(out);
        capture_packets++;
    }
    MUTEX_UNLOCK(capture_mutex);
}

void
ap2_capture_close(void)
{
    if (capture_state == 1 && capture_file) {
        MUTEX_LOCK(capture_mutex);
        fclose(capture_file);
        capture_file = NULL;
        capture_state = -1;
        MUTEX_UNLOCK(capture_mutex);
    }
}
