/**
 *  Copyright (C) 2018  Juho Vähä-Herttua
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *===================================================================
 * modfied by fduncanh 2021-2023
 */

/* This file should be only included from raop.c as it defines static handler
 * functions and depends on raop internals */

#include "dnssdint.h"
#include "utils.h"
#include <ctype.h>
#include <stdlib.h>
#include <inttypes.h>
#include <plist/plist.h>
#define AUDIO_SAMPLE_RATE 44100   /* all supported AirPlay audio format use this sample rate */
#define SECOND_IN_USECS 1000000
#define SECOND_IN_NSECS 1000000000
#define MAX_PW_ATTEMPTS 3

typedef void (*raop_handler_t)(raop_conn_t *, http_request_t *,
                               http_response_t *, char **, int *);


static void
raop_handler_info(raop_conn_t *conn,
                  http_request_t *request, http_response_t *response,
                  char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    assert(raop->dnssd);

    /* There are three possible RTSP/1.0  GET/info requests
       (1) with a CSeq number and with a plist
       (2) with a CSeq number and without a plist
       (3) without a CSeq number or a Header (part of Bluetooth LE Service Discovery) */

    const char* url =  NULL;
    const char* content_type =  NULL;
    const char* cseq =  NULL;
    url  = http_request_get_url(request);
    content_type = http_request_get_header(request, "Content-Type");
    cseq = http_request_get_header(request, "CSeq");
    int len = 0;
    bool add_txt_airplay = false;
    bool add_txt_raop = false;
    const char txtRAOP[] = "txtRAOP";
    const char txtAirPlay[] = "txtAirPlay";


    plist_t res_node = plist_new_dict();
     
    /* initial GET/info request sends plist with string "txtAirPlay" */
    if (content_type && strstr(content_type, "application/x-apple-binary-plist")) {
        char *qualifier_string = NULL;
        const char *data = NULL;
        int data_len = 0;
        data = http_request_get_data(request, &data_len);
        //parsing bplist
        plist_t req_root_node = NULL;
        plist_from_bin(data, data_len, &req_root_node);
        plist_t req_qualifier_node = plist_dict_get_item(req_root_node, "qualifier");
        if (PLIST_IS_ARRAY(req_qualifier_node)) {
            plist_t req_string_node = plist_array_get_item(req_qualifier_node, 0);
            plist_get_string_val(req_string_node, &qualifier_string);
        }
        if (qualifier_string) {
            if (!strcmp(qualifier_string, txtAirPlay )) {
                add_txt_airplay = true;
            } else if (!strcmp(qualifier_string, txtRAOP)) {
                add_txt_raop = true;
            }
            plist_mem_free(qualifier_string);
        }
        plist_free(req_root_node);
    }
    

    /* Bluetoth LE discovery protocol request */
    if (!cseq) {
        add_txt_airplay = (bool) strstr(url, txtAirPlay);
        add_txt_raop = (bool) strstr(url, txtRAOP);
    }
    
    if (add_txt_airplay) {
        const char *txt = dnssd_get_airplay_txt(raop->dnssd, &len);
        plist_t txt_airplay_node = plist_new_data(txt, len);
        plist_dict_set_item(res_node, txtAirPlay, txt_airplay_node);
    }

    if (add_txt_raop) {
        const char *txt = dnssd_get_raop_txt(raop->dnssd, &len);
        plist_t txt_raop_node = plist_new_data(txt, len);
        plist_dict_set_item(res_node, txtRAOP, txt_raop_node);
    }
  
    /* don't need anything below here in the response to initial  "txtAirPlay" GET/info request */
    if (content_type) {
        goto finished;
    }
 
    /* deviceID is the physical hardware address, and will not change */
    int hw_addr_raw_len = 0;
    const char *hw_addr_raw = dnssd_get_hw_addr(raop->dnssd, &hw_addr_raw_len);
    char *hw_addr = calloc(1, 3 * hw_addr_raw_len);
    //int hw_addr_len =
    utils_hwaddr_airplay(hw_addr, 3 * hw_addr_raw_len, hw_addr_raw, hw_addr_raw_len);
    plist_t device_id_node = plist_new_string(hw_addr);
    plist_dict_set_item(res_node, "deviceID", device_id_node);

    plist_t mac_address_node = plist_new_string(hw_addr);
    plist_dict_set_item(res_node, "macAddress", mac_address_node);
    free(hw_addr);
   
    /* Persistent Public Key */
    int pk_len = 0;
    char *pk = utils_parse_hex(raop->pk_str, strlen(raop->pk_str), &pk_len);
    plist_t pk_node = plist_new_data(pk, pk_len);
    plist_dict_set_item(res_node, "pk", pk_node);
    free(pk);

    uint64_t features = dnssd_get_airplay_features(raop->dnssd);
    /*
     * Preserve Mac/P2P discovery and HomeKit access control, but ask the
     * sender to use UxPlay's proven legacy FairPlay media setup after the
     * encrypted control channel is established.
     */
    if (raop->hkp_enabled) {
        features = raop->hkp_legacy_media
            ? 0x527FFEE6ULL
            : 0x381607DE5A7FFEE6ULL;
        /*
         * Keep /info consistent with the advertised TXT bitmap. Reporting a
         * different feature set here does not switch the sender back to the
         * legacy ekey path -- it just stalls before the type-110 SETUP.
         */
        const char *features_override = getenv("UXPLAY_MAC_FEATURES");
        if (features_override && features_override[0]) {
            char *end = NULL;
            unsigned long long low =
                strtoull(features_override, &end, 0);
            unsigned long long high = 0;
            if (end && *end == ',') {
                high = strtoull(end + 1, NULL, 0);
            }
            features = (high << 32) | (low & 0xFFFFFFFFULL);
        }
    }
    plist_t features_node = plist_new_uint(features);
    plist_dict_set_item(res_node, "features", features_node);

    int name_len = 0;
    const char *name = dnssd_get_name(raop->dnssd, &name_len);
    plist_t name_node = plist_new_string(name);
    plist_dict_set_item(res_node, "name", name_node);

    plist_t pi_node = plist_new_string(
        raop->hkp_enabled
            ? "5c7d1d2e-79f8-4d9c-9d1a-5b7556d10006"
            : AIRPLAY_PI);
    plist_dict_set_item(res_node, "pi", pi_node);

    plist_t vv_node = plist_new_uint(strtol(AIRPLAY_VV, NULL, 10));
    plist_dict_set_item(res_node, "vv", vv_node);

    plist_t status_flags_node = plist_new_uint(
        raop->hkp_enabled ? 4 : 68);
    plist_dict_set_item(res_node, "statusFlags", status_flags_node);

    plist_t keep_alive_low_power_node = plist_new_uint(1);
    plist_dict_set_item(res_node, "keepAliveLowPower", keep_alive_low_power_node);

    plist_t source_version_node = plist_new_string(
        raop->hkp_enabled
            ? MAC_P2P_SOURCE_VERSION
            : GLOBAL_VERSION);
    plist_dict_set_item(res_node, "sourceVersion", source_version_node);

    plist_t keep_alive_send_stats_as_body_node = plist_new_bool(1);
    plist_dict_set_item(res_node, "keepAliveSendStatsAsBody", keep_alive_send_stats_as_body_node);

    plist_t model_node = plist_new_string(
        raop->hkp_enabled ? "Mac15,6" : GLOBAL_MODEL);
    plist_dict_set_item(res_node, "model", model_node);

    /* dont need anything below here in the Bluetooth LE response */
    if (cseq == NULL) {
        goto finished;
    }

    plist_t initial_volume_node = plist_new_real(raop->callbacks.audio_set_client_volume(raop->callbacks.cls)); 
    plist_dict_set_item(res_node, "initialVolume", initial_volume_node);
      
    plist_t audio_latencies_node = plist_new_array();
    plist_t audio_latencies_0_node = plist_new_dict();
    plist_t audio_latencies_0_output_latency_micros_node = plist_new_bool(0);
    plist_t audio_latencies_0_type_node = plist_new_uint(100);
    plist_t audio_latencies_0_audio_type_node = plist_new_string("default");
    plist_t audio_latencies_0_input_latency_micros_node = plist_new_uint(0);
    plist_dict_set_item(audio_latencies_0_node, "type", audio_latencies_0_type_node);
    plist_dict_set_item(audio_latencies_0_node, "inputLatencyMicros", audio_latencies_0_input_latency_micros_node);
    plist_dict_set_item(audio_latencies_0_node, "audioType", audio_latencies_0_audio_type_node);
    plist_dict_set_item(audio_latencies_0_node, "outputLatencyMicros", audio_latencies_0_output_latency_micros_node);
    plist_array_append_item(audio_latencies_node, audio_latencies_0_node);

    plist_t audio_latencies_1_node = plist_new_dict();
    plist_t audio_latencies_1_output_latency_micros_node = plist_new_bool(0);
    plist_t audio_latencies_1_type_node = plist_new_uint(101);
    plist_t audio_latencies_1_audio_type_node = plist_new_string("default");
    plist_t audio_latencies_1_input_latency_micros_node = plist_new_uint(0);
    plist_dict_set_item(audio_latencies_1_node, "type", audio_latencies_1_type_node);
    plist_dict_set_item(audio_latencies_1_node, "audioType", audio_latencies_1_audio_type_node);
    plist_dict_set_item(audio_latencies_1_node, "inputLatencyMicros", audio_latencies_1_input_latency_micros_node);
    plist_dict_set_item(audio_latencies_1_node, "outputLatencyMicros", audio_latencies_1_output_latency_micros_node);
    plist_array_append_item(audio_latencies_node, audio_latencies_1_node);
    plist_dict_set_item(res_node, "audioLatencies", audio_latencies_node);

    plist_t audio_formats_node = plist_new_array();
    plist_t audio_format_0_node = plist_new_dict();
    plist_t audio_format_0_type_node = plist_new_uint(100);
    plist_t audio_format_0_audio_input_formats_node = plist_new_uint(0x3fffffc);
    plist_t audio_format_0_audio_output_formats_node = plist_new_uint(0x3fffffc);
    plist_dict_set_item(audio_format_0_node, "audioOutputFormats", audio_format_0_audio_output_formats_node);
    plist_dict_set_item(audio_format_0_node, "type", audio_format_0_type_node);
    plist_dict_set_item(audio_format_0_node, "audioInputFormats", audio_format_0_audio_input_formats_node);
    plist_array_append_item(audio_formats_node, audio_format_0_node);

    plist_t audio_format_1_node = plist_new_dict();
    plist_t audio_format_1_type_node = plist_new_uint(101);
    plist_t audio_format_1_audio_input_formats_node = plist_new_uint(0x3fffffc);
    plist_t audio_format_1_audio_output_formats_node = plist_new_uint(0x3fffffc);
    plist_dict_set_item(audio_format_1_node, "audioOutputFormats", audio_format_1_audio_output_formats_node);
    plist_dict_set_item(audio_format_1_node, "type", audio_format_1_type_node);
    plist_dict_set_item(audio_format_1_node, "audioInputFormats", audio_format_1_audio_input_formats_node);
    plist_array_append_item(audio_formats_node, audio_format_1_node);
    plist_dict_set_item(res_node, "audioFormats", audio_formats_node);

    plist_t displays_node = plist_new_array();
    plist_t displays_0_node = plist_new_dict();
    plist_t displays_0_width_physical_node = plist_new_uint(0);
    plist_t displays_0_height_physical_node = plist_new_uint(0);
    plist_t displays_0_uuid_node = plist_new_string("e0ff8a27-6738-3d56-8a16-cc53aacee925");
    plist_t displays_0_width_node = plist_new_uint(raop->width);
    plist_t displays_0_height_node = plist_new_uint(raop->height);
    plist_t displays_0_width_pixels_node = plist_new_uint(raop->width);
    plist_t displays_0_height_pixels_node = plist_new_uint(raop->height);
    plist_t displays_0_rotation_node = plist_new_bool(0); /* set to true in AppleTV gen 3 (which has features bit 8  set */
    plist_t displays_0_refresh_rate_node = plist_new_real((double) 1.0 / raop->refreshRate);  /* set as real 0.166666  = 60hz in AppleTV gen 3 */
    plist_t displays_0_max_fps_node = plist_new_uint(raop->maxFPS);
    plist_t displays_0_overscanned_node = plist_new_bool(raop->overscanned);
    plist_t displays_0_features = plist_new_uint(14);

    plist_dict_set_item(displays_0_node, "uuid", displays_0_uuid_node);
    plist_dict_set_item(displays_0_node, "widthPhysical", displays_0_width_physical_node);
    plist_dict_set_item(displays_0_node, "heightPhysical", displays_0_height_physical_node);
    plist_dict_set_item(displays_0_node, "width", displays_0_width_node);
    plist_dict_set_item(displays_0_node, "height", displays_0_height_node);
    plist_dict_set_item(displays_0_node, "widthPixels", displays_0_width_pixels_node);
    plist_dict_set_item(displays_0_node, "heightPixels", displays_0_height_pixels_node);
    plist_dict_set_item(displays_0_node, "rotation", displays_0_rotation_node);    
    plist_dict_set_item(displays_0_node, "refreshRate", displays_0_refresh_rate_node);
    plist_dict_set_item(displays_0_node, "maxFPS", displays_0_max_fps_node);
    plist_dict_set_item(displays_0_node, "overscanned", displays_0_overscanned_node);
    plist_dict_set_item(displays_0_node, "features", displays_0_features);
    plist_array_append_item(displays_node, displays_0_node);
    plist_dict_set_item(res_node, "displays", displays_node);

 finished:
    plist_to_bin(res_node, response_data, (uint32_t *) response_datalen);
    plist_free(res_node);
    http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
}

