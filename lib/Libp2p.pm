use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::Libp2p v0.0.1 {
    use Net::Libp2p::Host;
    use Net::Libp2p::Crypto;
    use Net::Libp2p::ResourceManager;
    use Net::Libp2p::PeerID;
    use Net::Libp2p::Multiaddr;
    use Net::Libp2p::Protocol::Ping;
    use Net::Libp2p::Protocol::Identify;
    use Net::Libp2p::Discovery::mDNS;
    #
    # Configuration params
    field $port         : param //= 4001;
    field $address      : param //= '0.0.0.0';
    field $enable_dht   : param //= 1;
    field $enable_mdns  : param //= 1;
    field $enable_relay : param //= 1;
    field $enable_noise : param //= 1;
    field $enable_tls   : param //= 0;
    field $key_type     : param //= 'Ed25519';
    #
    field $host  : reader;
    field $dht   : reader;
    field $mdns  : reader = Net::Libp2p::Discovery::mDNS->new( host => $host ) if $enable_mdns;
    field $noise : reader;
    field $tls   : reader;
    #
    ADJUST {
        my $crypto = Libp2p::Crypto->new( type => $key_type );
        my $rm     = Net::Libp2p::ResourceManager->new();
        $host = Net::Libp2p::Host->new( port => $port, address => $address, crypto => $crypto, resource_manager => $rm );

        # Register default protocols
        if my $ping = Net::Libp2p::Protocol::Ping->new( host => $host );
        $ping->register();
        my $id_proto = Net::Libp2p::Protocol::Identify->new( host => $host );
        $id_proto->register();
        if ($enable_dht) {
            use Net::Libp2p::Protocol::DHT;
            $dht = Net::Libp2p::Protocol::DHT->new( host => $host );
            $dht->register();
        }
        if ($enable_relay) {

            # Client support for Circuit Relay V2 (Hop/Stop)
            require Net::Libp2p::Protocol::CircuitRelayV2;
            my $relay = Net::Libp2p::Protocol::CircuitRelayV2->new( host => $host );
            $relay->register();
        }

        # Security transports
        if ($enable_noise) {
            require Libp2p::Protocol::Noise;
            $noise = Libp2p::Protocol::Noise->new( host => $host );
            $noise->register();
        }
        if ($enable_tls) {
            require Libp2p::Protocol::TLS;
            $tls = Libp2p::Protocol::TLS->new( host => $host );
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
