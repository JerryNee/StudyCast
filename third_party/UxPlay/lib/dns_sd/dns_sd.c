/**
 *  Copyright (C) 2011-2012  Juho Vähä-Herttua
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
 *=================================================================
 * modified by fduncanh 2022, 2026
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "../compat.h"
#include <dns_sd.h>
#include "../dnssd.h"
#include "../dnssdint.h"
#include "../utils.h"

#define MAX_DEVICEID 18
#define MAX_SERVNAME 256
#define DISCOVERY_PROFILE_ENV "UXPLAY_DISCOVERY_PROFILE"
/*
 * Peer-to-peer registration itself is a normal option, -p2p.
 *
 * This profile additionally impersonates a Mac receiver. It also reaches
 * AWDL, but a Mac identity makes senders switch to the AP2 media setup, which
 * omits the legacy FairPlay ekey -- video then arrives and cannot be
 * decrypted. It exists only to capture material for that investigation, so it
 * stays an environment variable rather than a documented option.
 */
#define MAC_P2P_DISCOVERY_PROFILE "mac-p2p"

/*
 * Synthetic stand-ins for a Mac receiver's Bonjour identity. These are
 * deliberately not copied from a real machine: publishing another device's
 * AirPlay identifiers would be both a privacy leak and a source of collisions
 * on a network where that machine is present.
 */
#define MAC_WIRE_DEVICEID "02:00:5E:10:00:01"
#define MAC_WIRE_FEATURES "0x5A7FFEE6,0x381607DE"
#define MAC_WIRE_MODEL "Mac15,6"
#define MAC_WIRE_SRCVERS "980.63.2"
#define MAC_WIRE_FLAGS "0x4"
#define MAC_WIRE_GID "00000000-0000-4000-8000-000000000001"
#define MAC_WIRE_PI "00000000-0000-4000-8000-000000000001"
#define MAC_WIRE_PSI "00000000-0000-4000-8000-000000000002"

static int
mac_wire_discovery_profile_enabled(void)
{
    const char *profile = getenv(DISCOVERY_PROFILE_ENV);
    return profile && !strcmp(profile, MAC_P2P_DISCOVERY_PROFILE);
}

/*
 * Senders consult this bitmap when deciding both whether to use Apple
 * peer-to-peer and whether to negotiate the AP2 media setup, so allow the
 * exact value to be set from the environment while investigating which bits
 * drive which decision. Format matches the TXT record.
 */
static const char *
mac_wire_features(void)
{
    const char *override = getenv("UXPLAY_MAC_FEATURES");
    if (override && override[0]) {
        return override;
    }
    return MAC_WIRE_FEATURES;
}

/*
 * Opt the receiver into Apple's peer-to-peer Bonjour discovery paths. Its TXT
 * identity and feature bitmap remain UxPlay's own, so the client only
 * negotiates transports and pairing modes that UxPlay actually implements.
 */
static void
discovery_registration_options(dnssd_t *dnssd_public, DNSServiceFlags *flags,
                               uint32_t *interface_index)
{
    *flags = 0;
    *interface_index = 0;

#ifdef __APPLE__
    /* The Mac research profile implies peer-to-peer registration. */
    if (dnssd_public->peer_to_peer || mac_wire_discovery_profile_enabled()) {
        /*
         * Register on the normal infrastructure interfaces and opt into both
         * Apple peer-to-peer discovery families.  Pinning the service to
         * awdl0 hid it from clients currently using newer P2P interfaces such
         * as anri0/en17.
         */
        *interface_index = kDNSServiceInterfaceIndexAny;
        *flags = kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL;
    }
#endif
}

#if defined(HAVE_LIBDL) && !defined(__APPLE__)
# define USE_LIBDL 1
#else
# define USE_LIBDL 0
#endif