static void
raop_handler_pairpinstart(raop_conn_t *conn,
                          http_request_t *request, http_response_t *response,
                          char **response_data, int *response_datalen) {
    raop_t *raop = conn->raop;
    logger_log(raop->logger, LOGGER_INFO, "client sent PAIR-PIN-START request");
    int pin_4 = 0;
    if (raop->pin > 9999) {
        pin_4 = raop->pin % 10000;
    } else {
        pin_4 = random_pin();
        if (pin_4 < 0) {
            logger_log(raop->logger, LOGGER_ERR, "Failed to generate random pin");
        } else {
            raop->pin = (unsigned short) pin_4 % 10000;
        }
    }
    char pin[6] = { '\0' };
    snprintf(pin, 5, "%04u", pin_4);
    if (raop->callbacks.display_pin) {
         raop->callbacks.display_pin(raop->callbacks.cls, pin);
    }
    logger_log(raop->logger, LOGGER_INFO, "*** CLIENT MUST NOW ENTER PIN = \"%s\" AS AIRPLAY PASSWORD", pin);
    /*
     * AirPlay 2 senders keep this RTSP connection alive.  An explicit
     * zero-length body marks the end of the PIN-start response; without it,
     * visionOS waits indefinitely for a body and never presents its code UI.
     */
    http_response_add_header(response, "Content-Length", "0");
}

static void
raop_handler_pairsetup_pin(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen) {
    raop_t *raop = conn->raop;
    const char *request_data = NULL;;
    int request_datalen = 0;
    bool data_is_plist = false;
    bool logger_debug = (logger_get_level(raop->logger) >= LOGGER_DEBUG);
    request_data = http_request_get_data(request, &request_datalen);
    logger_log(raop->logger, LOGGER_INFO, "client requested pair-setup-pin, datalen = %d", request_datalen);
    if (request_datalen > 0) {
        char *header_str= NULL; 
        http_request_get_header_string(request, &header_str);
        logger_log(raop->logger, LOGGER_INFO, "request header: %s", header_str);
        data_is_plist = (strstr(header_str,"apple-binary-plist") != NULL);
        free(header_str);
    }
    if (!data_is_plist) {
        logger_log(raop->logger, LOGGER_INFO, "did not receive expected plist from client, request_datalen = %d",
                  request_datalen);
        goto authentication_failed;
    }

    /* process the pair-setup-pin request */
    plist_t req_root_node = NULL;
    plist_from_bin(request_data, request_datalen, &req_root_node);
    plist_t req_method_node = plist_dict_get_item(req_root_node, "method");
    plist_t req_user_node = plist_dict_get_item(req_root_node, "user");
    plist_t req_pk_node = plist_dict_get_item(req_root_node, "pk");
    plist_t req_proof_node = plist_dict_get_item(req_root_node, "proof");
    plist_t req_epk_node = plist_dict_get_item(req_root_node, "epk");
    plist_t req_authtag_node = plist_dict_get_item(req_root_node, "authTag");
  
    if (PLIST_IS_STRING(req_method_node) && PLIST_IS_STRING(req_user_node)) {
        /* this is the initial pair-setup-pin request */
        const char *salt = NULL;
        char pin[6] = { '\0' };
        const char *pk = NULL;
        int len_pk = 0, len_salt = 0;
        char *method = NULL;
        char *user = NULL;
        plist_get_string_val(req_method_node, &method);
        if (strncmp(method, "pin", strlen (method))) {
            logger_log(raop->logger, LOGGER_ERR, "error, required method is \"pin\", client requested \"%s\"", method);
            free (method);
            plist_free (req_root_node);
            return;
        }
        plist_mem_free(method);
        method = NULL;
        plist_get_string_val(req_user_node, &user);
        logger_log(raop->logger, LOGGER_INFO, "pair-setup-pin:  device_id = %s", user);
        snprintf(pin, 6, "%04u", raop->pin % 10000);
        if (raop->pin < 10000) {
            raop->pin = 0;
        }
        int ret = srp_new_user(conn->session, raop->pairing, (const char *) user,
                               (const char *) pin, &salt, &len_salt, &pk, &len_pk);
        plist_mem_free(user);
        user = NULL;
        plist_free(req_root_node);
        if (ret < 0) {
            logger_log(raop->logger, LOGGER_ERR, "failed to create user, err = %d", ret);
            goto authentication_failed;
        }
        plist_t res_root_node = plist_new_dict();
        plist_t res_salt_node = plist_new_data(salt, len_salt);
        plist_t res_pk_node = plist_new_data(pk, len_pk);
        plist_dict_set_item(res_root_node, "pk", res_pk_node);	
        plist_dict_set_item(res_root_node, "salt", res_salt_node);
        plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);
        plist_free(res_root_node);
        http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
        return;
    } else if (PLIST_IS_DATA(req_pk_node) && PLIST_IS_DATA(req_proof_node)) {
        /* this is the second part of pair-setup-pin request */
        char *client_pk = NULL;
        char *client_proof = NULL;
        unsigned char proof[64] = { '\0' };
        memset(proof, 0, sizeof(proof));
        uint64_t client_pk_len = 0;
        uint64_t client_proof_len = 0;
        plist_get_data_val(req_pk_node, &client_pk, &client_pk_len); 
        plist_get_data_val(req_proof_node, &client_proof, &client_proof_len);
        if (logger_debug) {
            char *str = utils_data_to_string((const unsigned char *) client_proof, client_proof_len, 20);
            logger_log(raop->logger, LOGGER_DEBUG, "client SRP6a proof <M> :\n%s", str);	    
            free (str);
        }
        memcpy(proof, client_proof, (int) client_proof_len);
        free (client_proof);
        int ret = srp_validate_proof(conn->session, raop->pairing, (const unsigned char *) client_pk,
                                     (int) client_pk_len, proof, (int) client_proof_len, (int) sizeof(proof));
        free (client_pk);
        plist_free(req_root_node);
        if (ret < 0) {
            logger_log(raop->logger, LOGGER_ERR, "Client Authentication Failure (client proof not validated)");
            goto authentication_failed;
        }
        if (logger_debug) {
	    char *str = utils_data_to_string((const unsigned char *) proof, sizeof(proof), 20);
            logger_log(raop->logger, LOGGER_DEBUG, "server SRP6a proof <M1> :\n%s", str);
            free (str);
        }
        plist_t res_root_node = plist_new_dict();
        plist_t res_proof_node = plist_new_data((const char *) proof, 20);
        plist_dict_set_item(res_root_node, "proof", res_proof_node);	
        plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);
        plist_free(res_root_node);
        http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
        return;
    } else if (PLIST_IS_DATA(req_epk_node) && PLIST_IS_DATA(req_authtag_node)) {
        /* this is the third part of pair-setup-pin request */
        char *client_epk = NULL;
        char *client_authtag = NULL;
        uint64_t client_epk_len = 0;
        uint64_t client_authtag_len = 0;
        unsigned char epk[ED25519_KEY_SIZE];
        unsigned char authtag[GCM_AUTHTAG_SIZE];
        int ret = 0;
        plist_get_data_val(req_epk_node, &client_epk, &client_epk_len); 
        plist_get_data_val(req_authtag_node, &client_authtag, &client_authtag_len);

        if (logger_debug) {
            char *str = utils_data_to_string((const unsigned char *) client_epk, client_epk_len, 16);
            logger_log(raop->logger, LOGGER_DEBUG, "client_epk %d:\n%s\n", (int) client_epk_len, str);
            str = utils_data_to_string((const unsigned char *) client_authtag, client_authtag_len, 16);
            logger_log(raop->logger, LOGGER_DEBUG, "client_authtag  %d:\n%s\n", (int) client_authtag_len, str);
            free (str);
        }

        memcpy(epk, client_epk, ED25519_KEY_SIZE);
        memcpy(authtag, client_authtag, GCM_AUTHTAG_SIZE);
        free (client_authtag);
        free (client_epk);
        plist_free(req_root_node);
        ret = srp_confirm_pair_setup(conn->session, raop->pairing, epk, authtag);
        if (ret < 0) {
            logger_log(raop->logger, LOGGER_ERR, "pair-pin-setup (step 3): client authentication failed\n");
            goto authentication_failed;
        } else {
            logger_log(raop->logger, LOGGER_DEBUG, "pair-pin-setup success\n");
        }
        pairing_session_set_setup_status(conn->session);
        plist_t res_root_node = plist_new_dict();
        plist_t res_epk_node = plist_new_data((const char *) epk, 32);
        plist_t res_authtag_node = plist_new_data((const char *) authtag, 16);
        plist_dict_set_item(res_root_node, "epk", res_epk_node);
        plist_dict_set_item(res_root_node, "authTag", res_authtag_node);	
        plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);
        plist_free(res_root_node);
        http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
        return;
    }
 authentication_failed:;
    http_response_init(response, "RTSP/1.0", 470, "Client Authentication Failure");
}

