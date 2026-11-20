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
        let response = expect_bytes(
            remo_wg_receive(server, initiation.as_ptr(), initiation.len()),
            RemoWireGuardOperation::Send,
        );
        let confirmation = expect_bytes(
            remo_wg_receive(client, response.as_ptr(), response.len()),
            RemoWireGuardOperation::Send,
        );
        assert!(remo_wg_is_ready(client));
        let keepalive = remo_wg_receive(server, confirmation.as_ptr(), confirmation.len());
        assert!(matches!(keepalive.operation, RemoWireGuardOperation::Idle));
        assert!(remo_wg_is_ready(server));

        for (sender, receiver, datagram) in [
            (client, server, vec![1, 2, 3]),
            (server, client, vec![42; MAX_DATAGRAM]),
        ] {
            let encrypted = expect_bytes(
                remo_wg_send(sender, datagram.as_ptr(), datagram.len()),
                RemoWireGuardOperation::Send,
            );
            assert_eq!((encrypted.len() - 32) % 16, 0);
            let decrypted = expect_bytes(
                remo_wg_receive(receiver, encrypted.as_ptr(), encrypted.len()),
                RemoWireGuardOperation::Deliver,
            );
            assert_eq!(decrypted, datagram);
            let replay = remo_wg_receive(receiver, encrypted.as_ptr(), encrypted.len());
            assert!(matches!(replay.operation, RemoWireGuardOperation::Idle));
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
    assert_eq!(flow.decode(&packet[..size]), Some(&[1, 2, 3][..]));
    assert_eq!(
        UdpFlow {
            destination_port: 7712,
            ..flow
        }
        .decode(&packet[..size]),
        None
    );
    assert_eq!(flow.reversed().decode(&packet[..size]), None);
    assert_eq!(flow.decode(&packet[..HEADERS + 2]), None);

    packet[HEADERS] ^= 1;
    assert_eq!(flow.decode(&packet[..size]), None);
    packet[26..28].fill(0); // An IPv4 sender may omit the UDP checksum.
    assert_eq!(flow.decode(&packet[..size]), Some(&[0, 2, 3][..]));
    packet[8] ^= 1;
    assert_eq!(flow.decode(&packet[..size]), None);
}
