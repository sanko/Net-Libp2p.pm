use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Host v0.0.1 {
    use Libp2p::Utils qw[decode_varint encode_varint];
    use Libp2p::Stream;
    use Libp2p::Multiaddr;
    use Libp2p::PeerStore;
    use Libp2p::ConnectionManager;
    use Libp2p::ResourceManager;
    use Libp2p::IO;
    use Libp2p::Crypto;
    use Libp2p::PeerID;
    use FindBin;
    use File::Spec;
    use Socket qw[inet_ntoa getaddrinfo getnameinfo AF_INET AF_INET6 AF_UNSPEC SOCK_STREAM NI_NUMERICHOST NI_NUMERICSERV];
    $|++;
    #
    field $port             : param : reader //= 4001;
    field $address          : param : reader //= '0.0.0.0';
    field $crypto           : param : reader //= Libp2p::Crypto->new();
    field $peer_id          : param : reader //= $crypto->peer_id;
    field $resource_manager : param : reader //= Libp2p::ResourceManager->new();
    field $io_utils         : reader = Libp2p::IO->new();
    field $listener;
    field $handlers   : reader = {};
    field $protocols  : reader = {};
    field $peer_store : reader = Libp2p::PeerStore->new();
    field %_active_sessions;    # Store futures by stream ID
    field $ssl_key_file;
    field $ssl_cert_file;
    field $pubsub : reader : writer;
    field $conn_mgr : reader;
    #
    ADJUST {
        $conn_mgr = Libp2p::ConnectionManager->new( host => $self );
        my $root = File::Spec->catdir( $FindBin::Bin, '..' );
        $ssl_cert_file = File::Spec->rel2abs( 'server.crt', $root );
        $ssl_key_file  = File::Spec->rel2abs( 'server.key', $root );
        ( $listener, $port ) = $io_utils->listen_tcp(
            address    => $address,
            port       => $port,
            on_connect => sub ($sock) {
                $self->_handle_session($sock);
            }
        );
        $io_utils->register_host($self);
    }

    method set_handler ( $protocol, $code, $obj //= undef ) {
        $handlers->{$protocol}  = $code;
        $protocols->{$protocol} = $obj if defined $obj;
    }

    method listen_addrs () {

        # For now, just return the address and port we are listening on
        my $addr = $address eq '0.0.0.0' ? '127.0.0.1' : $address;
        return [ Libp2p::Multiaddr->new( string => "/ip4/$addr/tcp/$port" ) ];
    }

    method dial ( $addr_or_peerid, $protocol ) {
        my $multiaddr_str;
        my $pid_key;
        if ( $addr_or_peerid !~ m{^/} ) {
            $pid_key = $peer_store->_to_id_key($addr_or_peerid);
            my $existing = $conn_mgr->get_connection($pid_key);
            if ($existing) {
                say "[NETWORK][Host] Reusing existing connection to $pid_key for $protocol" if $ENV{DEBUG};
                if ( defined $existing->protocol && $existing->protocol eq $protocol ) {
                    say "[NETWORK] [Host] Protocol $protocol already active, skipping negotiation" if $ENV{DEBUG};
                    return Libp2p::Future->resolve($existing);
                }
                return $existing->negotiate($protocol)->then( sub { return $existing } );
            }
            my $addrs = $peer_store->get_addrs($pid_key);
            warn "[DEBUG] [Host] dial lookup for pid_key=$pid_key: found " . scalar(@$addrs) . " addrs\n" if $ENV{DEBUG};
            if (@$addrs) {
                $multiaddr_str = $addrs->[0];
            }
            else {
                if ( $ENV{DEBUG} ) {
                    my $stats = $peer_store->stats;
                    warn "[DEBUG] [Host] dial lookup FAILED for pid_key=$pid_key. Available keys: " . join( ", ", keys $stats->%* ) . "\n";
                }
                return $io_utils->loop->new_future->fail("No known addresses for peer: $pid_key");
            }
        }
        else {
            $multiaddr_str = $addr_or_peerid;
        }

        # Handle DNS resolution anywhere in the multiaddr string
        if ( $multiaddr_str =~ m{/(dns(?:4|6)?)/([^/]+)} ) {
            my $proto     = $1;
            my $host_name = $2;
            try {
                my $ip = $self->_resolve_dns( $host_name, $proto );
                if ($ip) {
                    my $is_ipv6 = ( $ip =~ /:/ );
                    if ( $proto eq 'dns6' && !$is_ipv6 ) {
                        return $io_utils->loop->new_future->fail("DNS6 resolved to IPv4: $ip");
                    }
                    if ( $proto eq 'dns4' && $is_ipv6 ) {
                        return $io_utils->loop->new_future->fail("DNS4 resolved to IPv6: $ip");
                    }
                    my $new_proto = $is_ipv6 ? 'ip6' : 'ip4';
                    $multiaddr_str =~ s{/$proto/$host_name}{/$new_proto/$ip};
                    say "[NETWORK] [Host] Resolved $host_name ($proto) to $ip ($new_proto)" if $ENV{DEBUG};
                }
            }
            catch ($e) {
                return $io_utils->loop->new_future->fail("Failed to resolve DNS for $host_name: $e");
            }
        }
        say "[NETWORK] [Host] Dialing $multiaddr_str for $protocol...";

        # Handle Relay addresses
        if ( $multiaddr_str =~ m{/p2p-circuit/p2p/([^/]+)} ) {
            my $target_pid = $1;
            my ($relay_part) = $multiaddr_str =~ m{^(.+)/p2p-circuit};
            say "[NETWORK] [Host] Relaying through $relay_part to $target_pid" if $ENV{DEBUG};
            my $relay_proto = $protocols->{'/libp2p/circuit/relay/0.2.0/hop'} // $protocols->{'/libp2p/circuit/relay/0.2.0/stop'};
            if ( !$relay_proto ) {
                for my $p ( values $protocols->%* ) {
                    if ( builtin::blessed($p) && $p->isa('Libp2p::Protocol::CircuitRelayV2') ) {
                        $relay_proto = $p;
                        last;
                    }
                }
            }
            return $io_utils->loop->new_future->fail('Relay protocol not registered on host') unless $relay_proto;
            my $relay_pid;
            if   ( $relay_part =~ m{/p2p/([^/]+)} ) { $relay_pid = $1 }
            else                                    { $relay_pid = $relay_part; }
            return $relay_proto->connect( $relay_pid, $target_pid )->then(
                sub ($ss) {
                    my $target_pid_str = $peer_store->_to_id_key($target_pid);
                    $ss->set_peer_id($target_pid_str) if $ss->can('set_peer_id');
                    $conn_mgr->add_connection( $target_pid_str, $ss );
                    return $ss->negotiate($protocol)->then( sub { return $ss } );
                }
            );
        }
        my $ma = Libp2p::Multiaddr->new( string => $multiaddr_str );
        my $conn_f;
        if ( $multiaddr_str =~ m{/(ws|wss)$} ) {
            $conn_f = $io_utils->connect_ws( host => $ma->address, port => $ma->port );
        }
        else {
            $conn_f = $io_utils->connect_tcp( host => $ma->address, port => $ma->port );
        }
        return $conn_f->then(
            sub ($handle) {
                unless ( $resource_manager->open_connection() ) {
                    $handle->close() if builtin::blessed($handle) && $handle->can('close');
                    return Libp2p::Future->reject("Resource limits exceeded");
                }
                if ( builtin::blessed($handle) && $handle->can('blocking') ) {
                    $handle->blocking(0);
                }
                my $stream = Libp2p::Stream->new( handle => $handle, loop => $io_utils->loop );
                $conn_mgr->add_connection( "$handle", $stream );
                $stream->on_close( sub { $resource_manager->close_connection() } );
                return $stream->negotiate($protocol)->then( sub { return $stream; } );
            }
        )->else(
            sub ($e) {
                warn "DIAL FAILED: $e";
                return $io_utils->loop->new_future->fail("Dial failed: $e");
            }
        );
    }

    method _handle_session ($handle) {
        my $stream;
        if ( builtin::blessed($handle) && $handle->isa('Libp2p::Stream') ) {
            $stream = $handle;
        }
        else {
            unless ( $resource_manager->open_connection() ) {
                warn "[NETWORK] Rejected incoming connection: resource limits exceeded\n";
                $handle->close() if builtin::blessed($handle) && $handle->can('close');
                return Libp2p::Future->reject("Resource limits exceeded");
            }
            if ( builtin::blessed($handle) && $handle->can('blocking') ) {
                $handle->blocking(0);
            }
            $stream = Libp2p::Stream->new( handle => $handle, loop => $io_utils->loop );
            try {
                my $remote_sockaddr = $handle->peername;
                if ($remote_sockaddr) {
                    my ( $remote_port, $remote_ip_bin ) = Socket::unpack_sockaddr_in($remote_sockaddr);
                    if ($remote_ip_bin) {
                        my $stats = $peer_store->stats;
                    OUTER: for my $pid_str ( keys $stats->%* ) {
                            for my $addr ( @{ $stats->{$pid_str}{addrs} // [] } ) {
                                my $ma;
                                try { $ma = Libp2p::Multiaddr->new( string => $addr ) }
                                catch ($e) {
                                    try { $ma = Libp2p::Multiaddr->from_bytes($addr) }
                                    catch ($e2) { }
                                }
                                if ( $ma && $ma->port == $remote_port ) {
                                    my $ma_ip_bin = Socket::inet_aton( $ma->address );
                                    my $remote_ip = Socket::inet_ntoa($remote_ip_bin);
                                    if (
                                        $ma_ip_bin &&
                                        ( $ma_ip_bin eq $remote_ip_bin ||
                                            ( $ma->address eq '0.0.0.0'   && $remote_ip eq '127.0.0.1' ) ||
                                            ( $ma->address eq '127.0.0.1' && $remote_ip eq '127.0.0.1' ) )
                                    ) {
                                        my $pid_obj;
                                        try { $pid_obj = Libp2p::PeerID->from_binary( pack( "H*", $pid_str ) ) }
                                        catch ($e) {
                                            if ( $pid_str =~ /^f([a-f0-9]+)$/i ) {
                                                try { $pid_obj = Libp2p::PeerID->from_binary( pack( "H*", $1 ) ) } catch ($e2) {
                                                }
                                            }
                                        }
                                        if ($pid_obj) {
                                            $stream->set_peer_id($pid_obj);
                                            $conn_mgr->add_connection( $pid_obj->to_string, $stream );
                                        }
                                        last OUTER;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            catch ($e) {

                # Ignore peername extraction failures quietly
            }
            say "[NETWORK][Host] Accepted connection";
            $conn_mgr->add_connection( "$handle", $stream );
            $stream->on_close( sub { $resource_manager->close_connection() } );
        }
        $stream->trigger_read_check();
        my $sid       = builtin::blessed( $stream->handle ) ? "${\$stream->handle}" : "$stream";
        my $session_f = $stream->read_msg()->then(
            sub ($msg) {
                if ( $msg eq "/multistream/1.0.0" ) {
                    say "[NETWORK] [Host] Received /multistream/1.0.0, ACKing" if $ENV{DEBUG};
                    return $stream->write_msg("/multistream/1.0.0")->then( sub { $stream->read_msg() } );
                }
                return Libp2p::Future->resolve($msg);
            }
        )->then(
            sub ($protocol) {
                say "[NETWORK] [Host] Peer requested protocol: $protocol" if $ENV{DEBUG};
                if ( my $handler = $handlers->{$protocol} ) {
                    return $stream->write_msg($protocol)->then(
                        sub {
                            $stream->set_protocol($protocol);
                            say "[NETWORK] [Host] Dispatching handler for $protocol" if $ENV{DEBUG};
                            my $f = $handler->($stream);
                            $stream->trigger_read_check();
                            return $f;
                        }
                    );
                }
                else {
                    say "[NETWORK] Protocol not supported: $protocol. Sent 'na'.";
                    return $stream->write_msg("na");
                }
            }
        );
        $session_f->else(
            sub ($e) {
                warn "[NETWORK] Error in _process_incoming_stream: $e\n" if $ENV{DEBUG};
                $stream->close();
            }
        )->finally(
            sub {
                delete $_active_sessions{$sid};
            }
        );
        $_active_sessions{$sid} = $session_f;
        return $session_f;
    }

    method _resolve_dns ( $hostname, $protocol ) {
        my $family = AF_UNSPEC;
        if    ( $protocol eq 'dns4' ) { $family = AF_INET; }
        elsif ( $protocol eq 'dns6' ) { $family = AF_INET6; }
        my ( $err, @res ) = getaddrinfo( $hostname, 0, { family => $family, socktype => SOCK_STREAM } );
        die "DNS resolution failed for $hostname: $err" if $err;
        die "No DNS records found for $hostname" unless @res;
        my ( $err_name, $ip, $port ) = getnameinfo( $res[0]->{addr}, NI_NUMERICHOST | NI_NUMERICSERV );
        die "Could not extract IP for $hostname: $err_name" if $err_name;
        return $ip;
    }
};
#
1;
