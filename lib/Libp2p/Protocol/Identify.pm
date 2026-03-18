use v5.40;
use feature 'class';
no warnings 'experimental::class';

package Libp2p::Protocol::Identify::Message {
    use feature 'class';

    class Libp2p::Protocol::Identify::Message : isa(Libp2p::ProtoBuf::Message) {
        field $protocolVersion : param : reader : writer(set_protocolVersion) = 'ipfs/0.1.0';
        field $agentVersion    : param : reader : writer(set_agentVersion)    = 'perl-libp2p/0.1.0';
        field $publicKey       : param : reader : writer(set_publicKey)       = undef;
        field $listenAddrs     : param : reader : writer(set_listenAddrs)     = [];
        field $observedAddr    : param : reader : writer(set_observedAddr)    = undef;
        field $protocols       : param : reader : writer(set_protocols)       = [];
        __PACKAGE__->pb_field( 5, 'protocolVersion', 'string', writer   => 'set_protocolVersion' );
        __PACKAGE__->pb_field( 6, 'agentVersion',    'string', writer   => 'set_agentVersion' );
        __PACKAGE__->pb_field( 1, 'publicKey',       'bytes',  writer   => 'set_publicKey' );
        __PACKAGE__->pb_field( 2, 'listenAddrs',     'bytes',  repeated => 1, writer => 'set_listenAddrs' );
        __PACKAGE__->pb_field( 4, 'observedAddr',    'bytes',  writer   => 'set_observedAddr' );
        __PACKAGE__->pb_field( 3, 'protocols',       'string', repeated => 1, writer => 'set_protocols' );
    }
}
class Libp2p::Protocol::Identify v0.0.1 {
    use Libp2p::Future;
    use Libp2p::Multiaddr;
    field $host : param;

    method register () {
        $host->set_handler( '/ipfs/id/1.0.0', sub { $self->handle_stream( $_[0] ) } );
    }

    method handle_stream ($ss) {
        my @bin_addrs = map { $_->to_binary } $host->listen_addrs->@*;
        my $msg       = Libp2p::Protocol::Identify::Message->new(
            publicKey   => $host->crypto->public_key_raw(),
            protocols   => [ keys %{ $host->handlers } ],
            listenAddrs => \@bin_addrs
        );
        return $ss->write_pb( $msg->to_pb() )->then( sub { $ss->close() } );
    }

    method request ($ss) {
        return $ss->read_pb()->then(
            sub ($data) {
                return Libp2p::Protocol::Identify::Message->from_pb($data);
            }
        );
    }
} 1;