#if defined(_WIN32) || USE_LIBDL
# ifdef _WIN32
#  include <stdint.h>
#  if !defined(EFI32) && !defined(EFI64)
#   define DNSSD_STDCALL __stdcall
#  else
#   define DNSSD_STDCALL
#  endif
# else
#  include <dlfcn.h>
#  define DNSSD_STDCALL
# endif

typedef struct _DNSServiceRef_t *DNSServiceRef;
#ifndef _WIN32
typedef union _TXTRecordRef_t { char PrivateData[16]; char *ForceNaturalAlignment; } TXTRecordRef;
#endif
typedef uint32_t DNSServiceFlags;
typedef int32_t  DNSServiceErrorType;

typedef void (DNSSD_STDCALL *DNSServiceRegisterReply)
    (
    DNSServiceRef                       sdRef,
    DNSServiceFlags                     flags,
    DNSServiceErrorType                 errorCode,
    const char                          *name,
    const char                          *regtype,
    const char                          *domain,
    void                                *context
    );

#else
//# include <dns_sd.h>
# define DNSSD_STDCALL
#endif

typedef DNSServiceErrorType (DNSSD_STDCALL *DNSServiceRegister_t)
        (
                DNSServiceRef                       *sdRef,
                DNSServiceFlags                     flags,
                uint32_t                            interfaceIndex,
                const char                          *name,
                const char                          *regtype,
                const char                          *domain,
                const char                          *host,
                uint16_t                            port,
                uint16_t                            txtLen,
                const void                          *txtRecord,
                DNSServiceRegisterReply             callBack,
                void                                *context
        );
typedef void (DNSSD_STDCALL *DNSServiceRefDeallocate_t)(DNSServiceRef sdRef);
typedef void (DNSSD_STDCALL *TXTRecordCreate_t)
        (
                TXTRecordRef     *txtRecord,
                uint16_t         bufferLen,
                void             *buffer
        );
typedef void (DNSSD_STDCALL *TXTRecordDeallocate_t)(TXTRecordRef *txtRecord);
typedef DNSServiceErrorType (DNSSD_STDCALL *TXTRecordSetValue_t)
        (
                TXTRecordRef     *txtRecord,
                const char       *key,
                uint8_t          valueSize,
                const void       *value
        );
typedef uint16_t (DNSSD_STDCALL *TXTRecordGetLength_t)(const TXTRecordRef *txtRecord);
typedef const void * (DNSSD_STDCALL *TXTRecordGetBytesPtr_t)(const TXTRecordRef *txtRecord);


typedef struct dnssd_private_s {
#ifdef WIN32
    HMODULE module;
#elif USE_LIBDL
    void *module;
#endif

    DNSServiceRegister_t       DNSServiceRegister;
    DNSServiceRefDeallocate_t  DNSServiceRefDeallocate;
    TXTRecordCreate_t          TXTRecordCreate;
    TXTRecordSetValue_t        TXTRecordSetValue;
    TXTRecordGetLength_t       TXTRecordGetLength;
    TXTRecordGetBytesPtr_t     TXTRecordGetBytesPtr;
    TXTRecordDeallocate_t      TXTRecordDeallocate;

    TXTRecordRef raop_record;
    TXTRecordRef airplay_record;

    DNSServiceRef raop_service;
    DNSServiceRef airplay_service;

} dnssd_private_t;


