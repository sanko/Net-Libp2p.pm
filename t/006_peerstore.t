use Test2::V0;
use blib;
use Libp2p::PeerStore;
#
subtest 'Basic PeerStore Operations' => sub {
    my $ps      = Libp2p::PeerStore->new();
    my $peer_id = 'QmPeerID1';
    $ps->add_addr( $peer_id, '/ip4/127.0.0.1/tcp/4001' );
    $ps->add_addr( $peer_id, '/ip4/127.0.0.1/tcp/4001' );    # Duplicate
    is $ps->get_addrs($peer_id), ['/ip4/127.0.0.1/tcp/4001'], 'duplicate address not added';
    $ps->add_protocol( $peer_id, '/libp2p/noise' );
    $ps->add_protocol( $peer_id, '/libp2p/yamux' );
    is [ sort @{ $ps->get_protocols($peer_id) } ], [ '/libp2p/noise', '/libp2p/yamux' ], 'found two supported protocols';
    $ps->set_metadata( $peer_id, 'agent_version', 'perl-libp2p/0.01' );
    is $ps->get_metadata( $peer_id, 'agent_version' ), 'perl-libp2p/0.01', 'metadata stored';
};
subtest 'peers_supporting' => sub {
    my $ps = Libp2p::PeerStore->new();
    $ps->add_protocol( 'peer1', '/libp2p/noise' );
    $ps->add_protocol( 'peer1', '/libp2p/yamux' );
    $ps->add_protocol( 'peer2', '/libp2p/noise' );
    is [ sort @{ $ps->peers_supporting('/libp2p/noise') } ], [ 'peer1', 'peer2' ], 'found two peers supporting noise';
    is $ps->peers_supporting('/libp2p/yamux'),               ['peer1'],            'found one peer supporting yamux';
};
#
done_testing;
