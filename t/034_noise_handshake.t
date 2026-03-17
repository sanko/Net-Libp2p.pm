use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';

#~ use blib;
use lib '../lib';
use Libp2p::Host;
use Libp2p::Crypto;
use Libp2p::Protocol::Noise;
use Libp2p::Loop;
#
alarm(60);
$SIG{ALRM} = sub { die "Test timed out!\n" };
my $loop = Libp2p::Loop->get;
subtest 'Noise Handshake' => sub {
    my $c1 = Libp2p::Crypto->new;
    my $h1 = Libp2p::Host->new( port => 0, address => '127.0.0.1', crypto => $c1 );
    my $n1 = Libp2p::Protocol::Noise->new( host => $h1 );
    $n1->register();
    #
    my $c2 = Libp2p::Crypto->new;
    my $h2 = Libp2p::Host->new( port => 0, address => '127.0.0.1', crypto => $c2 );
    my $n2 = Libp2p::Protocol::Noise->new( host => $h2 );
    $n2->register();
    #
    $h1->peer_store->add_addr( $h2->peer_id->to_string, '/ip4/127.0.0.1/tcp/' . $h2->port );
    #
    diag 'Node 1 dialing Node 2 for /noise...';
    my $dial_f = $h1->dial( $h2->peer_id->to_string, '/noise' );

    # In our impl, dial() returns a Stream already negotiated to /noise
    # We then need to perform the Noise handshake on that stream.
    my $stream = $loop->await($dial_f);
    ok $stream, 'Dialed /noise successfully';
    #
    diag 'Performing Noise handshake...';
    my $handshake_f   = $n1->initiate_handshake($stream);
    my $secure_stream = $loop->await($handshake_f);
    #
    ok $secure_stream, 'Noise handshake completed';
    isa_ok $secure_stream, ['Libp2p::Protocol::Noise::SecureStream'];
};
#
done_testing;