void *
dnssd_private_init(dnssd_t *dnssd_public, int *error)
{
    if (error) *error = DNSSD_ERROR_NOERROR;

    dnssd_private_t *dnssd = (dnssd_private_t *) calloc(1, sizeof(dnssd_private_t));
    if (!dnssd) {
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }

#ifdef WIN32
    dnssd->module = LoadLibraryA("dnssd.dll");
    if (!dnssd->module) {
        if (error) *error = DNSSD_ERROR_LIBNOTFOUND;
        free(dnssd);
        return NULL;
    }
    dnssd->DNSServiceRegister = (DNSServiceRegister_t)GetProcAddress(dnssd->module, "DNSServiceRegister");
    dnssd->DNSServiceRefDeallocate = (DNSServiceRefDeallocate_t)GetProcAddress(dnssd->module, "DNSServiceRefDeallocate");
    dnssd->TXTRecordCreate = (TXTRecordCreate_t)GetProcAddress(dnssd->module, "TXTRecordCreate");
    dnssd->TXTRecordSetValue = (TXTRecordSetValue_t)GetProcAddress(dnssd->module, "TXTRecordSetValue");
    dnssd->TXTRecordGetLength = (TXTRecordGetLength_t)GetProcAddress(dnssd->module, "TXTRecordGetLength");
    dnssd->TXTRecordGetBytesPtr = (TXTRecordGetBytesPtr_t)GetProcAddress(dnssd->module, "TXTRecordGetBytesPtr");
    dnssd->TXTRecordDeallocate = (TXTRecordDeallocate_t)GetProcAddress(dnssd->module, "TXTRecordDeallocate");

    if (!dnssd->DNSServiceRegister || !dnssd->DNSServiceRefDeallocate || !dnssd->TXTRecordCreate ||
        !dnssd->TXTRecordSetValue || !dnssd->TXTRecordGetLength || !dnssd->TXTRecordGetBytesPtr ||
        !dnssd->TXTRecordDeallocate) {
        if (error) *error = DNSSD_ERROR_PROCNOTFOUND;
        FreeLibrary(dnssd->module);
        free(dnssd);
        return NULL;
    }
#elif USE_LIBDL
    dnssd->module = dlopen("libdns_sd.so", RTLD_LAZY);
    if (!dnssd->module) {
      if (error) *error = DNSSD_ERROR_LIBNOTFOUND;
      free(dnssd);
      return NULL;
    }
    dnssd->DNSServiceRegister = (DNSServiceRegister_t)dlsym(dnssd->module, "DNSServiceRegister");
    dnssd->DNSServiceRefDeallocate = (DNSServiceRefDeallocate_t)dlsym(dnssd->module, "DNSServiceRefDeallocate");
    dnssd->TXTRecordCreate = (TXTRecordCreate_t)dlsym(dnssd->module, "TXTRecordCreate");
    dnssd->TXTRecordSetValue = (TXTRecordSetValue_t)dlsym(dnssd->module, "TXTRecordSetValue");
    dnssd->TXTRecordGetLength = (TXTRecordGetLength_t)dlsym(dnssd->module, "TXTRecordGetLength");
    dnssd->TXTRecordGetBytesPtr = (TXTRecordGetBytesPtr_t)dlsym(dnssd->module, "TXTRecordGetBytesPtr");
    dnssd->TXTRecordDeallocate = (TXTRecordDeallocate_t)dlsym(dnssd->module, "TXTRecordDeallocate");

    if (!dnssd->DNSServiceRegister || !dnssd->DNSServiceRefDeallocate || !dnssd->TXTRecordCreate ||
        !dnssd->TXTRecordSetValue || !dnssd->TXTRecordGetLength || !dnssd->TXTRecordGetBytesPtr ||
        !dnssd->TXTRecordDeallocate) {
        if (error) *error = DNSSD_ERROR_PROCNOTFOUND;
        dlclose(dnssd->module);
        free(dnssd);
        return NULL;
    }
#else
    dnssd->DNSServiceRegister = &DNSServiceRegister;
    dnssd->DNSServiceRefDeallocate = &DNSServiceRefDeallocate;
    dnssd->TXTRecordCreate = &TXTRecordCreate;
    dnssd->TXTRecordSetValue = &TXTRecordSetValue;
    dnssd->TXTRecordGetLength = &TXTRecordGetLength;
    dnssd->TXTRecordGetBytesPtr = &TXTRecordGetBytesPtr;
    dnssd->TXTRecordDeallocate = &TXTRecordDeallocate;
#endif

    return (void *) dnssd;
}

