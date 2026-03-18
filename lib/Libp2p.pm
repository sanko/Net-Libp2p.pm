use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Libp2p v0.1.0 {
    use Libp2p::Host;
    use Libp2p::Crypto;
    use Libp2p::Security::Noise;
    use Libp2p::Security::TLS;
    use Libp2p::Protocol::Identify;

    sub new_node ( $class, %args ) {
        my $crypto = Libp2p::Crypto->new( type => ( $args{key_type} // 'Ed25519' ) );
        my $host   = Libp2p::Host->new( port => ( $args{port} // 4001 ), address => ( $args{address} // '0.0.0.0' ), crypto => $crypto );
        Libp2p::Security::Noise->new( host => $host )->register();
        Libp2p::Security::TLS->new( host => $host )->register();
        Libp2p::Protocol::Identify->new( host => $host )->register();
        return $host;
    }
} 1;
__END__
use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p v0.0.1 {
    use Libp2p::Host;
    use Libp2p::Crypto;
    use Libp2p::ResourceManager;
    use Libp2p::PeerID;
    use Libp2p::Multiaddr;
    #~ use Libp2p::Protocol::Ping;
     use Libp2p::Protocol::Identify;
    #~ use Libp2p::Discovery::mDNS;
    #
    # Configuration params
    field $port         : param //= 4001;
    field $address      : param //= '0.0.0.0';
    field $enable_dht   : param //= 1;
    field $enable_mdns  : param //= 0;
    field $enable_relay : param //= 1;
    field $enable_noise : param //= 1;
    field $enable_tls   : param //= 0;
    field $key_type     : param //= 'Ed25519';
    #
    field $host  : reader;
    field $dht   : reader;
    field $mdns  : reader = $enable_mdns ? Libp2p::Discovery::mDNS->new( host => $host ) : ();
    field $noise : reader;
    field $tls   : reader;
    #
    ADJUST {
        my $crypto = Libp2p::Crypto->new( type => $key_type );
        my $rm     = Libp2p::ResourceManager->new();
        $host = Libp2p::Host->new( port => $port, address => $address, crypto => $crypto, resource_manager => $rm );

        # Register default protocols
          #~ my $ping = Libp2p::Protocol::Ping->new( host => $host );
        #~ $ping->register();
        my $id_proto = Libp2p::Protocol::Identify->new( host => $host );
        $id_proto->register();
        my $identify = Libp2p::Protocol::Identify->new(host => $host);
        $identify->register();
        #
        if ($enable_dht) {
            use Libp2p::Routing::DHT;
            $dht = Libp2p::Routing::DHT->new( host => $host );
            $dht->register();
        }
        if ($enable_relay) {

            # Client support for Circuit Relay V2 (Hop/Stop)
            #~ require Libp2p::Protocol::CircuitRelayV2;
            #~ my $relay = Libp2p::Protocol::CircuitRelayV2->new( host => $host );
            #~ $relay->register();
        }

        # Security transports
        if ($enable_noise) {
            require Libp2p::Security::Noise;
            $noise = Libp2p::Security::Noise->new( host => $host );
            $noise->register();
        }
        if ($enable_tls) {
            require Libp2p::Security::TLS;
            $tls = Libp2p::Security::TLS->new( host => $host );
            $tls->register();
        }
    }

    method start () {
        $mdns->start() if $mdns;

        # Host is already listening via IO::Utils in ADJUST
        return $self;
    }
    method loop () { $host->io_utils->loop }

    method run () {
        $self->start();
        $self->loop->run();
    }
    method dial ( $addr_or_pid, $proto ) { $host->dial( $addr_or_pid, $proto ) }
    method peer_id ()                    { $host->peer_id }
    method listen_addrs ()               { $host->listen_addrs }
};
#
1;
