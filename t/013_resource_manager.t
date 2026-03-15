use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';
use blib;
use Libp2p::Host;
use Libp2p::Crypto;
use Libp2p::ResourceManager;
use Libp2p::Loop;
#
subtest 'Resource Manager Limits' => sub {
    my $loop = Libp2p::Loop->get;

    # Host with limit of 1 connection
    my $rm  = Libp2p::ResourceManager->new( max_connections => 1 );
    my $c1  = Libp2p::Crypto->new;
    my $h1  = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $c1->peer_id, resource_manager => $rm );
    my $c2  = Libp2p::Crypto->new;
    my $rm2 = Libp2p::ResourceManager->new();
    my $h2  = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $c2->peer_id, resource_manager => $rm2 );
    $h2->set_handler( '/test/1.0.0', sub { } );
    my $c3  = Libp2p::Crypto->new;
    my $rm3 = Libp2p::ResourceManager->new();
    my $h3  = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $c3->peer_id, resource_manager => $rm3 );
    $h3->set_handler( '/test/1.0.0', sub { } );

    # First connection should succeed
    my $f1 = $h1->dial( '/ip4/127.0.0.1/tcp/' . $h2->port, '/test/1.0.0' );
    my $s1 = $loop->await($f1);
    ok $s1, 'First connection succeeded';
    is $rm->stats->{connections}, 1, 'Stats show 1 connection';

    # Second connection should fail (outbound)
    my $f2 = $h1->dial( '/ip4/127.0.0.1/tcp/' . $h3->port, '/test/1.0.0' );
    try { $loop->await($f2) } catch ($e) {
        ok $f2->is_failed, 'Second connection failed';
        like $e, qr/Resource limits exceeded/, 'Error message is correct';
    }

    # Close first connection and try again
    $s1->close();
    $loop->tick(0.1);
    is $rm->stats->{connections}, 0, 'Stats show 0 connections after close';
    my $f3 = $h1->dial( '/ip4/127.0.0.1/tcp/' . $h3->port, '/test/1.0.0' );
    my $s3 = $loop->await($f3);
    ok $s3, 'Connection succeeded after previous one closed';
    is $rm->stats->{connections}, 1, 'Stats show 1 connection again';
};
#
done_testing;