static bool
raop_request_uses_hkp(http_request_t *request)
{
    const char *hkp = http_request_get_header(request, "X-Apple-HKP");
    const char *content_type = http_request_get_header(request, "Content-Type");
    return hkp || (content_type &&
        (strstr(content_type, "pairing+tlv8") ||
         strstr(content_type, "application/octet-stream")));
}

static int
raop_hkp_tlv_state(const uint8_t *data, size_t datalen)
{
    if (data && datalen >= 3 && data[0] == 6 && data[1] == 1) {
        return data[2];
    }
    return -1;
}

static void
raop_hkp_store_shared_secret(raop_conn_t *conn,
                             const uint8_t *secret, size_t secret_len)
{
    if (!secret_len) {
        return;
    }
    if (secret_len > sizeof(conn->hkp_shared_secret)) {
        secret_len = sizeof(conn->hkp_shared_secret);
    }
    memcpy(conn->hkp_shared_secret, secret, secret_len);
    conn->hkp_shared_secret_len = secret_len;
}

static void
raop_handler_pairsetup_hkp(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *data = NULL;
    int datalen = 0;
    uint8_t *body = NULL;
    size_t body_len = 0;

    data = http_request_get_data(request, &datalen);
    logger_log(raop->logger, LOGGER_INFO,
               "HomeKit pair-setup request, state = %d, datalen = %d",
               raop_hkp_tlv_state((const uint8_t *) data, (size_t) datalen),
               datalen);

    if (!conn->hkp_setup) {
        char pin[5] = {0};
        unsigned int pin_value = raop->pin % 10000;
        if (!pin_value) {
            pin_value = 3939;
        }
        snprintf(pin, sizeof(pin), "%04u", pin_value);
        conn->hkp_setup = pair_setup_new(
            PAIR_SERVER_HOMEKIT, pin, hkp_store_client, conn,
            raop->hkp_device_id);
        if (!conn->hkp_setup) {
            logger_log(raop->logger, LOGGER_ERR,
                       "Unable to create HomeKit pair-setup context");
            http_response_init(response, "RTSP/1.0", 500,
                               "Internal Server Error");
            return;
        }
    }

    int ret = pair_setup(&body, &body_len, conn->hkp_setup,
                         (const uint8_t *) data, (size_t) datalen);
    logger_log(raop->logger, LOGGER_INFO,
               "HomeKit pair-setup response, ret = %d, state = %d, "
               "datalen = %zu",
               ret, raop_hkp_tlv_state(body, body_len), body_len);
    if (ret < 0) {
        logger_log(raop->logger, LOGGER_ERR,
                   "HomeKit pair-setup failed: %s",
                   pair_setup_errmsg(conn->hkp_setup));
        http_response_init(response, "RTSP/1.0", 470,
                           "Connection Authorization Required");
        free(body);
        return;
    }

    struct pair_result *result = NULL;
    ret = pair_setup_result(NULL, &result, conn->hkp_setup);
    if (ret == 0 && result && result->shared_secret_len > 0 &&
        !conn->hkp_control_cipher) {
        conn->hkp_setup_result = result;
        /*
         * A transient pair-setup produces the session secret here rather than
         * in pair-verify. Record it either way, otherwise the media-key
         * candidates and the event channel are both left without a secret and
         * the sender never starts the mirroring stream.
         */
        raop_hkp_store_shared_secret(
            conn, result->shared_secret, result->shared_secret_len);
        conn->hkp_control_cipher = pair_cipher_new(
            PAIR_SERVER_HOMEKIT, 3, result->shared_secret,
            result->shared_secret_len, "");
        if (!conn->hkp_control_cipher) {
            logger_log(raop->logger, LOGGER_ERR,
                       "Unable to create HomeKit control cipher");
            free(body);
            http_response_init(response, "RTSP/1.0", 500,
                               "Internal Server Error");
            return;
        }
        conn->hkp_cipher_pending = true;
        logger_log(raop->logger, LOGGER_INFO,
                   "HomeKit transient pair-setup completed");
    } else if (ret == 0) {
        conn->hkp_setup_result = result;
        logger_log(raop->logger, LOGGER_INFO,
                   "HomeKit normal pair-setup completed");
    }

    *response_data = (char *) body;
    *response_datalen = (int) body_len;
    http_response_add_header(response, "Content-Type",
                             "application/octet-stream");
}

static void
raop_handler_pairverify_hkp(raop_conn_t *conn,
                            http_request_t *request, http_response_t *response,
                            char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *data = NULL;
    int datalen = 0;
    uint8_t *body = NULL;
    size_t body_len = 0;

    data = http_request_get_data(request, &datalen);
    logger_log(raop->logger, LOGGER_INFO,
               "HomeKit pair-verify request, state = %d, datalen = %d",
               raop_hkp_tlv_state((const uint8_t *) data, (size_t) datalen),
               datalen);

    if (!conn->hkp_verify) {
        conn->hkp_verify = pair_verify_new(
            PAIR_SERVER_HOMEKIT, NULL, hkp_get_client, conn,
            raop->hkp_device_id);
        if (!conn->hkp_verify) {
            logger_log(raop->logger, LOGGER_ERR,
                       "Unable to create HomeKit pair-verify context");
            http_response_init(response, "RTSP/1.0", 500,
                               "Internal Server Error");
            return;
        }
    }

    int ret = pair_verify(&body, &body_len, conn->hkp_verify,
                          (const uint8_t *) data, (size_t) datalen);
    logger_log(raop->logger, LOGGER_INFO,
               "HomeKit pair-verify response, ret = %d, state = %d, "
               "datalen = %zu",
               ret, raop_hkp_tlv_state(body, body_len), body_len);
    if (ret < 0) {
        logger_log(raop->logger, LOGGER_ERR,
                   "HomeKit pair-verify failed: %s",
                   pair_verify_errmsg(conn->hkp_verify));
        http_response_init(response, "RTSP/1.0", 470,
                           "Connection Authorization Required");
        free(body);
        return;
    }

    struct pair_result *result = NULL;
    ret = pair_verify_result(&result, conn->hkp_verify);
    /*
     * Keep the verify secret even when a transient pair-setup already built
     * the control cipher -- it is still a media-key candidate.
     */
    if (ret == 0 && result) {
        raop_hkp_store_shared_secret(
            conn, result->shared_secret, result->shared_secret_len);
    }
    if (ret == 0 && result && result->shared_secret_len > 0 &&
        !conn->hkp_control_cipher) {
        conn->hkp_control_cipher = pair_cipher_new(
            PAIR_SERVER_HOMEKIT, 3, result->shared_secret,
            result->shared_secret_len, "");
        if (!conn->hkp_control_cipher) {
            logger_log(raop->logger, LOGGER_ERR,
                       "Unable to create HomeKit verify control cipher");
            free(body);
            http_response_init(response, "RTSP/1.0", 500,
                               "Internal Server Error");
            return;
        }
        conn->hkp_cipher_pending = true;
        logger_log(raop->logger, LOGGER_INFO,
                   "HomeKit pair-verify completed");
    }

    *response_data = (char *) body;
    *response_datalen = (int) body_len;
    http_response_add_header(response, "Content-Type",
                             "application/octet-stream");
}