void
dnssd_private_destroy(void *private)
{
    if (private) {
        dnssd_private_t *dnssd = (dnssd_private_t *) private;
#ifdef WIN32
        FreeLibrary(dnssd->module);
#elif USE_LIBDL
        dlclose(dnssd->module);
#endif
        free(dnssd);
    }
}

int
dnssd_register_raop(dnssd_t *dnssd_public, unsigned short port)
{
    char servname[MAX_SERVNAME];
    char features[22] = {0};
    DNSServiceFlags registration_flags = 0;
    uint32_t registration_interface = 0;
    discovery_registration_options(dnssd_public, &registration_flags,
                                   &registration_interface);

    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    
    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd_public->features1, dnssd_public->features2);

    dnssd->TXTRecordCreate(&dnssd->raop_record, 0, NULL);
    if (mac_wire_discovery_profile_enabled()) {
        /*
         * Match the system Mac receiver's wire-visible RAOP shape while
         * retaining UxPlay's real feature bitmap and matching public key.
         */
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "cn", strlen(RAOP_CN), RAOP_CN);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "da", strlen(RAOP_DA), RAOP_DA);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "et", strlen(RAOP_ET), RAOP_ET);
        const char *wire_features = mac_wire_features();
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "ft",
                                 strlen(wire_features), wire_features);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "sf",
                                 strlen(MAC_WIRE_FLAGS), MAC_WIRE_FLAGS);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "md", strlen(RAOP_MD), RAOP_MD);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "am", strlen(MAC_WIRE_MODEL), MAC_WIRE_MODEL);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "pk", strlen(dnssd_public->pk), dnssd_public->pk);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "tp", strlen(RAOP_TP), RAOP_TP);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vn", strlen(RAOP_VN), RAOP_VN);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vs", strlen(MAC_WIRE_SRCVERS), MAC_WIRE_SRCVERS);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vv", strlen("0"), "0");
    } else {
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "ch", strlen(RAOP_CH), RAOP_CH);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "cn", strlen(RAOP_CN), RAOP_CN);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "da", strlen(RAOP_DA), RAOP_DA);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "et", strlen(RAOP_ET), RAOP_ET);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vv", strlen(RAOP_VV), RAOP_VV);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "ft", strlen(features), features);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "am", strlen(GLOBAL_MODEL), GLOBAL_MODEL);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "md", strlen(RAOP_MD), RAOP_MD);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "rhd", strlen(RAOP_RHD), RAOP_RHD);
        switch (dnssd_public->pin_pw) {
        case 1:
            /* sf bit 3 0x08 means "pin required". */
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "pw", strlen("true"), "true");
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "sf", strlen("0x8c"), "0x8c");
            break;
        case 2:
        case 3:
            /* sf bit 7 0x80 means "password required". */
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "pw", strlen("true"), "true");
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "sf", strlen("0x84"), "0x84");
            break;
        default:
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "pw", strlen("false"), "false");
            dnssd->TXTRecordSetValue(&dnssd->raop_record, "sf", strlen(RAOP_SF), RAOP_SF);
            break;
        }
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "sr", strlen(RAOP_SR), RAOP_SR);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "ss", strlen(RAOP_SS), RAOP_SS);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "sv", strlen(RAOP_SV), RAOP_SV);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "tp", strlen(RAOP_TP), RAOP_TP);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "txtvers", strlen(RAOP_TXTVERS), RAOP_TXTVERS);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vs", strlen(RAOP_VS), RAOP_VS);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "vn", strlen(RAOP_VN), RAOP_VN);
        dnssd->TXTRecordSetValue(&dnssd->raop_record, "pk", strlen(dnssd_public->pk), dnssd_public->pk);
    }

    /* Convert hardware address to string. */
    if (utils_hwaddr_raop(servname, sizeof(servname), dnssd_public->hw_addr,
                          dnssd_public->hw_addr_len) < 0) {
        return -1;
    }

    /* Check that we have bytes for 'hw@name' format */
    if (sizeof(servname) < strlen(servname) + 1 + dnssd_public->name_len + 1) {
        /* FIXME: handle better */
        return -2;
    }

    strncat(servname, "@", sizeof(servname)-strlen(servname)-1);
    strncat(servname, dnssd_public->name, sizeof(servname)-strlen(servname)-1);

    /* Register the service */
    DNSServiceErrorType retval = dnssd->DNSServiceRegister(&dnssd->raop_service,
                                                          registration_flags,
                                                          registration_interface,
                                                          servname, "_raop._tcp",
                                                          NULL, NULL,
                                                          htons(port),
                                                          dnssd->TXTRecordGetLength(&dnssd->raop_record),
                                                          dnssd->TXTRecordGetBytesPtr(&dnssd->raop_record),
                                                          NULL, NULL);

    return (int) retval;   /* error codes are listed in Apple's dns_sd.h */
}

