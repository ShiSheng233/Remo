// Created by Cyandev.

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use std::ptr;
use std::slice;

const MAX_DATAGRAM: usize = 1200;
const IPV4_HEADER: usize = 20;
const UDP_HEADER: usize = 8;
const HEADERS: usize = IPV4_HEADER + UDP_HEADER;
const MAX_INNER: usize = (HEADERS + MAX_DATAGRAM).next_multiple_of(16);
// Also accommodates a full-size incoming packet with IPv4 options and WireGuard padding.
const MAX_WIRE: usize = 1500;

#[derive(Clone, Copy)]
struct UdpFlow {
    source_ip: [u8; 4],
    destination_ip: [u8; 4],
    source_port: u16,
    destination_port: u16,
}

impl UdpFlow {
    fn reversed(self) -> Self {
        Self {
            source_ip: self.destination_ip,
            destination_ip: self.source_ip,
            source_port: self.destination_port,
            destination_port: self.source_port,
        }
    }

    fn encode(self, datagram: &[u8], packet: &mut [u8; MAX_INNER]) -> usize {
        let size = HEADERS + datagram.len();
        let padded = size.next_multiple_of(16);
        packet[..HEADERS].fill(0);
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(size as u16).to_be_bytes());
        packet[6] = 0x40; // Don't fragment.
        packet[8] = 64;
        packet[9] = 17;
        packet[12..16].copy_from_slice(&self.source_ip);
        packet[16..20].copy_from_slice(&self.destination_ip);
        let ip_checksum = checksum(&[&packet[..IPV4_HEADER]]);
        packet[10..12].copy_from_slice(&ip_checksum.to_be_bytes());

        packet[20..22].copy_from_slice(&self.source_port.to_be_bytes());
        packet[22..24].copy_from_slice(&self.destination_port.to_be_bytes());
        packet[24..26].copy_from_slice(&((size - IPV4_HEADER) as u16).to_be_bytes());
        packet[HEADERS..size].copy_from_slice(datagram);
        let udp_checksum = udp_checksum(self, &packet[IPV4_HEADER..size]);
        let udp_checksum = if udp_checksum == 0 {
            u16::MAX
        } else {
            udp_checksum
        };
        packet[26..28].copy_from_slice(&udp_checksum.to_be_bytes());
        packet[size..padded].fill(0);
        padded
    }

    fn decode(self, packet: &[u8]) -> Option<&[u8]> {
        if packet.len() < HEADERS || packet[0] >> 4 != 4 || packet[9] != 17 {
            return None;
        }
        let header_size = usize::from(packet[0] & 0x0f) * 4;
        let total_size = usize::from(read_u16(&packet[2..4]));
        if header_size < IPV4_HEADER
            || total_size < header_size + UDP_HEADER
            || total_size > packet.len()
            || read_u16(&packet[6..8]) & 0xbfff != 0
            || packet[12..16] != self.source_ip
            || packet[16..20] != self.destination_ip
            || checksum(&[&packet[..header_size]]) != 0
        {
            return None;
        }
        let udp = &packet[header_size..total_size];
        if read_u16(&udp[..2]) != self.source_port
            || read_u16(&udp[2..4]) != self.destination_port
            || usize::from(read_u16(&udp[4..6])) != udp.len()
            || udp.len() > UDP_HEADER + MAX_DATAGRAM
            || (read_u16(&udp[6..8]) != 0 && udp_checksum(self, udp) != 0)
        {
            return None;
        }
        Some(&udp[UDP_HEADER..])
    }
}

fn read_u16(bytes: &[u8]) -> u16 {
    u16::from_be_bytes([bytes[0], bytes[1]])
}

