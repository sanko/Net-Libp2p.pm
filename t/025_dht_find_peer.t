use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';
use blib;
use Libp2p::Host;
use Libp2p::Crypto;
use Libp2p::Protocol::DHT;
use Libp2p::Loop;
use Digest::SHA qw[sha256];
#
alarm(60);
$SIG{ALRM} = sub { die "Test timed out!\n" };
my $loop = Libp2p::Loop->get;
subtest 'DHT FIND_PEER' => sub {

    # Setup 3 nodes
    my $c1 = Libp2p::Crypto->new;
    my $h1 = Libp2p::Host->new( port => 0, address => '127.0.0.1', crypto => $c1 );
    my $d1 = Libp2p::Protocol::DHT->new( host => $h1 );
    $d1->register();
    my $c2 = Libp2p::Crypto->new;
    my $h2 = Libp2p::Host->new( port => 0, address => '127.0.0.1', crypto => $c2 );
    my $d2 = Libp2p::Protocol::DHT->new( host => $h2 );
    $d2->register();
    my $c3 = Libp2p::Crypto->new;
    my $h3 = Libp2p::Host->new( port => 0, address => '127.0.0.1', crypto => $c3 );
    my $d3 = Libp2p::Protocol::DHT->new( host => $h3 );
    $d3->register();
    my $pid1  = $h1->peer_id;
    my $pid2  = $h2->peer_id;
    my $pid3  = $h3->peer_id;
    my $addr1 = '/ip4/127.0.0.1/tcp/' . $h1->port;
    my $addr2 = '/ip4/127.0.0.1/tcp/' . $h2->port;
    my $addr3 = '/ip4/127.0.0.1/tcp/' . $h3->port;

    # Bootstrap Topology: 1 -> 2 -> 3
    # Node 1 knows 2
    $h1->peer_store->add_addr( $pid2, $addr2 );
    $d1->routing_table->add_peer( sha256( $pid2->multihash ), $pid2->raw );

    # Node 2 knows 1 and 3
    $h2->peer_store->add_addr( $pid1, $addr1 );
    $d2->routing_table->add_peer( sha256( $pid1->multihash ), $pid1->raw );
    $h2->peer_store->add_addr( $pid3, $addr3 );
    $d2->routing_table->add_peer( sha256( $pid3->multihash ), $pid3->raw );

    # Node 3 knows 2
    $h3->peer_store->add_addr( $pid2, $addr2 );
    $d3->routing_table->add_peer( sha256( $pid2->multihash ), $pid2->raw );

    # Node 1 tries to find Node 3
    diag 'Node 1 searching for Node 3...';
    my $find_f    = $d1->find_peer( $pid3->raw );    # Pass full binary
    my $peer_info = $loop->await($find_f);

    # Allow deferred updates to settle
    $loop->tick(0.1);
    ok $peer_info, 'Found Node 3 info';
    is $peer_info->{data}, $pid3->raw, 'ID matches raw binary PeerID';

    # Check if address was added to Node 1's PeerStore
    my $addrs = $h1->peer_store->get_addrs($pid3);
    ok $addrs && @$addrs, 'Node 3 addresses added to PeerStore';
    is $addrs->[0], $addr3, 'Address matches expected multiaddr';
};
#
done_testing;
