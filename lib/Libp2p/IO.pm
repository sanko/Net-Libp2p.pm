use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::IO v0.0.1 {
    use warnings::register;
    use Libp2p::Loop;
    use Libp2p::Future;
    use IO::Socket::IP;
    use IO::Select;
    use Socket;
    use Errno qw[EAGAIN EWOULDBLOCK EINTR EINPROGRESS];
    #
    field $loop : reader = Libp2p::Loop->get();
    field @hosts;
    #
    method register_host ($h) { push @hosts, $h }

    method listen_tcp (%args) {
        my $port          = $args{port}    // 0;
        my $addr          = $args{address} // '0.0.0.0';
        my $on_connect_cb = $args{on_connect};
        my $sock          = IO::Socket::IP->new( LocalAddr => $addr, LocalPort => $port, Listen => 128, ReuseAddr => 1, Blocking => 0 ) or
            die "Could not create TCP socket on $addr:$port : $!";
        $loop->add_read_handler(
            $sock,
            sub ($lsock) {
                say "[DEBUG] [IO] Lsock read handler triggered" if $ENV{DEBUG};
                while ( my $new_sock = $lsock->accept ) {
                    say "[DEBUG] [IO] Accepted new connection" if $ENV{DEBUG};
                    $new_sock->blocking(0);
                    $on_connect_cb->($new_sock);
                }
            }
        );
        return ( $sock, $sock->sockport );
    }

    method connect_tcp (%args) {
        my $sock = IO::Socket::IP->new( PeerAddr => $args{host}, PeerPort => $args{port}, Blocking => 0 );
        my $f    = Libp2p::Future->new;
        return Libp2p::Future->reject( 'Connect failed: ' . $! ) unless $sock;
        if ( $sock->connected ) {
            $f->done($sock);
        }
        else {
            # Check if error happened immediately
            my $err = $sock->getsockopt( Socket::SOL_SOCKET, Socket::SO_ERROR );
            if ($err) {
                $! = $err;
                return Libp2p::Future->reject( 'Connection failed: ' . $! );
            }

            # Add to write AND exception sets (Windows needs the exception set)
            $loop->add_write_handler(
                $sock,
                sub ($s) {
                    $loop->remove_write_handler($s);
                    my $so_err = $s->getsockopt( Socket::SOL_SOCKET, Socket::SO_ERROR );
                    if ($so_err) {
                        $! = $so_err;
                        $f->fail( 'Connection failed: ' . $! );
                    }
                    else {
                        $f->done($s);
                    }
                }
            );
        }
        return $f;
    }

    method connect_ws (%args) {
        require Libp2p::Transport::Websocket;
        my $ts = Libp2p::Transport::Websocket->new( host => $args{host}, port => $args{port}, loop => $loop );
        $ts->connect();
    }
    method connected ($sock) { $sock->connected }

    method listen_udp (%args) {
        my $port       = $args{port}    // 0;
        my $addr       = $args{address} // '0.0.0.0';
        my $on_data_cb = $args{on_data};
        my $sock       = IO::Socket::IP->new( LocalAddr => $addr, LocalPort => $port, Proto => 'udp', Blocking => 0, ) or
            die "Could not create UDP socket on $addr:$port : $!";
        $loop->add_read_handler(
            $sock,
            sub ($s) {
                while ( my $sender = $s->recv( my $data, 65536 ) ) {
                    $on_data_cb->( $data, $sender );
                }
            }
        );
        $sock;
    }
    method send_udp ( $sock, $data, $dest ) { $sock->send( $data, 0, $dest ) }
    method run ()                           { $loop->run() }
    method loop_once ( $timeout //= 0.1 )   { $loop->tick($timeout) }
};
#
1;
