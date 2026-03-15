use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';

#~ use blib;
use lib '../lib';
use Libp2p::Host;
use Libp2p::Crypto;
use Libp2p::IO;
#
alarm(60);
$SIG{ALRM} = sub { die "Test timed out!\n" };
my $loop = Libp2p::Loop->get;
#
my $crypto1        = Libp2p::Crypto->new;
my $host1          = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $crypto1->peer_id );
my $proto          = '/test/1.0.0';
my $handler_called = 0;
$host1->set_handler(
    $proto => sub ($stream) {
        $handler_called = 1;
        $stream->read_msg()->then(
            sub ($msg) {
                if ( $msg eq 'ping' ) {
                    return $stream->write_msg('pong');
                }
            }
        );
    }
);
my $crypto2 = Libp2p::Crypto->new;
my $host2   = Libp2p::Host->new( port => 0, address => '127.0.0.1', peer_id => $crypto2->peer_id );
#
diag 'Dialing...';
my $ma     = '/ip4/127.0.0.1/tcp/' . $host1->port;
my $dial_f = $host2->dial( $ma, $proto );

# We MUST tick the loop while waiting for the dial to complete
# because both sides need the same loop to progress.
my $stream = $loop->await($dial_f);
ok $stream, 'Dialed and negotiated successfully';
diag 'Writing ping...';
my $write_f = $stream->write_msg('ping');
$loop->await($write_f);
diag 'Reading pong...';
my $read_f   = $stream->read_msg();
my $response = $loop->await($read_f);
is $response, 'pong', 'Received correct response string';
ok $handler_called, 'Handler was called';
#
done_testing;
