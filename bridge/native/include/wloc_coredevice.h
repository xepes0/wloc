#ifndef WLOC_COREDEVICE_H
#define WLOC_COREDEVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PairingSession PairingSession;
typedef struct LocationSession LocationSession;

typedef void (*WLOCPairingReadyCallback)(
    void *context,
    const char *service_identifier,
    uint16_t port,
    const char *const *txt_keys,
    const char *const *txt_values,
    size_t txt_count
);

typedef void (*WLOCPairingPinCallback)(void *context, const char *pin);
typedef void (*WLOCLocationStartedCallback)(void *context);

typedef struct {
    char *error_message;
    uint8_t *pairing_record;
    size_t pairing_record_length;
    uint8_t *host_alt_irk;
    size_t host_alt_irk_length;
} WLOCPairingResult;

typedef struct {
    char *error_message;
} WLOCLocationResult;

PairingSession *wloc_pairing_session_create(void);
void wloc_pairing_session_cancel(PairingSession *session);
void wloc_pairing_session_destroy(PairingSession *session);
int32_t wloc_pairing_session_run(
    PairingSession *session,
    const char *host_name,
    const char *host_model,
    WLOCPairingReadyCallback ready_callback,
    WLOCPairingPinCallback pin_callback,
    void *context,
    WLOCPairingResult *result
);
void wloc_pairing_result_destroy(WLOCPairingResult *result);

LocationSession *wloc_location_session_create(void);
int32_t wloc_location_session_update(
    LocationSession *session,
    double latitude,
    double longitude
);
void wloc_location_session_cancel(LocationSession *session);
void wloc_location_session_destroy(LocationSession *session);
int32_t wloc_location_session_run(
    LocationSession *session,
    const uint8_t *pairing_record,
    size_t pairing_record_length,
    const char *peer_address,
    uint16_t remote_pairing_port,
    const char *service_identifier,
    const char *auth_tag,
    double latitude,
    double longitude,
    WLOCLocationStartedCallback started_callback,
    void *context,
    WLOCLocationResult *result
);
void wloc_location_result_destroy(WLOCLocationResult *result);

#ifdef __cplusplus
}
#endif

#endif
