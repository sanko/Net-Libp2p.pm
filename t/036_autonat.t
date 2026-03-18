use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';
use lib '../lib', 'lib';
use Libp2p::Host;
use Libp2p::Loop;
use Libp2p::Protocol::AutoNAT;

# Setup
my $loop = Libp2p::Loop->get();
my $h1   = Libp2p::Host->new( address => '127.0.0.1', port => 0 );
my $h2   = Libp2p::Host->new( address => '127.0.0.1', port => 0 );
my $nat1 = Libp2p::Protocol::AutoNAT->new( host => $h1 );
my $nat2 = Libp2p::Protocol::AutoNAT->new( host => $h2 );
$nat1->register();
$nat2->register();

# Wait a bit for listeners to settle if needed (usually immediate in this lib)
subtest 'AutoNAT v1' => sub {

    # Node 1 asks Node 2 to check reachability via v1
    my $addr2 = '/ip4/127.0.0.1/tcp/' . $h2->port;
    my $f     = $nat1->check_reachability_v1($addr2);
    my $resp  = $loop->await($f);
    ok $resp, 'Got v1 response';
    is $resp->status, Libp2p::Protocol::AutoNAT::V1_OK, 'Status is OK';
    ok $resp->addr, 'Got reachability address';
};
subtest 'AutoNAT v2' => sub {

    # Node 1 asks Node 2 to check reachability via v2
    my $addr2 = '/ip4/127.0.0.1/tcp/' . $h2->port;
    my $f     = $nat1->check_reachability_v2($addr2);
    my $resp  = $loop->await($f);
    ok $resp, 'Got v2 response';
    is $resp->status, Libp2p::Protocol::AutoNAT::V2_OK, 'Status is OK';

    # addr_idx is 0 because we passed one address and it was verified
    is $resp->addr_idx, 0, 'Correct address index confirmed';
};
done_testing;
