// Created by Cyandev.

use super::*;

fn expect_bytes(result: RemoWireGuardResult, operation: RemoWireGuardOperation) -> Vec<u8> {
    assert_eq!(result.operation as u32, operation as u32);
    unsafe { slice::from_raw_parts(result.bytes, result.length) }.to_vec()
}

#[test]
fn wireguard_handshake_and_udp_datagrams() {
    let client_secret = [23; 32];
    let server_secret = [37; 32];
    let client_public = PublicKey::from(&StaticSecret::from(client_secret)).to_bytes();
    let server_public = PublicKey::from(&StaticSecret::from(server_secret)).to_bytes();
    let client_ip = [10, 14, 0, 2];
    let server_ip = [10, 14, 0, 1];
    let psk = [19; 32];
    unsafe {
        let client = remo_wg_new(
            &client_secret,
            &server_public,
            &psk,
            &client_ip,
            &server_ip,
            50000,
            7711,
            1,
        );
        let server = remo_wg_new(
            &server_secret,
            &client_public,
            &psk,
            &server_ip,
            &client_ip,
            7711,
            50000,
            2,
        );
        assert!(!remo_wg_is_ready(client));

        let initiation = expect_bytes(remo_wg_handshake(client), RemoWireGuardOperation::Send);
        let received = remo_wg_receive(server, initiation.as_ptr(), initiation.len());
        assert_eq!(CStr::from_ptr(received.receive_reason), c"controlHandshakeInit");
        assert_eq!(received.index_event, RemoWireGuardIndexEvent::SessionEstablished);
        let server_index = received.local_receiver_index;
        let response = expect_bytes(received, RemoWireGuardOperation::Send);
        let received = remo_wg_receive(client, response.as_ptr(), response.len());
        assert_eq!(CStr::from_ptr(received.receive_reason), c"controlHandshakeResponse");
        assert_eq!(received.index_event, RemoWireGuardIndexEvent::SessionEstablished);
        let client_index = received.local_receiver_index;
        assert_eq!(client_index.to_le_bytes(), initiation[4..8]);
        assert_eq!(server_index.to_le_bytes(), response[4..8]);
        let confirmation = expect_bytes(received, RemoWireGuardOperation::Send);
        assert!(remo_wg_is_ready(client));
        let keepalive = remo_wg_receive(server, confirmation.as_ptr(), confirmation.len());
        assert!(matches!(keepalive.operation, RemoWireGuardOperation::Idle));
        assert_eq!(CStr::from_ptr(keepalive.receive_reason), c"controlKeepalive");
        assert_eq!(keepalive.index_event, RemoWireGuardIndexEvent::DataAccepted);
        assert_eq!(keepalive.local_receiver_index, server_index);
        assert!(remo_wg_is_ready(server));
        let drain = remo_wg_receive(server, ptr::null(), 0);
        assert!(drain.receive_reason.is_null());
        let oversized = [0; MAX_WIRE + 1];
        let rejected = remo_wg_receive(server, oversized.as_ptr(), oversized.len());
        assert_eq!(CStr::from_ptr(rejected.receive_reason), c"outerOversize");


        for (sender, receiver, datagram) in [
            (client, server, vec![1, 2, 3]),
            (server, client, vec![42; MAX_DATAGRAM]),
        ] {
            let encrypted = expect_bytes(
                remo_wg_send(sender, datagram.as_ptr(), datagram.len()),
                RemoWireGuardOperation::Send,
            );
            assert_eq!((encrypted.len() - 32) % 16, 0);
            let received = remo_wg_receive(receiver, encrypted.as_ptr(), encrypted.len());
            let expected_index = if receiver == client { client_index } else { server_index };
            assert_eq!(received.index_event, RemoWireGuardIndexEvent::DataAccepted);
            assert_eq!(received.local_receiver_index, expected_index);
            let decrypted = expect_bytes(received, RemoWireGuardOperation::Deliver);
            assert_eq!(decrypted, datagram);
            let replay = remo_wg_receive(receiver, encrypted.as_ptr(), encrypted.len());
            assert!(matches!(replay.operation, RemoWireGuardOperation::Idle));
            assert_eq!(CStr::from_ptr(replay.receive_reason), c"wgDuplicateCounter");
            assert_eq!(replay.index_event, RemoWireGuardIndexEvent::None);

            let mut unknown = encrypted;
            let missing_index = expected_index ^ 1;
            unknown[4..8].copy_from_slice(&missing_index.to_le_bytes());
            let missing = remo_wg_receive(receiver, unknown.as_ptr(), unknown.len());
            assert_eq!(missing.index_event, RemoWireGuardIndexEvent::MissingSession);
            assert_eq!(missing.local_receiver_index, missing_index);
        }
        remo_wg_free(client);
        remo_wg_free(server);
    }
}

#[test]
fn udp_checksums_and_address_filters() {
    let flow = UdpFlow {
        source_ip: [10, 14, 0, 2],
        destination_ip: [10, 14, 0, 1],
        source_port: 50000,
        destination_port: 7711,
    };
    let mut packet = [0; MAX_INNER];
    let size = flow.encode(&[1, 2, 3], &mut packet);
    assert_eq!(flow.decode(&packet[..size]), Ok(&[1, 2, 3][..]));
    assert_eq!(
        UdpFlow {
            destination_port: 7712,
            ..flow
        }
        .decode(&packet[..size]),
        Err(c"innerDestinationPort")
    );
    assert_eq!(flow.reversed().decode(&packet[..size]), Err(c"innerSourceIp"));
    assert_eq!(flow.decode(&packet[..HEADERS + 2]), Err(c"innerIpTruncated"));

    packet[HEADERS] ^= 1;
    assert_eq!(flow.decode(&packet[..size]), Err(c"innerUdpChecksum"));
    packet[26..28].fill(0); // An IPv4 sender may omit the UDP checksum.
    assert_eq!(flow.decode(&packet[..size]), Ok(&[0, 2, 3][..]));
    packet[8] ^= 1;
    assert_eq!(flow.decode(&packet[..size]), Err(c"innerIpChecksum"));
}
