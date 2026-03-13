use v5.40;
use Test2::V0;
use Libp2p::IO;
use Libp2p::Loop;
use Time::HiRes qw(time);
my $io   = Libp2p::IO->new;
my $loop = Libp2p::Loop->get;
subtest 'tcp connect' => sub {
    my ( $server_sock, $port ) = $io->listen_tcp(
        port       => 0,
        address    => '127.0.0.1',
        on_connect => sub ($conn) {
            $conn->syswrite("HELLO\n");
            $conn->close;
        }
    );
    ok( $server_sock, 'server listening' );
    ok( $port,        "port is $port" );
    my $f = $io->connect_tcp( host => '127.0.0.1', port => $port );
    my $client_sock;
    $f->then(
        sub ($sock) {
            $client_sock = $sock;
        }
    )->catch(
        sub ($err) {
            diag "Connect failed: $err";
        }
    );

    # Run loop until client connects
    my $start = time;
    while ( !$client_sock && time - $start < 5 ) {
        $loop->tick(0.1);
    }
    ok( $client_sock, 'client connected' );
    if ($client_sock) {
        my $buf;
        my $read_f = Libp2p::Future->new;
        $loop->add_read_handler(
            $client_sock,
            sub ($s) {
                my $ret = $s->sysread( $buf, 1024 );
                if ( defined $ret && $ret > 0 ) {
                    $read_f->done($buf);
                    $loop->remove_read_handler($s);
                }
                elsif ( defined $ret && $ret == 0 ) {

                    # EOF
                }
            }
        );
        $start = time;
        while ( !$read_f->is_ready && time - $start < 5 ) {
            $loop->tick(0.1);
        }
        is( $read_f->get, "HELLO\n", 'received data' );
    }
};
done_testing;