static void
raop_handler_pairsetup(raop_conn_t *conn,
                       http_request_t *request, http_response_t *response,
                       char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    unsigned char public_key[ED25519_KEY_SIZE];
    const char *data;
    int datalen = 0;

    data = http_request_get_data(request, &datalen);
    if (raop->hkp_enabled &&
        (raop_request_uses_hkp(request) || datalen != 32)) {
        raop_handler_pairsetup_hkp(conn, request, response,
                                   response_data, response_datalen);
        return;
    }
    if (datalen != 32) {
        logger_log(raop->logger, LOGGER_ERR,
                   "Invalid pair-setup data length: expected 32, received %d",
                   datalen);
        if (data && datalen > 0) {
            int dump_len = datalen > 128 ? 128 : datalen;
            char *dump = utils_data_to_string(
                (const unsigned char *) data, dump_len, 16);
            if (dump) {
                logger_log(raop->logger, LOGGER_INFO,
                           "pair-setup payload (first %d bytes):\n%s",
                           dump_len, dump);
                free(dump);
            }
        }
        return;
    }

    pairing_get_public_key(raop->pairing, public_key);
    pairing_session_set_setup_status(conn->session);

    *response_data = calloc(1, sizeof(public_key));
    if (*response_data) {
        http_response_add_header(response, "Content-Type", "application/octet-stream");
        memcpy(*response_data, public_key, sizeof(public_key));
        *response_datalen = sizeof(public_key);
    }
}

static void
raop_handler_pairverify(raop_conn_t *conn,
                        http_request_t *request, http_response_t *response,
                        char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    bool register_check = false;  
    if (pairing_session_check_handshake_status(conn->session)) {
        if (raop->use_pin) {
            pairing_session_set_setup_status(conn->session);
            register_check = true;
        } else {
            return;
        }
    }
    unsigned char public_key[X25519_KEY_SIZE];
    unsigned char signature[PAIRING_SIG_SIZE];
    const unsigned char *data = NULL;
    int datalen = 0;

    data = (unsigned char *) http_request_get_data(request, &datalen);
    if (raop->hkp_enabled && raop_request_uses_hkp(request)) {
        raop_handler_pairverify_hkp(conn, request, response,
                                    response_data, response_datalen);
        return;
    }
    if (datalen < 4) {
        logger_log(raop->logger, LOGGER_ERR, "Invalid pair-verify data");
        return;
    }
    switch (data[0]) {
    case 1:
        if (datalen != 4 + X25519_KEY_SIZE + ED25519_KEY_SIZE) {
            logger_log(raop->logger, LOGGER_ERR, "Invalid pair-verify data");
            return;
        }
        /* We can fall through these errors, the result will just be garbage... */
        if (pairing_session_handshake(conn->session, data + 4, data + 4 + X25519_KEY_SIZE)) {
            logger_log(raop->logger, LOGGER_ERR, "Error initializing pair-verify handshake");
        }
        if (pairing_session_get_public_key(conn->session, public_key)) {
            logger_log(raop->logger, LOGGER_ERR, "Error getting ECDH public key");
        }
        if (pairing_session_get_signature(conn->session, signature)) {
            logger_log(raop->logger, LOGGER_ERR, "Error getting ED25519 signature");
        }
        if (register_check) {
            bool registered_client = true;
            if (raop->callbacks.check_register) {
                const unsigned char *pk = data + 4 + X25519_KEY_SIZE;
                char *pk64 = NULL;
                ed25519_pk_to_base64(pk, &pk64);
                registered_client = raop->callbacks.check_register(raop->callbacks.cls, pk64);
                free (pk64);
            }

            if (!registered_client) {
                return;
            }
        }
        *response_data = calloc(1, sizeof(public_key) + sizeof(signature));
        if (*response_data) {
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            memcpy(*response_data, public_key, sizeof(public_key));
            memcpy(*response_data + sizeof(public_key), signature, sizeof(signature));
            *response_datalen = sizeof(public_key) + sizeof(signature);
        }
        break;
    case 0:
        logger_log(raop->logger, LOGGER_DEBUG, "2nd pair-verify step: checking signature");
        if (datalen != 4 + PAIRING_SIG_SIZE) {
            logger_log(raop->logger, LOGGER_ERR, "Invalid pair-verify data");
            return;
        }

        if (pairing_session_finish(conn->session, data + 4)) {
            logger_log(raop->logger, LOGGER_ERR, "Incorrect pair-verify signature");
            http_response_set_disconnect(response, 1);
            return;
        }
        logger_log(raop->logger, LOGGER_DEBUG, "pair-verify: signature is verified");	    
        http_response_add_header(response, "Content-Type", "application/octet-stream");
        break;
    }
}

static void
raop_handler_fpsetup(raop_conn_t *conn,
                     http_request_t *request, http_response_t *response,
                     char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;  
    const unsigned char *data = NULL;
    int datalen = 0;

    data = (unsigned char *) http_request_get_data(request, &datalen);
    if (datalen == 16) {
        *response_data = calloc(142, sizeof(char));
        if (*response_data) {
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            if (!fairplay_setup(conn->fairplay, data, (unsigned char *) *response_data)) {
                *response_datalen = 142;
            } else {
                // Handle error?
                free(*response_data);
                *response_data = NULL;
            }
        }
    } else if (datalen == 164) {
        *response_data = calloc(32, sizeof(char));
        if (*response_data) {
            http_response_add_header(response, "Content-Type", "application/octet-stream");
            if (!fairplay_handshake(conn->fairplay, data, (unsigned char *) *response_data)) {
                *response_datalen = 32;
            } else {
                // Handle error?
                free(*response_data);
                *response_data = NULL;
            }
        }
    } else {
        logger_log(raop->logger, LOGGER_ERR, "Invalid fp-setup data length");
        return;
    }
}

static void
raop_handler_options(raop_conn_t *conn,
                     http_request_t *request, http_response_t *response,
                     char **response_data, int *response_datalen)
{
    http_response_add_header(response, "Public", "SETUP, RECORD, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER");
}

static void
hkp_add_digest_candidates(raop_rtp_mirror_t *mirror,
                          const unsigned char *seed, size_t seed_len,
                          const char *prefix)
{
    unsigned char digest[64] = { 0 };
    char name[48] = { 0 };
    sha_ctx_t *ctx = sha_init();
    sha_update(ctx, seed, (int) seed_len);
    sha_final(ctx, digest, NULL);
    sha_destroy(ctx);

    snprintf(name, sizeof(name), "%s-sha512-16", prefix);
    raop_rtp_mirror_add_aes_candidate(mirror, digest, 16, name);
    snprintf(name, sizeof(name), "%s-sha512-32", prefix);
    raop_rtp_mirror_add_aes_candidate(mirror, digest, 32, name);
    snprintf(name, sizeof(name), "%s-sha512-64", prefix);
    raop_rtp_mirror_add_aes_candidate(mirror, digest, 64, name);
    memset(digest, 0, sizeof(digest));
}

static void
hkp_add_mirror_candidates(raop_conn_t *conn,
                          raop_rtp_mirror_t *mirror,
                          const unsigned char fairplay_key[16],
                          bool have_fairplay_key)
{
    if (have_fairplay_key) {
        raop_rtp_mirror_add_aes_candidate(
            mirror, fairplay_key, 16, "fairplay-session-16");
    }

    if (conn->hkp_shared_secret_len > 0) {
        size_t secret_len = conn->hkp_shared_secret_len;
        if (secret_len >= 16) {
            raop_rtp_mirror_add_aes_candidate(
                mirror, conn->hkp_shared_secret, 16, "hkp-secret-16");
        }
        raop_rtp_mirror_add_aes_candidate(
            mirror, conn->hkp_shared_secret, secret_len, "hkp-secret-full");
        hkp_add_digest_candidates(
            mirror, conn->hkp_shared_secret, secret_len, "hkp");

        if (have_fairplay_key && secret_len <= 48) {
            unsigned char combination[64] = { 0 };
            memcpy(combination, fairplay_key, 16);
            memcpy(combination + 16, conn->hkp_shared_secret, secret_len);
            raop_rtp_mirror_add_aes_candidate(
                mirror, combination, 16 + secret_len, "fairplay+hkp");
            hkp_add_digest_candidates(
                mirror, combination, 16 + secret_len, "fairplay+hkp");

            memset(combination, 0, sizeof(combination));
            memcpy(combination, conn->hkp_shared_secret, secret_len);
            memcpy(combination + secret_len, fairplay_key, 16);
            raop_rtp_mirror_add_aes_candidate(
                mirror, combination, secret_len + 16, "hkp+fairplay");
            hkp_add_digest_candidates(
                mirror, combination, secret_len + 16, "hkp+fairplay");
            memset(combination, 0, sizeof(combination));
        }

        for (int channel = 0; channel <= 5; channel++) {
            struct pair_cipher_context *cipher = pair_cipher_new(
                PAIR_SERVER_HOMEKIT, channel, conn->hkp_shared_secret,
                secret_len, "");
            if (!cipher) {
                continue;
            }
            unsigned char encryption_key[32] = { 0 };
            unsigned char decryption_key[32] = { 0 };
            if (pair_cipher_get_keys(
                    encryption_key, decryption_key, cipher) == 0) {
                char name[48] = { 0 };
                snprintf(name, sizeof(name), "hkp-ch%d-encrypt-16",
                         channel);
                raop_rtp_mirror_add_aes_candidate(
                    mirror, encryption_key, 16, name);
                snprintf(name, sizeof(name), "hkp-ch%d-encrypt-32",
                         channel);
                raop_rtp_mirror_add_aes_candidate(
                    mirror, encryption_key, 32, name);
                snprintf(name, sizeof(name), "hkp-ch%d-decrypt-16",
                         channel);
                raop_rtp_mirror_add_aes_candidate(
                    mirror, decryption_key, 16, name);
                snprintf(name, sizeof(name), "hkp-ch%d-decrypt-32",
                         channel);
                raop_rtp_mirror_add_aes_candidate(
                    mirror, decryption_key, 32, name);
            }
            memset(encryption_key, 0, sizeof(encryption_key));
            memset(decryption_key, 0, sizeof(decryption_key));
            pair_cipher_free(cipher);
        }
    }

    raop_rtp_mirror_enable_aes_probe(mirror);
}

