use v5.40;
use Test2::V0;
use blib;
use Libp2p::Host;
use Libp2p::Multiaddr;
use Libp2p::Crypto;
#
subtest 'Multiaddr DNS Parsing' => sub {
    my $ma1 = Libp2p::Multiaddr->new( string => '/dns4/localhost/tcp/1234' );
    is $ma1->string, '/dns4/localhost/tcp/1234', 'dns4 string parsing';
    my $ma2 = Libp2p::Multiaddr->new( bytes => $ma1->bytes );
    is $ma2->string, '/dns4/localhost/tcp/1234', 'dns4 binary roundtrip';
};
subtest 'Local DNS Resolution' => sub {
    my $c   = Libp2p::Crypto->new;
    my $h   = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $c->peer_id );
    my $f   = $h->dial( '/dns4/localhost/tcp/1234', '/test/1.0.0' );
    my $err = '';
    try {
        $h->io_utils->loop->await($f);
    }
    catch ($e) {
        $err = $e;
    }
    ok $f->is_failed, 'Dial future failed as expected';
    like $err, qr/actively refused|Connection failed|Dial failed/i, 'Error message confirms it attempted to dial (not a DNS fail)';
};
subtest 'Local DNS6 Resolution' => sub {
    my $c = Libp2p::Crypto->new;
    my $h = Libp2p::Host->new( port => 0, address => '::', peer_id => $c->peer_id );
    my $f = $h->dial( '/dns6/localhost/tcp/1234', '/test/1.0.0' );
    try {
        $h->io_utils->loop->await($f);
    }
    catch ($e) {
        if ( $e =~ /DNS resolution failed|DNS6 resolved to IPv4/ ) {
            todo 'Environment does not support IPv6 localhost resolution' => sub {
                fail 'DNS6 resolution returned IPv4 or failed';
            };
        }
        else {
            ok $f->is_failed, 'Dial future failed as expected';
            like $e, qr/actively refused|Connection failed|Dial failed/i, 'Error message confirms it attempted to dial IPv6';
        }
    }
};
subtest 'Real World Internet DNS Resolution' => sub {
    my $c = Libp2p::Crypto->new;
    my $h = Libp2p::Host->new( port => 0, address => '0.0.0.0', peer_id => $c->peer_id );

    # Direct Resolver Checks using google.com
    my $ip4;
    try { $ip4 = $h->_resolve_dns( 'google.com', 'dns4' ) } catch ($e) {
    }
    is $ip4, D(), 'Successfully resolved google.com via dns4 without exceptions';
    like $ip4, qr/^\d{1,3}(\.\d{1,3}){3}$/, 'google.com IPv4 successfully verified as: ' . $ip4;
    my $ip6;
    try { $ip6 = $h->_resolve_dns( 'google.com', 'dns6' ) } catch ($e) {
        if ($e) {
            todo 'Host network might lack IPv6 DNS capability' => sub {
                fail "google.com dns6 resolution (Error: $e)";
            };
        }
        else {
            like $ip6, qr/:/, 'google.com IPv6 successfully verified as: ' . $ip6;
        }
    };

    # Integration Check via Dialing
    my $f = $h->dial( '/dns4/example.com/tcp/12345', '/test/1.0.0' );
    try {
        $h->io_utils->loop->await($f);
    }
    catch ($e) {
        unlike $e, qr/Failed to resolve DNS/i,                                    'Dialing routine passed DNS phase for example.com';
        like $e,   qr/actively refused|Connection failed|Dial failed|timed out/i, 'Connection failed gracefully at TCP layer after DNS success';
    }
};
#
done_testing;
