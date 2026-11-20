// Created by Cyandev.

#ifndef REMO_WIREGUARD_H
#define REMO_WIREGUARD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct RemoWireGuard RemoWireGuard;

typedef enum {
    RemoWireGuardIdle = 0,
    RemoWireGuardSend = 1,
    RemoWireGuardDeliver = 2,
} RemoWireGuardOperation;

typedef struct {
    RemoWireGuardOperation operation;
    // Borrowed until the next mutating call on this handle.
    const uint8_t * _Nullable bytes;
    size_t length;
} RemoWireGuardResult;

// All calls on a handle must be serialized.
RemoWireGuard * _Nonnull remo_wg_new(
    const uint8_t * _Nonnull private_key,
    const uint8_t * _Nonnull peer_key,
    const uint8_t * _Nullable preshared_key,
    const uint8_t * _Nonnull local_ip,
    const uint8_t * _Nonnull remote_ip,
    uint16_t local_port,
    uint16_t remote_port,
    uint32_t index
);
void remo_wg_free(RemoWireGuard * _Nonnull state);
bool remo_wg_is_ready(const RemoWireGuard * _Nonnull state);
RemoWireGuardResult remo_wg_handshake(RemoWireGuard * _Nonnull state);
RemoWireGuardResult remo_wg_tick(RemoWireGuard * _Nonnull state);
RemoWireGuardResult remo_wg_send(RemoWireGuard * _Nonnull state, const uint8_t * _Nullable bytes, size_t length);
// Pass NULL and 0 to drain BoringTun's queued output after a handshake.
RemoWireGuardResult remo_wg_receive(RemoWireGuard * _Nonnull state, const uint8_t * _Nullable bytes, size_t length);

#endif
