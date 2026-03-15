use Test2::V0;
use blib;
use Libp2p::Crypto;
use Libp2p::PeerID;
#
subtest 'Ed25519 Key and PeerID' => sub {
    my $crypto = Libp2p::Crypto->new( type => 'Ed25519' );
    ok $crypto, 'crypto object created';
    is $crypto->type, 'Ed25519', 'type matches';
    my $pk_pb = $crypto->public_key_raw();
    ok length($pk_pb) <= 42, 'Ed25519 public key wrapped in PB is <= 42 bytes';
    my $peer_id = $crypto->peer_id();
    isa_ok $peer_id, ['Libp2p::PeerID'];
    is $peer_id->version, 0,    'v0 CID (Raw Multihash)';
    is $peer_id->codec,   0x72, 'libp2p-key codec';
    is $peer_id->hash,    0x00, 'identity hash';
    my $data = 'hello world';
    my $sig  = $crypto->sign($data);
    ok $sig, 'signature generated';
    ok $crypto->verify( $data,         $sig ), 'self-verify success';
    ok !$crypto->verify( "wrong data", $sig ), 'verify fails for wrong data';
};
subtest 'RSA Key and PeerID' => sub {

    # RSA 1024 will result in a public key larger than 42 bytes
    my $crypto = Libp2p::Crypto->new( type => 'RSA' );
    ok $crypto, 'crypto object created';
    is $crypto->type, 'RSA', 'type matches';
    my $pk_pb = $crypto->public_key_raw();
    ok length($pk_pb) > 42, 'RSA 1024 public key wrapped in PB is > 42 bytes';
    my $peer_id = $crypto->peer_id();
    isa_ok $peer_id, ['Libp2p::PeerID'];
    is $peer_id->version, 0,    'v0 CID (Raw Multihash)';
    is $peer_id->codec,   0x72, 'libp2p-key codec';
    is $peer_id->hash,    0x12, 'sha2-256 hash (due to length > 42)';
    my $data = 'hello world';
    my $sig  = $crypto->sign($data);
    ok $sig,                           'signature generated';
    ok $crypto->verify( $data, $sig ), 'self-verify success';
};
subtest 'Ed25519 Cross-Verification via Protobuf' => sub {
    my $alice          = Libp2p::Crypto->new( type => 'Ed25519' );
    my $message        = 'Hello Libp2p World!';
    my $signature      = $alice->sign($message);
    my $alice_pb_bytes = $alice->public_key_raw();
    my $bob            = Libp2p::Crypto->new( type => 'Ed25519' );
    my $is_valid       = $bob->verify( $message, $signature, $alice_pb_bytes );
    ok $is_valid, "Bob successfully verified Alice's signature via decoded protobuf";
    is $bob->verify( "Fake message", $signature, $alice_pb_bytes ), F(), 'Tampered messages correctly fail verification';
};
subtest 'RSA Cross-Verification via Protobuf' => sub {
    my $alice          = Libp2p::Crypto->new( type => 'RSA' );
    my $message        = 'Secure RSA Data';
    my $signature      = $alice->sign($message);
    my $alice_pb_bytes = $alice->public_key_raw();
    my $bob            = Libp2p::Crypto->new( type => 'Ed25519' );
    ok $bob->verify( $message, $signature, $alice_pb_bytes ), "Bob verified Alice's RSA signature via decoded protobuf";
};
done_testing;
