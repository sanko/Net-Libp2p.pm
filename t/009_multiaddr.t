use v5.40;
use Test2::V0;
use blib;
use Libp2p::Multiaddr;
#
my $qm = 'QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N';
#
subtest 'Basic IP4/TCP Address' => sub {
    my $m1 = Libp2p::Multiaddr->from_string('/ip4/127.0.0.1/tcp/8080');
    is $m1->string, '/ip4/127.0.0.1/tcp/8080', 'String is preserved';

    # IP4 code: 0x04, 127.0.0.1: 7f 00 00 01
    # TCP code: 0x06, 8080: 1f 90
    is unpack( 'H*', $m1->to_binary ), '047f000001061f90', 'Binary encoding of basic IPv4/TCP is correct';
};
subtest 'IPv6 Address' => sub {

    # Using the RFC 5952 standard short form for 2001:0db8:0000:0000:0000:0000:0000:0001
    my $str = '/ip6/2001:db8::1/tcp/8080';
    my $m1  = Libp2p::Multiaddr->from_string($str);
    is $m1->string, $str, 'IPv6 string representation is preserved';

    # IP6 Code: 0x29 (41)
    # 2001:db8::1 => 20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 01
    # TCP Code: 0x06 (6)
    # 8080 => 1f 90
    my $expected_hex = '2920010db8000000000000000000000001061f90';
    is unpack( 'H*', $m1->to_binary ), $expected_hex, 'Binary encoding of IPv6/TCP is correct';

    # Test reverse (bytes to string)
    my $m2 = Libp2p::Multiaddr->from_bytes( pack( 'H*', $expected_hex ) );
    is $m2->string, $str, 'IPv6 perfectly round-trips from binary to string';
};
subtest 'P2P (CIDv0) Specification Validation' => sub {
    my $m2 = Libp2p::Multiaddr->from_string("/p2p/$qm");
    is $m2->string, "/p2p/$qm", 'P2P string representation preserved';
    my $hex = unpack( 'H*', $m2->to_binary );

    # 1) 421 encoded as varint: a503
    # 2) Length of decoded Qm hash (34 bytes): 22
    # 3) Decoded Multihash (SHA2-256 starts with 0x12, length 0x20): 1220...
    like $hex, qr/^a503221220/, 'Binary correctly leads with Code 421, Length 34, and Multihash identifier';
};
subtest 'P2P / IPFS Alias Interoperability' => sub {
    my $m2 = Libp2p::Multiaddr->from_string("/p2p/$qm");

    # Backwards compatibility requirement: /ipfs must parse as code 421, identically to /p2p
    my $m3 = Libp2p::Multiaddr->from_string("/ipfs/$qm");
    is unpack( 'H*', $m3->to_binary ), unpack( 'H*', $m2->to_binary ), '/ipfs yields exactly the same binary as /p2p';

    # When reconstructing from bytes, code 421 MUST strictly be converted back to /p2p
    my $m4 = Libp2p::Multiaddr->from_bytes( $m3->to_binary );
    is $m4->string, "/p2p/$qm", 'Reconstructed binary normalizes /ipfs aliasing back to /p2p';
};
subtest 'Nested/Composite Addresses (Relays)' => sub {
    my $composite_str
        = "/ip6/2001:8a0:7ac5:4201:3ac9:86ff:fe31:7095/tcp/4001/p2p/$qm/p2p-circuit/p2p/12D3KooWD3eckifWpRn9wQpMG9R9hX3sD158z7EqHWmweQAJU5SA";
    my $m5 = Libp2p::Multiaddr->from_string($composite_str);

    # Reconstruct from bytes to test entire pipeline
    my $m6 = Libp2p::Multiaddr->from_bytes( $m5->to_binary );
    is $m6->string, $composite_str, 'Composite string containing IPv6, TCP, P2P, circuit, and P2P perfectly round-trips from binary to string';
};
subtest 'No-Value Protocols' => sub {
    my $ws_str = "/dns4/example.com/tcp/443/wss";
    my $m7     = Libp2p::Multiaddr->from_string($ws_str);
    is $m7->string, $ws_str, 'WSS (Size 0) parsed and maintained without stealing next argument';
    my $m8 = Libp2p::Multiaddr->from_bytes( $m7->to_binary );
    is $m8->string, $ws_str, 'WSS round-trips from binary perfectly';
};
#
done_testing();