// All slices except the last have even lengths.
fn checksum(parts: &[&[u8]]) -> u16 {
    let mut sum = 0u32;
    for part in parts {
        let (words, tail) = part.as_chunks::<2>();
        sum += words
            .iter()
            .map(|word| u32::from(u16::from_be_bytes(*word)))
            .sum::<u32>();
        if let [last] = tail {
            sum += u32::from(*last) << 8;
        }
    }
    while sum > u32::from(u16::MAX) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn udp_checksum(flow: UdpFlow, udp: &[u8]) -> u16 {
    checksum(&[
        &flow.source_ip,
        &flow.destination_ip,
        &[0, 17],
        &(udp.len() as u16).to_be_bytes(),
        udp,
    ])
}

pub struct RemoWireGuard {
    tunnel: Tunn,
    flow: UdpFlow,
    inner: [u8; MAX_INNER],
    output: [u8; MAX_WIRE],
}

#[repr(C)]
pub enum RemoWireGuardOperation {
    Idle,
    Send,
    Deliver,
}

#[repr(C)]
pub struct RemoWireGuardResult {
    operation: RemoWireGuardOperation,
    bytes: *const u8,
    length: usize,
}

impl RemoWireGuardResult {
    fn idle() -> Self {
        Self {
            operation: RemoWireGuardOperation::Idle,
            bytes: ptr::null(),
            length: 0,
        }
    }

    fn from_tunnel(result: TunnResult<'_>, inbound_flow: Option<UdpFlow>) -> Self {
        let (operation, bytes) = match result {
            TunnResult::WriteToNetwork(bytes) => (RemoWireGuardOperation::Send, &*bytes),
            TunnResult::WriteToTunnelV4(packet, _) => {
                let Some(datagram) = inbound_flow.and_then(|flow| flow.decode(packet)) else {
                    return Self::idle();
                };
                (RemoWireGuardOperation::Deliver, datagram)
            }
            _ => return Self::idle(),
        };
        Self {
            operation,
            bytes: bytes.as_ptr(),
            length: bytes.len(),
        }
    }
}

/// # Safety
/// Each key must point to 32 bytes and each address to 4 bytes. The PSK may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_new(
    private_key: *const [u8; 32],
    peer_key: *const [u8; 32],
    preshared_key: *const [u8; 32],
    local_ip: *const [u8; 4],
    remote_ip: *const [u8; 4],
    local_port: u16,
    remote_port: u16,
    index: u32,
) -> *mut RemoWireGuard {
    let tunnel = Tunn::new(
        StaticSecret::from(unsafe { *private_key }),
        PublicKey::from(unsafe { *peer_key }),
        unsafe { preshared_key.as_ref().copied() },
        None,
        index,
        None,
    );
    Box::into_raw(Box::new(RemoWireGuard {
        tunnel,
        flow: UdpFlow {
            source_ip: unsafe { *local_ip },
            destination_ip: unsafe { *remote_ip },
            source_port: local_port,
            destination_port: remote_port,
        },
        inner: [0; MAX_INNER],
        output: [0; MAX_WIRE],
    }))
}

/// # Safety
/// The handle must be live, and no other call or read of its output may be in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_free(state: *mut RemoWireGuard) {
    drop(unsafe { Box::from_raw(state) });
}

/// # Safety
/// Requires exclusive access to a live handle. Output is borrowed until the next mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_handshake(state: *mut RemoWireGuard) -> RemoWireGuardResult {
    let state = unsafe { &mut *state };
    RemoWireGuardResult::from_tunnel(
        state
            .tunnel
            .format_handshake_initiation(&mut state.output, false),
        None,
    )
}

/// # Safety
/// The handle must be live and cannot be mutated during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_is_ready(state: *const RemoWireGuard) -> bool {
    unsafe { &*state }
        .tunnel
        .time_since_last_handshake()
        .is_some()
}

/// # Safety
/// Requires exclusive access to a live handle. Output is borrowed until the next mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_tick(state: *mut RemoWireGuard) -> RemoWireGuardResult {
    let state = unsafe { &mut *state };
    RemoWireGuardResult::from_tunnel(state.tunnel.update_timers(&mut state.output), None)
}

/// # Safety
/// Requires exclusive access to a live handle. Nonempty input must point to `length`
/// readable bytes outside the handle. Output is borrowed until the next mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_send(
    state: *mut RemoWireGuard,
    bytes: *const u8,
    length: usize,
) -> RemoWireGuardResult {
    if length == 0 || length > MAX_DATAGRAM {
        return RemoWireGuardResult::idle();
    }
    let state = unsafe { &mut *state };
    let datagram = unsafe { slice::from_raw_parts(bytes, length) };
    let length = state.flow.encode(datagram, &mut state.inner);
    RemoWireGuardResult::from_tunnel(
        state
            .tunnel
            .encapsulate(&state.inner[..length], &mut state.output),
        None,
    )
}

/// # Safety
/// Requires exclusive access to a live handle. Nonempty input must point to `length`
/// readable bytes outside the handle. Output is borrowed until the next mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remo_wg_receive(
    state: *mut RemoWireGuard,
    bytes: *const u8,
    length: usize,
) -> RemoWireGuardResult {
    if length > MAX_WIRE {
        return RemoWireGuardResult::idle();
    }
    let state = unsafe { &mut *state };
    // An empty input drains packets queued by BoringTun during a handshake.
    let packet = if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(bytes, length) }
    };
    RemoWireGuardResult::from_tunnel(
        state.tunnel.decapsulate(None, packet, &mut state.output),
        Some(state.flow.reversed()),
    )
}

#[cfg(test)]
mod tests;