static void
raop_handler_setup(raop_conn_t *conn,
                   http_request_t *request, http_response_t *response,
                   char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *dacp_id = NULL;
    const char *active_remote_header = NULL;
    bool logger_debug = (logger_get_level(raop->logger) >= LOGGER_DEBUG);
    
    const char *data = NULL;
    int data_len = 0;
    data = http_request_get_data(request, &data_len);

    dacp_id = http_request_get_header(request, "DACP-ID");
    active_remote_header = http_request_get_header(request, "Active-Remote");

    if (dacp_id && active_remote_header) {
        logger_log(raop->logger, LOGGER_DEBUG, "DACP-ID: %s", dacp_id);
        logger_log(raop->logger, LOGGER_DEBUG, "Active-Remote: %s", active_remote_header);
        if (conn->raop_rtp) {
            raop_rtp_remote_control_id(conn->raop_rtp, dacp_id, active_remote_header);
        }
    }

    // Parsing bplist
    plist_t req_root_node = NULL;
    plist_from_bin(data, data_len, &req_root_node);
    plist_t req_ekey_node = plist_dict_get_item(req_root_node, "ekey");
    plist_t req_eiv_node = plist_dict_get_item(req_root_node, "eiv");
	
    // For the response
    plist_t res_root_node = plist_new_dict();

    if (PLIST_IS_DATA(req_eiv_node) && PLIST_IS_DATA(req_ekey_node)) {
        // The first SETUP call that initializes keys and timing

        unsigned char aesiv[16] = { 0 };
        unsigned char aeskey[16] = { 0 };
        unsigned char eaeskey[72] = { 0 };

        logger_log(raop->logger, LOGGER_DEBUG, "SETUP 1");

        // First setup

        char *deviceID = NULL;
        plist_t req_deviceid_node = plist_dict_get_item(req_root_node, "deviceID");
        plist_get_string_val(req_deviceid_node, &deviceID);  


        /* RFC2617 Digest authentication (md5 hash) of uxplay client-access password, if set */
        if (!conn->authenticated && raop->callbacks.passwd) {
            size_t pin_len = 4;
            const char *authorization = NULL;
            authorization = http_request_get_header(request, "Authorization");
            if (!authorization) {
                // if random_pw is set, but client has changed, unset it 
                if (raop->random_pw && strncmp(raop->random_pw + pin_len + 1,  deviceID, 17)) {
                    free(raop->random_pw);
                    raop->random_pw = NULL;
                }
            }
            int len = 0;
            const char *password = raop->callbacks.passwd(raop->callbacks.cls, &len);
            // len = -1 means use a random password for this connection; len = 0 means no password
            if (len == -1 && raop->random_pw && raop->auth_fail_count >= MAX_PW_ATTEMPTS) {
                // change random_pw after MAX_PW_ATTEMPTS  failed authentication attempts
                logger_log(raop->logger, LOGGER_INFO, "Too many authentication failures: generate new random password");
                free(raop->random_pw);
                raop->random_pw = NULL;
            }
            if (len == -1 && !raop->random_pw) {
                // get and store 4 random digits
                int pin_4  = random_pin();
                if (pin_4 < 0) {
                    logger_log(raop->logger, LOGGER_ERR, "Failed to generate random pin");
                    pin_4 = 1234;
                }
                if ((raop->random_pw =  (char *) calloc(pin_len + 1 + 18, sizeof(char)))) {
                    char *pin = raop->random_pw;
                    snprintf(pin, pin_len + 1, "%04u", pin_4 % 10000);
                    pin[pin_len] = '\0';
                    snprintf(pin + pin_len + 1, 18, "%s", deviceID);
                } else {
                    logger_log(raop->logger, LOGGER_ERR, "Failed to allocate raop->random_pw");
                }
                raop->auth_fail_count = 0;
            }
            if (len == -1 && !authorization && raop->random_pw) {
                if (raop->callbacks.display_pin) {
                    raop->callbacks.display_pin(raop->callbacks.cls, raop->random_pw);
                }
                logger_log(raop->logger, LOGGER_INFO, "*** CLIENT MUST NOW ENTER PIN = \"%s\" AS AIRPLAY PASSWORD", raop->random_pw);
                raop->auth_fail_count++;
            }
	    if (len && !conn->authenticated) {
 	        if (len == -1) {
                    password = (const char *) raop->random_pw;
                }
                char nonce_string[33] = { '\0' };
                //bool stale = false;  //not implemented
                if (len && authorization) {
                    const char *ptr = strstr(authorization, "nonce=\"") +  strlen("nonce=\"");
                    strncpy(nonce_string, ptr, 32);
                    const char *method = http_request_get_method(request);
                    conn->authenticated = pairing_digest_verify(method, authorization, password);
		    if (!conn->authenticated) {
                        // if random_pw is used, the auth_fail_count will be the number of times it is displayed after creation
                        if (len != -1) {
                            raop->auth_fail_count++;
                        }
                        logger_log(raop->logger, LOGGER_INFO, "*** authentication failure: count = %u", raop->auth_fail_count);
                    }
                    if (conn->authenticated) {
                        //printf("initial authenticatication OK\n");
                        conn->authenticated = conn->authenticated && !strcmp(nonce_string, raop->nonce);
                        if (!conn->authenticated) {
                            logger_log(raop->logger, LOGGER_INFO, "authentication rejected (nonce mismatch) %s %s",
                                       nonce_string, raop->nonce);
                        }			
                    }
                    if (conn->authenticated && raop->random_pw) {
                        free (raop->random_pw);
                        raop->random_pw = NULL;
                    }
                    if (raop->nonce) {
                        free(raop->nonce);
                        raop->nonce = NULL;
                    }
                    logger_log(raop->logger, LOGGER_INFO, "Client authentication %s", (conn->authenticated ? "success" : "failure"));
                }
                if (!conn->authenticated) {
                    /* create a nonce */
                    const char *url = http_request_get_url(request);
                    unsigned char nonce[16] = { '\0' };
                    int len = 16;
                    uint64_t now = raop_ntp_get_local_time();
                    assert (!pairing_session_make_nonce(conn->session, &now, url, nonce, len));
                    if (raop->nonce) {
                        free(raop->nonce);
                    }
                    raop->nonce = utils_hex_to_string(nonce, len);
                    char response_text[80] = "Digest realm=\"raop\", nonce=\"";
                    strncat(response_text, raop->nonce, 80 - strlen(response_text) - 1);
                    strncat(response_text, "\"", 80 - strlen(response_text) - 1);
                    http_response_init(response, "RTSP/1.0", 401, "Unauthorized");
                    http_response_add_header(response, "WWW-Authenticate", response_text);
                    return;
                }
            }
        }
	
        char* eiv = NULL;
        uint64_t eiv_len = 0;
        char *model = NULL;
        char *name = NULL;
        bool admit_client = true;
        plist_t req_model_node = plist_dict_get_item(req_root_node, "model");
        plist_get_string_val(req_model_node, &model);  
        plist_t req_name_node = plist_dict_get_item(req_root_node, "name");
        plist_get_string_val(req_name_node, &name);  
        if (raop->callbacks.report_client_request) {
            raop->callbacks.report_client_request(raop->callbacks.cls, deviceID, model, name, &admit_client);
        }
        if (admit_client && deviceID && name && raop->callbacks.register_client) {
            char *client_device_id = NULL;
            char *client_pk = NULL;   /* encoded as null-terminated  base64 string, must be freed*/
            get_pairing_session_client_data(conn->session, &client_device_id, &client_pk);
            if (client_pk && !strcmp(deviceID, client_device_id)) { 
                raop->callbacks.register_client(raop->callbacks.cls, client_device_id, client_pk, name); 
                free (client_pk);
            }
        }
        plist_mem_free(deviceID);
        deviceID = NULL;
        plist_mem_free(model);
        model = NULL;
        plist_mem_free(name);
        name = NULL;
        if (admit_client == false) {
            /* client is not authorized to connect */
            plist_free(res_root_node);
            plist_free(req_root_node);
            return;
        }

        plist_get_data_val(req_eiv_node, &eiv, &eiv_len);
        memcpy(aesiv, eiv, 16);
        free(eiv);	
        logger_log(raop->logger, LOGGER_DEBUG, "eiv_len = %llu", eiv_len);
        if (logger_debug) {
            char* str = utils_data_to_string(aesiv, 16, 16);
            logger_log(raop->logger, LOGGER_DEBUG, "16 byte aesiv (needed for AES-CBC audio decryption iv):\n%s", str);
            free(str);
        }

        char* ekey = NULL;
        uint64_t ekey_len = 0;
        plist_get_data_val(req_ekey_node, &ekey, &ekey_len);
        memcpy(eaeskey,ekey,72);
        free(ekey);
        logger_log(raop->logger, LOGGER_DEBUG, "ekey_len = %llu", ekey_len);
        // eaeskey is 72 bytes, aeskey is 16 bytes
        if (logger_debug) {
            char *str = utils_data_to_string((unsigned char *) eaeskey, ekey_len, 16);
            logger_log(raop->logger, LOGGER_DEBUG, "ekey:\n%s", str);
            free (str);
        }
        int ret = fairplay_decrypt(conn->fairplay, (unsigned char*) eaeskey, aeskey);
        logger_log(raop->logger, LOGGER_DEBUG, "fairplay_decrypt ret = %d", ret);
        if (logger_debug) {
            char *str = utils_data_to_string(aeskey, 16, 16);
            logger_log(raop->logger, LOGGER_DEBUG, "16 byte aeskey (fairplay-decrypted from ekey):\n%s", str);
            free(str);
        }

        const char *user_agent = http_request_get_header(request, "User-Agent");
        logger_log(raop->logger, LOGGER_INFO, "Client identified as User-Agent: %s", user_agent);	

        bool old_protocol = false;
#ifdef OLD_PROTOCOL_CLIENT_USER_AGENT_LIST    /* set in global.h */
        if (strstr(OLD_PROTOCOL_CLIENT_USER_AGENT_LIST, user_agent)) old_protocol = true;
        if (strstr(user_agent, "AirMyPC")) old_protocol = true;   //AirMyPC/7200 still uses old protocol: unlikely to change (?)
#endif
        if  (old_protocol) {    /* some windows AirPlay-client emulators use old AirPlay 1 protocol with unhashed AES key */
            logger_log(raop->logger, LOGGER_INFO, "Client identifed as using old protocol (unhashed) AES audio key)");
        } else {
            unsigned char ecdh_secret[X25519_KEY_SIZE];
            if (pairing_get_ecdh_secret_key(conn->session, ecdh_secret)) {
                /* In this case  (legacy) pairing with client was successfully set up and created the shared ecdh_secret:
                 * aeskey must now be hashed with it
                 *
                 * If byte 27 of features ("supports legacy pairing") is turned off, the client does not request pairsetup
                 * and does NOT set up pairing (this eliminates a 5 second delay in connecting with no apparent bad effects).
                 * In this case, ecdh_secret does not exist, so aeskey should NOT be hashed with it.

                 * UxPlay may be able to function with byte 27 turned off because it currently does not support connections 
                 * with more than one client at a time. AppleTV supports up to 12 clients, uses pairing to give each a distinct
                 * SessionID and ecdh_secret.
            
                 * The "old protocol" Windows AirPlay client AirMyPC seems not to respect the byte 27 setting, and always sets
                 * up the  ecdh_secret, but decryption fails if aeskey is hashed.*/

                if (logger_debug) {
                    char *str = utils_data_to_string(ecdh_secret, X25519_KEY_SIZE, 16);
                    logger_log(raop->logger, LOGGER_DEBUG, "32 byte shared ecdh_secret:\n%s", str);
                    free(str);
                }
                memcpy(eaeskey, aeskey, 16);
                sha_ctx_t *ctx = sha_init();
                sha_update(ctx, eaeskey, 16);
                sha_update(ctx, ecdh_secret, 32);
                sha_final(ctx, eaeskey, NULL);
                sha_destroy(ctx);
                memcpy(aeskey, eaeskey, 16);
                if (logger_debug) {
                    char *str = utils_data_to_string(aeskey, 16, 16);
                    logger_log(raop->logger, LOGGER_DEBUG, "16 byte aeskey after sha-256 hash with ecdh_secret:\n%s", str);
                    free(str);
                }
            }
        }

        // Time port
        plist_t req_is_remote_control_only_node = plist_dict_get_item(req_root_node, "isRemoteControlOnly");
        if (req_is_remote_control_only_node) {
	    uint8_t bool_val = 0;
	    plist_get_bool_val(req_is_remote_control_only_node, &bool_val);  
            if (bool_val) {
                logger_log(raop->logger, LOGGER_ERR, "Client specified AirPlay2 \"Remote Control\" protocol\n"
			   " Only AirPlay v1 protocol (using NTP and timing port) is supported");
            }
        }
        char *timing_protocol = NULL;
        timing_protocol_t time_protocol = TP_NONE;
        plist_t req_timing_protocol_node = plist_dict_get_item(req_root_node, "timingProtocol");
        plist_get_string_val(req_timing_protocol_node, &timing_protocol);
        if (timing_protocol) {
             int string_len = strlen(timing_protocol);
             if (strncmp(timing_protocol, "NTP", string_len) == 0) {
                 time_protocol = NTP;
             } else if (strncmp(timing_protocol, "None", string_len) == 0) {
                 time_protocol = TP_NONE;
             } else {
                 time_protocol = TP_OTHER;
             }
             if (time_protocol != NTP) {
                 logger_log(raop->logger, LOGGER_ERR, "Client specified timingProtocol=%s,"
                            " but timingProtocol= NTP is required here", timing_protocol);
             }
             plist_mem_free (timing_protocol);
             timing_protocol = NULL;
        } else {
            logger_log(raop->logger, LOGGER_DEBUG, "Client did not specify timingProtocol,"
                       " old protocol without offset will be used");
            time_protocol = TP_UNSPECIFIED;
        }
        uint64_t timing_rport = 0;
        plist_t req_timing_port_node = plist_dict_get_item(req_root_node, "timingPort");
        if (req_timing_port_node) {
             plist_get_uint_val(req_timing_port_node, &timing_rport);
        }
        if (timing_rport) {
            logger_log(raop->logger, LOGGER_DEBUG, "timing_rport = %llu", timing_rport);
        } else {
            logger_log(raop->logger, LOGGER_ERR, "Client did not supply timing_rport,"
                       " may be using unsupported AirPlay2 \"Remote Control\" protocol");
        }
        unsigned short timing_lport = raop->timing_lport;

        conn->raop_ntp = NULL;
        conn->raop_rtp = NULL;
        conn->raop_rtp_mirror = NULL;
        char remote[40] = { 0 };
        int len = utils_ipaddress_to_string(conn->remotelen, conn->remote, conn->zone_id, remote, (int) sizeof(remote));
        if (!len || len > (int) sizeof(remote)) {
            char *str = utils_data_to_string(conn->remote, conn->remotelen, 16);
            logger_log(raop->logger, LOGGER_ERR, "failed to extract valid client ip address:\n"
                       "*** UxPlay will be unable to send communications to client.\n"
                       "*** address length %d, zone_id %u address data:\n%sparser returned \"%s\"\n",
                       conn->remotelen, conn->zone_id, str, remote);
            free(str);
        }
        conn->raop_ntp = raop_ntp_init(raop->logger, &raop->callbacks, remote,
                                       conn->remotelen, (unsigned short) timing_rport, &time_protocol);
        raop_ntp_start(conn->raop_ntp, &timing_lport);
        conn->raop_rtp = raop_rtp_init(raop->logger, &raop->callbacks, conn->raop_ntp,
                                       remote, conn->remotelen, aeskey, aesiv);
        conn->raop_rtp_mirror = raop_rtp_mirror_init(raop->logger, &raop->callbacks,
                                                     conn->raop_ntp, remote, conn->remotelen, aeskey);

        /* the event port is not used in mirror mode or audio mode */
        unsigned short event_port = 0;
        plist_t res_event_port_node = plist_new_uint(event_port);
        plist_t res_timing_port_node = plist_new_uint(timing_lport);
        plist_dict_set_item(res_root_node, "timingPort", res_timing_port_node);
        plist_dict_set_item(res_root_node, "eventPort", res_event_port_node);

        logger_log(raop->logger, LOGGER_DEBUG, "eport = %d, tport = %d", event_port, timing_lport);
    } else if (raop->hkp_enabled && !conn->raop_rtp_mirror) {
        /*
         * A Mac AirPlay receiver advertises HomeKit pairing and receives an
         * AP2-style initial SETUP without the legacy FairPlay ekey/eiv
         * properties.  Keep the proven Mac discovery/control path, but make a
         * mirroring transport available before the type-110 stream SETUP.
         *
         * The candidate key source is selectable so packet captures can
         * distinguish FairPlay-session and HomeKit-secret derivations without
         * changing discovery again.
         */
        plist_t req_timing_port_node =
            plist_dict_get_item(req_root_node, "timingPort");
        uint64_t timing_rport = 0;
        if (req_timing_port_node) {
            plist_get_uint_val(req_timing_port_node, &timing_rport);
        }

        if (timing_rport) {
            unsigned char media_key[16] = { 0 };
            unsigned char fairplay_key[16] = { 0 };
            const char *key_mode = getenv("UXPLAY_HKP_MEDIA_KEY_MODE");
            if (!key_mode || !key_mode[0]) {
                key_mode = "fairplay";
            }
            int key_ret = -1;
            int fairplay_ret =
                fairplay_session_key(conn->fairplay, fairplay_key);

            /*
             * Record every input a media-key derivation could plausibly
             * consume, so scripts/ap2_key_search.py can search offline
             * instead of spending a physical mirroring session per guess.
             */
            if (ap2_capture_enabled()) {
                unsigned char keymsg[164] = { 0 };
                ap2_capture_str("device_id", raop->hkp_device_id);
                ap2_capture_str("pk", raop->pk_str);
                if (fairplay_ret == 0) {
                    ap2_capture_hex("fairplay_session_key",
                                    fairplay_key, sizeof(fairplay_key));
                }
                if (fairplay_get_keymsg(conn->fairplay, keymsg) == 0) {
                    ap2_capture_hex("fairplay_keymsg",
                                    keymsg, sizeof(keymsg));
                }
                if (conn->hkp_shared_secret_len) {
                    ap2_capture_hex("hkp_shared_secret",
                                    conn->hkp_shared_secret,
                                    conn->hkp_shared_secret_len);
                }
                for (int channel = 0; channel <= 5; channel++) {
                    struct pair_cipher_context *cipher = pair_cipher_new(
                        PAIR_SERVER_HOMEKIT, channel,
                        conn->hkp_shared_secret,
                        conn->hkp_shared_secret_len, "");
                    if (!cipher) {
                        continue;
                    }
                    unsigned char write_key[32] = { 0 };
                    unsigned char read_key[32] = { 0 };
                    if (pair_cipher_get_keys(
                            write_key, read_key, cipher) == 0) {
                        char name[48];
                        snprintf(name, sizeof(name),
                                 "hkp_ch%d_write", channel);
                        ap2_capture_hex(name, write_key, sizeof(write_key));
                        snprintf(name, sizeof(name),
                                 "hkp_ch%d_read", channel);
                        ap2_capture_hex(name, read_key, sizeof(read_key));
                    }
                    pair_cipher_free(cipher);
                }
            }

            if (!strcmp(key_mode, "fairplay")) {
                if (fairplay_ret == 0) {
                    memcpy(media_key, fairplay_key, sizeof(media_key));
                    key_ret = 0;
                }
            } else if (!strcmp(key_mode, "hkp-secret") &&
                       conn->hkp_shared_secret_len >= sizeof(media_key)) {
                memcpy(media_key, conn->hkp_shared_secret,
                       sizeof(media_key));
                key_ret = 0;
            } else if (!strcmp(key_mode, "sha256-hkp") &&
                       conn->hkp_shared_secret_len > 0) {
                unsigned char digest[64] = { 0 };
                sha_ctx_t *ctx = sha_init();
                sha_update(ctx, conn->hkp_shared_secret,
                           (int) conn->hkp_shared_secret_len);
                sha_final(ctx, digest, NULL);
                sha_destroy(ctx);
                memcpy(media_key, digest, sizeof(media_key));
                memset(digest, 0, sizeof(digest));
                key_ret = 0;
            }

            if (key_ret == 0) {
                char remote[40] = { 0 };
                int len = utils_ipaddress_to_string(
                    conn->remotelen, conn->remote, conn->zone_id, remote,
                    (int) sizeof(remote));
                if (len > 0 && len <= (int) sizeof(remote)) {
                    timing_protocol_t time_protocol = NTP;
                    plist_t req_timing_protocol_node =
                        plist_dict_get_item(req_root_node,
                                            "timingProtocol");
                    char *timing_protocol = NULL;
                    if (req_timing_protocol_node) {
                        plist_get_string_val(req_timing_protocol_node,
                                             &timing_protocol);
                    }
                    if (timing_protocol &&
                        strcmp(timing_protocol, "NTP")) {
                        time_protocol = TP_OTHER;
                    }
                    if (timing_protocol) {
                        plist_mem_free(timing_protocol);
                    }

                    unsigned short timing_lport = raop->timing_lport;
                    conn->raop_ntp = raop_ntp_init(
                        raop->logger, &raop->callbacks, remote,
                        conn->remotelen, (unsigned short) timing_rport,
                        &time_protocol);
                    if (conn->raop_ntp) {
                        raop_ntp_start(conn->raop_ntp, &timing_lport);
                        conn->raop_rtp_mirror = raop_rtp_mirror_init(
                            raop->logger, &raop->callbacks, conn->raop_ntp,
                            remote, conn->remotelen, media_key);
                    }

                    if (conn->raop_rtp_mirror) {
                        hkp_add_mirror_candidates(
                            conn, conn->raop_rtp_mirror, fairplay_key,
                            fairplay_ret == 0);
                        unsigned short event_port =
                            hkp_start_event_channel(conn);
                        plist_dict_set_item(
                            res_root_node, "timingPort",
                            plist_new_uint(timing_lport));
                        plist_dict_set_item(
                            res_root_node, "eventPort",
                            plist_new_uint(event_port));
                        logger_log(
                            raop->logger, LOGGER_INFO,
                            "HomeKit/AP2 mirroring transport initialized "
                            "with media key mode %s, event port %u",
                            key_mode, event_port);
                    } else {
                        logger_log(
                            raop->logger, LOGGER_ERR,
                            "Unable to initialize HomeKit/AP2 mirroring "
                            "transport");
                    }
                }
            } else {
                logger_log(
                    raop->logger, LOGGER_ERR,
                    "Unable to derive HomeKit/AP2 media key in mode %s",
                    key_mode);
            }
            memset(media_key, 0, sizeof(media_key));
            memset(fairplay_key, 0, sizeof(fairplay_key));
        }
    }

    // Process stream setup requests
    plist_t req_streams_node = plist_dict_get_item(req_root_node, "streams");
    if (PLIST_IS_ARRAY(req_streams_node)) {
        plist_t res_streams_node = plist_new_array();

        int count = plist_array_get_size(req_streams_node);
        for (int i = 0; i < count; i++) {
            plist_t req_stream_node = plist_array_get_item(req_streams_node, i);
            plist_t req_stream_type_node = plist_dict_get_item(req_stream_node, "type");
            uint64_t type;
            plist_get_uint_val(req_stream_type_node, &type);
            logger_log(raop->logger, LOGGER_DEBUG, "type = %llu", type);

            switch (type) {
            case 110: {
                // Mirroring
                raop_destroy_airplay_video(raop, -1);  //cleanup any hls data still present when mirror video starts
                unsigned short dport =
                    raop->hkp_enabled ? 0 : raop->mirror_data_lport;
                plist_t stream_id_node = plist_dict_get_item(req_stream_node, "streamConnectionID");
                uint64_t stream_connection_id = 0;
                plist_get_uint_val(stream_id_node, &stream_connection_id);
                logger_log(raop->logger, LOGGER_DEBUG, "streamConnectionID (needed for AES-CTR video decryption"
                           " key and iv): %llu", stream_connection_id);

                if (conn->raop_rtp_mirror) {
                    raop_rtp_mirror_init_aes(conn->raop_rtp_mirror, &stream_connection_id);
                    raop_rtp_mirror_start(conn->raop_rtp_mirror, &dport, raop->clientFPSdata);
                    logger_log(raop->logger, LOGGER_DEBUG, "Mirroring initialized successfully");
                } else {
                    logger_log(raop->logger, LOGGER_ERR, "Mirroring not initialized at SETUP, playing will fail!");
                    http_response_set_disconnect(response, 1);
                }

                plist_t res_stream_node = plist_new_dict();
                plist_t res_stream_data_port_node = plist_new_uint(dport);
                plist_t res_stream_type_node = plist_new_uint(110);
                plist_dict_set_item(res_stream_node, "dataPort", res_stream_data_port_node);
                plist_dict_set_item(res_stream_node, "type", res_stream_type_node);
                if (raop->hkp_enabled) {
                    if (conn->hkp_video_control_sock < 0) {
                        unsigned short control_port = 0;
                        int use_ipv6 = conn->remotelen == 16;
                        conn->hkp_video_control_sock =
                            netutils_init_socket(
                                &control_port, use_ipv6, 1);
                        if (conn->hkp_video_control_sock >= 0) {
                            conn->hkp_video_control_port =
                                control_port;
                        }
                    }
                    plist_dict_set_item(
                        res_stream_node, "controlPort",
                        plist_new_uint(
                            conn->hkp_video_control_port));
                    logger_log(
                        raop->logger, LOGGER_INFO,
                        "HomeKit/AP2 video control port %u",
                        conn->hkp_video_control_port);
                }
                plist_array_append_item(res_streams_node, res_stream_node);

                break;
                }
            case 96: {
                // Audio
                unsigned short cport = raop->control_lport, dport = raop->data_lport; 
                unsigned short remote_cport = 0;
                unsigned char ct = 0;
                unsigned int sr = AUDIO_SAMPLE_RATE; /* all AirPlay audio formats supported so far have sample rate 44.1kHz */

                uint64_t uint_val = 0;
                plist_t req_stream_control_port_node = plist_dict_get_item(req_stream_node, "controlPort");
                plist_get_uint_val(req_stream_control_port_node, &uint_val);
                remote_cport = (unsigned short) uint_val;   /* must != 0 to activate audio resend requests */

                plist_t req_stream_ct_node = plist_dict_get_item(req_stream_node, "ct");
                plist_get_uint_val(req_stream_ct_node, &uint_val);
                ct = (unsigned char) uint_val;

                if (raop->callbacks.audio_get_format) {
                    /* get additional audio format parameters  */
                    uint64_t audioFormat = 0;
                    unsigned short spf = 0;
                    bool isMedia = false;
                    bool usingScreen = false;
                    uint8_t bool_val = 0;

                    plist_t req_stream_spf_node = plist_dict_get_item(req_stream_node, "spf");
                    plist_get_uint_val(req_stream_spf_node, &uint_val);
                    spf = (unsigned short) uint_val;

                    plist_t req_stream_audio_format_node = plist_dict_get_item(req_stream_node, "audioFormat");
                    plist_get_uint_val(req_stream_audio_format_node, &audioFormat);

                    plist_t req_stream_is_media_node = plist_dict_get_item(req_stream_node, "isMedia");
                    if (req_stream_is_media_node) {
                        plist_get_bool_val(req_stream_is_media_node, &bool_val);
                        isMedia = (bool) bool_val;
                    } else {
                        isMedia = false;
                    }

                    plist_t req_stream_using_screen_node = plist_dict_get_item(req_stream_node, "usingScreen");
                    if (req_stream_using_screen_node) {
                        plist_get_bool_val(req_stream_using_screen_node, &bool_val);
                        usingScreen = (bool) bool_val;
                    } else {
                        usingScreen = false;
                    }

                    raop->callbacks.audio_get_format(raop->callbacks.cls, &ct, &spf, &usingScreen, &isMedia, &audioFormat);
                }

                if (conn->raop_rtp) {
                    raop_rtp_start_audio(conn->raop_rtp, &remote_cport, &cport, &dport, &ct, &sr);
                    logger_log(raop->logger, LOGGER_DEBUG, "RAOP initialized success");
                } else {
                    logger_log(raop->logger, LOGGER_ERR, "RAOP not initialized at SETUP, playing will fail!");
                    http_response_set_disconnect(response, 1);
                }

                plist_t res_stream_node = plist_new_dict();
                plist_t res_stream_data_port_node = plist_new_uint(dport);
                plist_t res_stream_control_port_node = plist_new_uint(cport);
                plist_t res_stream_type_node = plist_new_uint(96);
                plist_dict_set_item(res_stream_node, "dataPort", res_stream_data_port_node);
                plist_dict_set_item(res_stream_node, "controlPort", res_stream_control_port_node);
                plist_dict_set_item(res_stream_node, "type", res_stream_type_node);
                plist_array_append_item(res_streams_node, res_stream_node);

                break;
                }

            default:
                logger_log(raop->logger, LOGGER_ERR, "SETUP tries to setup stream of unknown type %llu", type);
                http_response_set_disconnect(response, 1);
                break;
            }
        }

        plist_dict_set_item(res_root_node, "streams", res_streams_node);
    }

    plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);
    plist_free(res_root_node);
    plist_free(req_root_node);
    http_response_add_header(response, "Content-Type", "application/x-apple-binary-plist");
}