int
dnssd_register_airplay(dnssd_t *dnssd_public, unsigned short port)
{
    char device_id[3 * MAX_HWADDR_LEN];
    char features[22] = {0};
    DNSServiceFlags registration_flags = 0;
    uint32_t registration_interface = 0;
    discovery_registration_options(dnssd_public, &registration_flags,
                                   &registration_interface);

    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    
    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd_public->features1, dnssd_public->features2);

    /* Convert hardware address to string. */
    if (utils_hwaddr_airplay(device_id, sizeof(device_id), dnssd_public->hw_addr,
                             dnssd_public->hw_addr_len) < 0) {
        return -1;
    }

    // flags is a string representing a 20-bit flag (up to 3 hex digits)
    dnssd->TXTRecordCreate(&dnssd->airplay_record, 0, NULL);
    /*
     * Keep the receiver identity distinct from the built-in Mac receiver.
     * Reusing its Device ID causes visionOS to merge both services and select
     * ControlCenter's dynamic endpoint instead of UxPlay.
     */
    const char *advertised_device_id = device_id;
    dnssd->TXTRecordSetValue(&dnssd->airplay_record, "deviceid",
                             strlen(advertised_device_id), advertised_device_id);
    const char *advertised_features = mac_wire_discovery_profile_enabled()
        ? mac_wire_features()
        : features;
    dnssd->TXTRecordSetValue(&dnssd->airplay_record, "features",
                             strlen(advertised_features), advertised_features);
    if (mac_wire_discovery_profile_enabled()) {
        /*
         * The complete Mac capability record is needed for visionOS to select
         * the AWDL data path. StudyCast handles the advertised HomeKit/System
         * pairing through the bundled pair_ap implementation.
         */
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "acl", strlen("0"), "0");
        /*
         * No "fex" record. Its value is an opaque token; the only one we had
         * was copied verbatim from a specific Mac, and republishing another
         * device's token is not something to ship. Omit the key rather than
         * invent a value whose meaning is unknown.
         */
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "flags",
                                 strlen(MAC_WIRE_FLAGS), MAC_WIRE_FLAGS);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "gid", strlen(MAC_WIRE_GID), MAC_WIRE_GID);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "igl", strlen("0"), "0");
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "gcgl", strlen("0"), "0");
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "model", strlen(MAC_WIRE_MODEL), MAC_WIRE_MODEL);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "at", strlen("4"), "4");
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "protovers", strlen("1.1"), "1.1");
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pi", strlen(MAC_WIRE_PI), MAC_WIRE_PI);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "psi", strlen(MAC_WIRE_PSI), MAC_WIRE_PSI);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pk", strlen(dnssd_public->pk), dnssd_public->pk);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "srcvers", strlen(MAC_WIRE_SRCVERS), MAC_WIRE_SRCVERS);
    } else {
        switch (dnssd_public->pin_pw) {
        case 1:   // display onscreen pin
        case 2:   // require password
        case 3:
            dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pw", strlen("true"), "true");
            dnssd->TXTRecordSetValue(&dnssd->airplay_record, "flags", 3, "0x4");
            break;
        default:
            dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pw", strlen("false"), "false");
            dnssd->TXTRecordSetValue(&dnssd->airplay_record, "flags", 3, "0x4");
            break;
        }
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "model", strlen(GLOBAL_MODEL), GLOBAL_MODEL);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pk", strlen(dnssd_public->pk), dnssd_public->pk);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "pi", strlen(AIRPLAY_PI), AIRPLAY_PI);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "srcvers", strlen(AIRPLAY_SRCVERS), AIRPLAY_SRCVERS);
        dnssd->TXTRecordSetValue(&dnssd->airplay_record, "vv", strlen(AIRPLAY_VV), AIRPLAY_VV);
    }

    /* Register the service */
    DNSServiceErrorType retval = dnssd->DNSServiceRegister(&dnssd->airplay_service,
                                                           registration_flags,
                                                           registration_interface,
                                                           dnssd_public->name, "_airplay._tcp",
                                                           NULL, NULL,
                                                           htons(port),
                                                           dnssd->TXTRecordGetLength(&dnssd->airplay_record),
                                                           dnssd->TXTRecordGetBytesPtr(&dnssd->airplay_record),
                                                           NULL, NULL);

    return (int) retval;   /* error codes are listed in Apple's dns_sd.h */
}

