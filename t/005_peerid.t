use v5.40;
use Test2::V0;
use blib;
use Digest::SHA qw[sha256];
use Libp2p::PeerID;
#
my ( $expected_ed25519_mh, $expected_secp_mh, $expected_ecdsa_digest, $expected_ecdsa_mh );

# Length is 36 bytes. Since 36 <= 42, it MUST use the "identity" (0x00) multihash.
my $ed25519_pk_hex = '080112201ed1e8fae2c4a144b8be8fd4b47bf3d3b34b871c3cacf6010f0e42d474fce27e';
#
subtest ED25519 => sub {
    my $ed25519_pk   = pack( 'H*', $ed25519_pk_hex );
    my $peer_ed25519 = Libp2p::PeerID->from_public_key($ed25519_pk);
    is $peer_ed25519->hash,                   0x00,            'Ed25519 (<= 42 bytes) uses identity multihash type 0x00';
    is unpack( 'H*', $peer_ed25519->digest ), $ed25519_pk_hex, 'Ed25519 digest is the raw key itself';

    # Multihash format: <hash_type: 0x00> <length: 0x24 (36)> <digest>
    $expected_ed25519_mh = '0024' . $ed25519_pk_hex;
    is unpack( 'H*', $peer_ed25519->multihash ), $expected_ed25519_mh, 'Ed25519 multihash bytes exactly match';

    # Requires the multibase fix changing 'z' -> 'f' for Hex Lowercase representations.
    is $peer_ed25519->to_string, 'f' . $expected_ed25519_mh, 'to_string() correctly outputs multibase f + hex';
};
subtest Secp256k1 => sub {

    # Length is 37 bytes. Since 37 <= 42, it MUST use the "identity" (0x00) multihash.
    my $secp_pk_hex = '08021221037777e994e452c21604f91de093ce415f5432f701dd8cd1a7a6fea0e630bfca99';
    my $secp_pk     = pack( 'H*', $secp_pk_hex );
    my $peer_secp   = Libp2p::PeerID->from_public_key($secp_pk);
    is $peer_secp->hash,                   0x00,         'Secp256k1 (<= 42 bytes) uses identity multihash type 0x00';
    is unpack( 'H*', $peer_secp->digest ), $secp_pk_hex, 'Secp256k1 digest is the raw key itself';

    # Multihash format: <hash_type: 0x00> <length: 0x25 (37)> <digest>
    $expected_secp_mh = '0025' . $secp_pk_hex;
    is unpack( 'H*', $peer_secp->multihash ), $expected_secp_mh, 'Secp256k1 multihash bytes exactly match';
};
subtest ECDSA => sub {

    # Length is 93 bytes. Since 93 > 42, it MUST use the "sha2-256" (0x12) multihash.
    my $ecdsa_pk_hex
        = '0803125b3059301306072a8648ce3d020106082a8648ce3d03010703420004de3d300fa36ae0e8f5d530899d83abab44abf3161f162a4bc901d8e6ecda020e8b6d5f8da30525e71d6851510c098e5c47c646a597fb4dcec034e9f77c409e62';
    my $ecdsa_pk   = pack( 'H*', $ecdsa_pk_hex );
    my $peer_ecdsa = Libp2p::PeerID->from_public_key($ecdsa_pk);
    is $peer_ecdsa->hash, 0x12, 'ECDSA (> 42 bytes) uses sha2-256 multihash type 0x12';
    $expected_ecdsa_digest = unpack( 'H*', sha256($ecdsa_pk) );
    is unpack( 'H*', $peer_ecdsa->digest ), $expected_ecdsa_digest, 'ECDSA digest is the SHA2-256 hash of the key';

    # Multihash format: <hash_type: 0x12> <length: 0x20 (32)> <digest>
    $expected_ecdsa_mh = '1220' . $expected_ecdsa_digest;
    is unpack( 'H*', $peer_ecdsa->multihash ), $expected_ecdsa_mh, 'ECDSA multihash bytes exactly match';
};
subtest 'Raw Multihashes (CIDv0)' => sub {
    my $parsed_ed25519 = Libp2p::PeerID->from_binary( pack( 'H*', $expected_ed25519_mh ) );
    is $parsed_ed25519->version,                0,               'Parsed raw Ed25519 multihash correctly defaults to version 0';
    is $parsed_ed25519->hash,                   0x00,            'Parsed raw Ed25519 multihash extracts identity hash type';
    is unpack( 'H*', $parsed_ed25519->digest ), $ed25519_pk_hex, 'Parsed raw Ed25519 digest matches original key';
    my $parsed_ecdsa = Libp2p::PeerID->from_binary( pack( 'H*', $expected_ecdsa_mh ) );
    is $parsed_ecdsa->version,                0,                      'Parsed raw ECDSA multihash correctly defaults to version 0';
    is $parsed_ecdsa->hash,                   0x12,                   'Parsed raw ECDSA multihash extracts sha2-256 hash type';
    is unpack( 'H*', $parsed_ecdsa->digest ), $expected_ecdsa_digest, 'Parsed raw ECDSA digest matches';
};
subtest 'Binary Decoding: CIDv1 Format' => sub {

    # CIDv1 layout: <version: 0x01> <codec: 0x72 (libp2p-key)> <multihash>
    my $cidv1_hex    = '0172' . $expected_ecdsa_mh;
    my $parsed_cidv1 = Libp2p::PeerID->from_binary( pack( 'H*', $cidv1_hex ) );
    is $parsed_cidv1->version,                1,                      'Parsed CIDv1 correctly identifies version 1';
    is $parsed_cidv1->codec,                  0x72,                   'Parsed CIDv1 extracts libp2p-key codec (0x72)';
    is $parsed_cidv1->hash,                   0x12,                   'Parsed CIDv1 extracts sha2-256 hash type from inner multihash';
    is unpack( 'H*', $parsed_cidv1->digest ), $expected_ecdsa_digest, 'Parsed CIDv1 extracts correct digest';
};
subtest 'RSA Public Key' => sub {

    # Protobuf structure: field 1 (Type) = 0 (RSA), field 2 (Data) = ~294 bytes of DER.
    # Hex: 08 00 (Type=RSA) 12 86 02 (Data, length 262) + 262 bytes of dummy key data.
    # Because the length is ~267 bytes (> 42), it MUST use the "sha2-256" (0x12) multihash.
    my $rsa_pk_hex
        = '080012a60430820222300d06092a864886f70d01010105000382020f003082020a0282020100e1beab071d08200bde24eef00d049449b07770ff9910257b2d7d5dda242ce8f0e2f12e1af4b32d9efd2c090f66b0f29986dbb645dae9880089704a94e5066d594162ae6ee8892e6ec70701db0a6c445c04778eb3de1293aa1a23c3825b85c6620a2bc3f82f9b0c309bc0ab3aeb1873282bebd3da03c33e76c21e9beb172fd44c9e43be32e2c99827033cf8d0f0c606f4579326c930eb4e854395ad941256542c793902185153c474bed109d6ff5141ebf9cd256cf58893a37f83729f97e7cb435ec679d2e33901d27bb35aa0d7e20561da08885ef0abbf8e2fb48d6a5487047a9ecb1ad41fa7ed84f6e3e8ecd5d98b3982d2a901b4454991766da295ab78822add5612a2df83bcee814cf50973e80d7ef38111b1bd87da2ae92438a2c8cbcc70b31ee319939a3b9c761dbc13b5c086d6b64bf7ae7dacc14622375d92a8ff9af7eb962162bbddebf90acb32adb5e4e4029f1c96019949ecfbfeffd7ac1e3fbcc6b6168c34be3d5a2e5999fcbb39bba7adbca78eab09b9bc39f7fa4b93411f4cc175e70c0a083e96bfaefb04a9580b4753c1738a6a760ae1afd851a1a4bdad231cf56e9284d832483df215a46c1c21bdf0c6cfe951c18f1ee4078c79c13d63edb6e14feaeffabc90ad317e4875fe648101b0864097e998f0ca3025ef9638cd2b0caecd3770ab54a1d9c6ca959b0f5dcbc90caeefc4135baca6fd475224269bbe1b0203010001';
    my $rsa_pk   = pack( 'H*', $rsa_pk_hex );
    my $peer_rsa = Libp2p::PeerID->from_public_key($rsa_pk);
    is $peer_rsa->hash, 0x12, 'RSA (> 42 bytes) uses sha2-256 multihash type 0x12';
    my $expected_rsa_digest = unpack( 'H*', sha256($rsa_pk) );
    is unpack( 'H*', $peer_rsa->digest ), $expected_rsa_digest, 'RSA digest is the SHA2-256 hash of the key';

    # Multihash format: <hash_type: 0x12> <length: 0x20 (32)> <digest>
    my $expected_rsa_mh = '1220' . $expected_rsa_digest;
    is unpack( 'H*', $peer_rsa->multihash ), $expected_rsa_mh, 'RSA multihash bytes exactly match';
    #
    my $parsed_rsa = Libp2p::PeerID->from_binary( pack( 'H*', $expected_rsa_mh ) );
    is $parsed_rsa->version,                0,                    'Parsed raw RSA multihash correctly defaults to version 0';
    is $parsed_rsa->hash,                   0x12,                 'Parsed raw RSA multihash extracts sha2-256 hash type';
    is unpack( 'H*', $parsed_rsa->digest ), $expected_rsa_digest, 'Parsed raw RSA digest matches';
};
subtest Decoding => sub {
    subtest 'CIDv1 Base32' => sub {
        my $cid_str = 'bafzbeie5745rpv2m6tjyuugywy4d5ewrqgqqhfnf445he3omzpjbx5xqxe';
        my $peer1   = Libp2p::PeerID->decode($cid_str);
        is $peer1,                   D(),  'Parsed base32 CID string successfully';
        is $peer1->version,          1,    'Version is 1';
        is $peer1->codec,            0x72, 'Codec is libp2p-key (0x72)';
        is $peer1->hash,             0x12, 'Hash type is sha2-256 (0x12)';
        is length( $peer1->digest ), 32,   'Extracted digest is exactly 32 bytes';
    };
    subtest 'Base58BTC Legacy (sha2-256)' => sub {
        my $qm_str = 'QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N';
        my $peer2  = Libp2p::PeerID->decode($qm_str);
        is $peer2,                   D(),  'Parsed Qm base58btc string successfully';
        is $peer2->version,          0,    'Version defaults to 0';
        is $peer2->hash,             0x12, 'Hash type is sha2-256 (0x12)';
        is length( $peer2->digest ), 32,   'Extracted digest is exactly 32 bytes';
    };
    subtest 'Base58BTC Identity (ed25519)' => sub {
        my $ed_str = '12D3KooWD3eckifWpRn9wQpMG9R9hX3sD158z7EqHWmweQAJU5SA';
        my $peer3  = Libp2p::PeerID->decode($ed_str);
        is $peer3,                   D(),  'Parsed 12D base58btc string successfully';
        is $peer3->version,          0,    'Version defaults to 0';
        is $peer3->hash,             0x00, 'Hash type is identity (0x00)';
        is length( $peer3->digest ), 36,   'Extracted digest is exactly 36 bytes';
    };
};
#
done_testing;