static void
raop_handler_get_parameter(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;  
    const char *content_type = NULL;
    const char *data = NULL;
    int datalen = 0;

    content_type = http_request_get_header(request, "Content-Type");
    if (!content_type) {
        http_response_init(response, "RTSP/1.0", 451, "Parameter not understood");
        return;
    }

    data = http_request_get_data(request, &datalen);
    if (!strcmp(content_type, "text/parameters")) {
        const char *current = data;

        while (current && (datalen - (current - data) > 0)) {
            const char *next;

            /* This is a bit ugly, but seems to be how airport works too */
            if ((datalen - (current - data) >= 8) && !strncmp(current, "volume\r\n", 8)) {
                char volume[25] = "volume: 0.0\r\n";
                if (raop->callbacks.audio_set_client_volume) {
                    snprintf(volume, 25, "volume: %9.6f\r\n", raop->callbacks.audio_set_client_volume(raop->callbacks.cls));
                }
                http_response_add_header(response, "Content-Type", "text/parameters");
                *response_data = strdup(volume);
                if (*response_data) {
                    *response_datalen = strlen(*response_data);
                }
                return;
            }

            for (next = current ; (datalen - (next - data) > 0) ; ++next) {
                if (*next == '\r') {
                    break;
                }
            }

            if ((datalen - (next - data) >= 2) && !strncmp(next, "\r\n", 2)) {
                if ((next - current) > 0) {
                    logger_log(raop->logger, LOGGER_WARNING,
                               "Found an unknown parameter: %.*s", (next - current), current);
                }
                current = next + 2;
            } else {
                current = NULL;
            }
        }
    }
}