const char *
dnssd_get_raop_txt(dnssd_t *dnssd_public, int *length)
{
    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    
    assert(length);

    *length = dnssd->TXTRecordGetLength(&dnssd->raop_record);
    return dnssd->TXTRecordGetBytesPtr(&dnssd->raop_record);
}

const char *
dnssd_get_airplay_txt(dnssd_t *dnssd_public, int *length)
{
    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    
    assert(length);

    *length = dnssd->TXTRecordGetLength(&dnssd->airplay_record);
    return dnssd->TXTRecordGetBytesPtr(&dnssd->airplay_record);
}

void
dnssd_unregister_raop(dnssd_t *dnssd_public)
{
    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    

    if (!dnssd->raop_service) {
        return;
    }

    /* Deallocate TXT record */
    dnssd->TXTRecordDeallocate(&dnssd->raop_record);

    dnssd->DNSServiceRefDeallocate(dnssd->raop_service);
    dnssd->raop_service = NULL;
}

void
dnssd_unregister_airplay(dnssd_t *dnssd_public)
{
    assert(dnssd_public);
    assert(dnssd_public->dnssd_private);
    dnssd_private_t *dnssd = (dnssd_private_t *) dnssd_public->dnssd_private;    

    if (!dnssd->airplay_service) {
        return;
    }

    /* Deallocate TXT record */
    dnssd->TXTRecordDeallocate(&dnssd->airplay_record);

    dnssd->DNSServiceRefDeallocate(dnssd->airplay_service);
    dnssd->airplay_service = NULL;
}

void dnssd_error_text(int *dnssd_error, const char *appname) {
    printf("*** dnssd_implementation: external, dns_sd.h\n");
    if (*dnssd_error == -65537) {
        printf("    No DNS-SD Server found (DNSServiceRegister call returned kDNSServiceErr_Unknown)\n");
    } else if (*dnssd_error == -65548) {
        printf("    DNSServiceRegister call returned kDNSServiceErr_NameConflict\n");
        printf("    Is another instance of %s running with the same DeviceID (MAC address) or using same network ports?\n",
	        appname);
        printf("    Use options -m ... and -p ... to allow multiple instances of %s to run concurrently\n", appname); 
    } else {
        printf("    mDNS Error codes are in range FFFE FF00 (-65792) to FFFE FFFF (-65537) "
	       "(see Apple's dns_sd.h)\n", *dnssd_error);
    }
}