static void
raop_handler_set_parameter(raop_conn_t *conn,
                           http_request_t *request, http_response_t *response,
                           char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *content_type = NULL;
    const char *data = NULL;
    int datalen = 0;

    content_type = http_request_get_header(request, "Content-Type");
    if (!content_type) {
        http_response_init(response, "RTSP/1.0", 451, "Parameter not understood");
        return;
    }
    data = http_request_get_data(request, &datalen);
    if (!strcmp(content_type, "text/parameters")) {
        char *datastr = NULL;
        datastr = calloc(1, datalen + 1);
        if (data && datastr && conn->raop_rtp) {
            memcpy(datastr, data, datalen);
            if ((datalen >= 8) && !strncmp(datastr, "volume: ", 8)) {
                float vol = 0.0f;
                sscanf(datastr+8, "%f", &vol);
                raop_rtp_set_volume(conn->raop_rtp, vol);
            } else if ((datalen >= 10) && !strncmp(datastr, "progress: ", 10)) {
                uint32_t start = 0, curr = 0, end = 0;
                sscanf(datastr+10, "%"PRIu32"/%"PRIu32"/%"PRIu32, &start, &curr, &end);
                raop_rtp_set_progress(conn->raop_rtp, start, curr, end);
            }
        } else if (!conn->raop_rtp) {
            logger_log(raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER");
        }
        free(datastr);
    } else if (!strcmp(content_type, "image/jpeg") || !strcmp(content_type, "image/png")) {
        logger_log(raop->logger, LOGGER_DEBUG, "Got image data of %d bytes", datalen);
        if (conn->raop_rtp) {
            raop_rtp_set_coverart(conn->raop_rtp, data, datalen);
        } else {
            logger_log(raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER coverart");
        }
    } else if (!strcmp(content_type, "application/x-dmap-tagged")) {
        logger_log(raop->logger, LOGGER_DEBUG, "Got metadata of %d bytes", datalen);
        if (conn->raop_rtp) {
            raop_rtp_set_metadata(conn->raop_rtp, data, datalen);
        } else {
            logger_log(raop->logger, LOGGER_WARNING, "RAOP not initialized at SET_PARAMETER metadata");
        }
    }
}

static void
raop_handler_audiomode(raop_conn_t *conn,
                      http_request_t *request, http_response_t *response,
                      char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *data = NULL;
    char *audiomode = NULL;
    int data_len = 0;
    data = http_request_get_data(request, &data_len);
    plist_t req_root_node = NULL;
    plist_from_bin(data, data_len, &req_root_node);
    plist_t req_audiomode_node = plist_dict_get_item(req_root_node, "audioMode");
    plist_get_string_val(req_audiomode_node, &audiomode);
    /* not sure what should be done with this request: usually audioMode requested is "default" */
    int log_level = (strstr(audiomode, "default") ? LOGGER_DEBUG : LOGGER_INFO);
    logger_log(raop->logger, log_level, "Unhandled RTSP request \"audioMode: %s\"", audiomode);
    plist_mem_free(audiomode);
    plist_free(req_root_node);
}

static void
raop_handler_feedback(raop_conn_t *conn,
                      http_request_t *request, http_response_t *response,
                      char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    logger_log(raop->logger, LOGGER_DEBUG, "raop_handler_feedback");
    /* register receipt of client's "heartbeat" signal  */
    raop->callbacks.conn_feedback(raop->callbacks.cls);
}

static void
raop_handler_record(raop_conn_t *conn,
                    http_request_t *request, http_response_t *response,
                    char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    char audio_latency[12] = { '\0' };
    unsigned int ad = (unsigned int) (((uint64_t) raop->audio_delay_micros) * AUDIO_SAMPLE_RATE / SECOND_IN_USECS);
    snprintf(audio_latency, sizeof(audio_latency), "%u", ad);
    logger_log(raop->logger, LOGGER_DEBUG, "raop_handler_record");
    http_response_add_header(
        response, "Audio-Latency",
        raop->hkp_enabled ? "0" : audio_latency);
    if (!raop->hkp_enabled) {
        http_response_add_header(
            response, "Audio-Jack-Status",
            "connected; type=analog");
    }
}

static void
raop_handler_flush(raop_conn_t *conn,
                      http_request_t *request, http_response_t *response,
                      char **response_data, int *response_datalen)
{
    raop_t *raop = conn->raop;
    const char *rtpinfo = NULL;
    int next_seq = -1;

    rtpinfo = http_request_get_header(request, "RTP-Info");
    if (rtpinfo) {
        logger_log(raop->logger, LOGGER_DEBUG, "Flush with RTP-Info: %s", rtpinfo);
        if (!strncmp(rtpinfo, "seq=", 4)) {
            next_seq = strtol(rtpinfo + 4, NULL, 10);
        }
    }
    if (conn->raop_rtp) {
        raop_rtp_flush(conn->raop_rtp, next_seq);
    } else {
        logger_log(raop->logger, LOGGER_WARNING, "RAOP not initialized at FLUSH");
    }
}

static void
raop_handler_teardown(raop_conn_t *conn,
                      http_request_t *request, http_response_t *response,
                      char **response_data, int *response_datalen)
{
    /* get the teardown request type(s):  (type 96, 110, or none) */
    raop_t *raop = conn->raop;
    const char *data = NULL;
    int data_len = 0;
    bool teardown_96 = false, teardown_110 = false;
    data = http_request_get_data(request, &data_len);
    plist_t req_root_node = NULL;
    plist_from_bin(data, data_len, &req_root_node);
    plist_t req_streams_node = plist_dict_get_item(req_root_node, "streams");
    /* Process stream teardown requests */
    if (PLIST_IS_ARRAY(req_streams_node)) {
        uint64_t val = 0;
        int count = plist_array_get_size(req_streams_node);
        for (int i = 0; i < count; i++) {
            plist_t req_stream_node = plist_array_get_item(req_streams_node,i);
            plist_t req_stream_type_node = plist_dict_get_item(req_stream_node, "type");
            plist_get_uint_val(req_stream_type_node, &val);
            if (val == 96) {
                teardown_96 = true;
            } else if (val == 110) { 
                teardown_110 = true;
            }
        }
    }
    plist_free(req_root_node);
    logger_log(raop->logger, LOGGER_DEBUG, "TEARDOWN request,  96=%d, 110=%d", teardown_96, teardown_110);
  
    http_response_add_header(response, "Connection", "close");
  
    if (teardown_96) {
        if (conn->raop_rtp) {
            /* Stop our audio RTP session */
            raop_rtp_stop(conn->raop_rtp);
            /* stop any  coverart rendering */
            if (raop->callbacks.audio_stop_coverart_rendering) {
                raop->callbacks.audio_stop_coverart_rendering(raop->callbacks.cls);
            }
        }
    } else if (teardown_110) {
        if (raop->hls_pending) {
            raop->callbacks.video_reset(raop->callbacks.cls, RESET_TYPE_RTP_TO_HLS_TEARDOWN);
        } else {
            raop->callbacks.video_reset(raop->callbacks.cls, RESET_TYPE_RTP_SHUTDOWN);
        }
        if (conn->raop_rtp_mirror) {
        /* Stop our video RTP session */
            raop_rtp_mirror_stop(conn->raop_rtp_mirror);
        }
    } else {
        /* Destroy our sessions */
        if (conn->raop_rtp) {
            raop_rtp_destroy(conn->raop_rtp);
            conn->raop_rtp = NULL;
        }
        if (conn->raop_rtp_mirror) {
            raop_rtp_mirror_destroy(conn->raop_rtp_mirror);
            conn->raop_rtp_mirror = NULL;
        }
        /* shut down any HLS connections */
        int hls_count = httpd_count_connection_type(raop->httpd, CONNECTION_TYPE_HLS);
        if (hls_count) {
            raop->callbacks.video_reset(raop->callbacks.cls, RESET_TYPE_HLS_SHUTDOWN);
        }
    }
}
