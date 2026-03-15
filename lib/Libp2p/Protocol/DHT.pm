use v5.40;
use feature 'class';
no warnings 'experimental::class';

# Define DHT Protobuf messages
class Libp2p::Protocol::DHT::Message::Record : isa(Libp2p::ProtoBuf::Message) {
    field $key          : param : reader : writer(set_key)   = undef;
    field $value        : param : reader : writer(set_value) = undef;
    field $timeReceived : param : reader : writer(set_time)  = undef;
    __PACKAGE__->pb_field( 1, 'key',          'bytes',  writer => 'set_key' );
    __PACKAGE__->pb_field( 2, 'value',        'bytes',  writer => 'set_value' );
    __PACKAGE__->pb_field( 5, 'timeReceived', 'string', writer => 'set_time' );
}

class Libp2p::Protocol::DHT::Message::Peer : isa(Libp2p::ProtoBuf::Message) {
    field $id    : param : reader : writer(set_id) = undef;
    field $addrs : param : reader : writer(set_addrs) //= [];
    field $connection : param : reader : writer(set_conn) = 0;
    __PACKAGE__->pb_field( 1, 'id',         'bytes', writer   => 'set_id' );
    __PACKAGE__->pb_field( 2, 'addrs',      'bytes', repeated => 1, writer => 'set_addrs' );
    __PACKAGE__->pb_field( 3, 'connection', 'enum',  writer   => 'set_conn' );
}

class Libp2p::Protocol::DHT::Message : isa(Libp2p::ProtoBuf::Message) {
    field $type            : param : reader : writer(set_type)   = undef;
    field $clusterLevelRaw : param : reader : writer(set_level)  = undef;
    field $key             : param : reader : writer(set_key)    = undef;
    field $record          : param : reader : writer(set_record) = undef;
    field $closerPeers     : param : reader : writer(set_closer)   //= [];
    field $providerPeers   : param : reader : writer(set_provider) //= [];
    __PACKAGE__->pb_field( 1, 'type',            'enum',    writer => 'set_type' );
    __PACKAGE__->pb_field( 2, 'clusterLevelRaw', 'int32',   writer => 'set_level' );
    __PACKAGE__->pb_field( 3, 'key',             'bytes',   writer => 'set_key' );
    __PACKAGE__->pb_field( 4, 'record',          'message', class  => 'Libp2p::Protocol::DHT::Message::Record', writer => 'set_record' );
    __PACKAGE__->pb_field( 5, 'closerPeers',   'message', class => 'Libp2p::Protocol::DHT::Message::Peer', repeated => 1, writer => 'set_closer' );
    __PACKAGE__->pb_field( 6, 'providerPeers', 'message', class => 'Libp2p::Protocol::DHT::Message::Peer', repeated => 1, writer => 'set_provider' );
}
class Libp2p::Protocol::DHT v0.2.0 {
    use Libp2p::Future;
    use Algorithm::Kademlia;
    use Digest::SHA qw(sha256);
    field $host          : param;
    field $routing_table : reader = Algorithm::Kademlia::RoutingTable->new( local_id_bin => sha256( $host->peer_id->multihash ), k => 20 );
    field %providers;
    use constant PROTOCOL_ID => '/ipfs/kad/1.0.0';

    # Message Types
    use constant { PUT_VALUE => 0, GET_VALUE => 1, ADD_PROVIDER => 2, GET_PROVIDERS => 3, FIND_NODE => 4, PING => 5 };

    method register () {
        $host->set_handler( PROTOCOL_ID, sub ($ss) { $self->handle_stream($ss) } );
    }

    method _to_routing_id ($id_bin) {
        try {
            my $pid = Libp2p::PeerID->from_binary($id_bin);
            return sha256( $pid->multihash );
        }
        catch ($e) { }
        return sha256($id_bin) if length($id_bin) >= 34 && ( substr( $id_bin, 0, 2 ) eq "\x12\x20" || substr( $id_bin, 0, 2 ) eq "\x00\x24" );
        return $id_bin         if length($id_bin) == 32;
        return sha256($id_bin);
    }

    method find_node ($target_bin) {
        my $routing_id = $self->_to_routing_id($target_bin);
        my $search     = Algorithm::Kademlia::Search->new( target_id_bin => $routing_id, k => 20, alpha => 3 );
        $search->add_candidates( $routing_table->find_closest( $routing_id, 20 ) );
        return $self->_run_search( $search, FIND_NODE )->then(
            sub ($results) {
                my @formatted = map { { id => $_->{data}, addrs => $_->{addrs} } } @$results;
                return Libp2p::Future->resolve( \@formatted );
            }
        );
    }

    method find_peer ($target_bin) {
        my $routing_id = $self->_to_routing_id($target_bin);
        my $search     = Algorithm::Kademlia::Search->new( target_id_bin => $routing_id, k => 20, alpha => 3 );
        my @candidates = $routing_table->find_closest( $routing_id, 20 );
        $search->add_candidates(@candidates);
        return $self->_run_search( $search, FIND_NODE )->then(
            sub ($all_discovered) {
                for my $p (@$all_discovered) {
                    return Libp2p::Future->resolve( { id => $p->{id}, data => $p->{data}, addrs => $p->{addrs} } ) if $p->{id} eq $routing_id;
                }
                return Libp2p::Future->resolve(undef);
            }
        );
    }

    method provide ($key_bin) {
        my $routing_id = $self->_to_routing_id($key_bin);
        $providers{$routing_id}{ $host->peer_id->raw } = { addrs => [ map { $_->bytes } $host->listen_addrs->@* ], expiry => time() + 24 * 3600 };
        return $self->find_node($key_bin)->then(
            sub ($closer_peers) {
                my @futures;
                for my $peer (@$closer_peers) {
                    next if $peer->{id} eq $host->peer_id->raw;
                    push @futures, $self->_send_add_provider( { data => $peer->{id} }, $key_bin );
                }
                return @futures ? $host->io_utils->loop->wait_all(@futures) : Libp2p::Future->resolve();
            }
        );
    }

    method find_providers ($key_bin) {
        my $routing_id = $self->_to_routing_id($key_bin);
        my $search     = Algorithm::Kademlia::Search->new( target_id_bin => $routing_id, k => 20, alpha => 3 );
        $search->add_candidates( $routing_table->find_closest( $routing_id, 20 ) );
        my @found_providers;
        return $self->_run_search( $search, GET_PROVIDERS, \@found_providers )->then(
            sub {
                my %unique;
                for my $p (@found_providers) {
                    $unique{ $p->{data} } = { id => $p->{data}, addrs => $p->{addrs} };
                }
                return Libp2p::Future->resolve( [ values %unique ] );
            }
        );
    }

    method _run_search ( $search, $type, $results_ref = undef ) {
        $results_ref //= [];
        if ( $search->is_finished ) {
            my %all;
            for my $p ( $search->best_results, @$results_ref ) {
                $all{ $p->{id} } = $p;
            }
            return Libp2p::Future->resolve( [ values %all ] );
        }
        my @to_query = $search->next_to_query();
        if ( !@to_query ) {
            my %all;
            for my $p ( $search->best_results, @$results_ref ) {
                $all{ $p->{id} } = $p;
            }
            return Libp2p::Future->resolve( [ values %all ] );
        }
        my @futures;
        for my $peer (@to_query) {
            if ( $peer->{id} eq $routing_table->local_id_bin ) {
                $search->mark_responded( $peer->{id} );
                next;
            }
            my $f;
            if ( $type == FIND_NODE ) {
                $f = $self->_send_rpc( $peer, FIND_NODE, $search->target_id_bin );
            }
            elsif ( $type == GET_PROVIDERS ) {
                $f = $self->_send_rpc( $peer, GET_PROVIDERS, $search->target_id_bin );
            }
            push @futures, $f->then(
                sub ($resp) {
                    if ( $type == GET_PROVIDERS ) {
                        push @$results_ref,
                            map { { id => $self->_to_routing_id( $_->{id} ), data => $_->{id}, addrs => $_->{addrs} } }
                            ( $resp->{providers} // [] )->@*;
                    }
                    if ( $type == FIND_NODE ) {
                        push @$results_ref,
                            map { { id => $self->_to_routing_id( $_->{id} ), data => $_->{id}, addrs => $_->{addrs} } } ( $resp->{closer} // [] )->@*;
                    }
                    for my $p ( ( $resp->{closer} // [] )->@*, ( $resp->{providers} // [] )->@* ) {
                        try {
                            my $pid_obj = Libp2p::PeerID->from_binary( $p->{id} );
                            if ($pid_obj) {
                                for my $addr_bin ( ( $p->{addrs} // [] )->@* ) {
                                    try {
                                        my $ma = Libp2p::Multiaddr->from_bytes($addr_bin);
                                        $host->peer_store->add_addr( $pid_obj, $ma->string ) if $ma;
                                    }
                                    catch ($e) { }
                                }
                            }
                        }
                        catch ($e) { }
                    }
                    my @new_peers
                        = map { { id => $self->_to_routing_id( $_->{id} ), data => $_->{id}, addrs => $_->{addrs} } } ( $resp->{closer} // [] )->@*;

                    # Properly add candidates to search before marking responded
                    $search->add_candidates(@new_peers);
                    $search->mark_responded( $peer->{id} );
                    return Libp2p::Future->resolve();
                }
            )->else(
                sub {
                    $search->mark_failed( $peer->{id} );
                    return Libp2p::Future->resolve();
                }
            );
        }
        if (@futures) {
            return $host->io_utils->loop->wait_all(@futures)->then(
                sub {
                    my $next_f = Libp2p::Future->new();
                    $host->io_utils->loop->next_tick(
                        sub {
                            $self->_run_search( $search, $type, $results_ref )->then( sub { $next_f->done(@_) }, sub { $next_f->fail(@_) } );
                        }
                    );
                    return $next_f;
                }
            );
        }
        else {
            return $self->_run_search( $search, $type, $results_ref );
        }
    }

    method _send_rpc ( $peer, $type, $target_routing_bin ) {
        return $host->dial( $peer->{data}, PROTOCOL_ID )->then(
            sub ($ss) {
                my $req = Libp2p::Protocol::DHT::Message->new( type => $type, key => $target_routing_bin );
                return $ss->write_bin( $req->to_pb() )->then( sub { $ss->read_bin() } );
            }
        )->then(
            sub ($resp_data) {
                my $msg = Libp2p::Protocol::DHT::Message->from_pb($resp_data);
                return Libp2p::Future->resolve(
                    {   closer    => [ map { { id => $_->id, addrs => [ ( $_->addrs // [] )->@* ] } } ( $msg->closerPeers   // [] )->@* ],
                        providers => [ map { { id => $_->id, addrs => [ ( $_->addrs // [] )->@* ] } } ( $msg->providerPeers // [] )->@* ]
                    }
                );
            }
        );
    }

    method _send_add_provider ( $peer, $key_bin ) {
        return $host->dial( $peer->{data}, PROTOCOL_ID )->then(
            sub ($ss) {
                my $req = Libp2p::Protocol::DHT::Message->new(
                    type          => ADD_PROVIDER,
                    key           => $key_bin,
                    providerPeers => [
                        Libp2p::Protocol::DHT::Message::Peer->new(
                            id    => $host->peer_id->raw,
                            addrs => [ map { $_->bytes } $host->listen_addrs->@* ]
                        )
                    ]
                );
                return $ss->write_bin( $req->to_pb() );
            }
        );
    }

    method handle_stream ($ss) {
        return $ss->read_bin()->then(
            sub ($data) {
                my $msg         = Libp2p::Protocol::DHT::Message->from_pb($data);
                my $routing_key = $msg->key;
                if ( $msg->type == FIND_NODE ) {
                    my @closest = $routing_table->find_closest( $routing_key, 20 );
                    my $resp    = Libp2p::Protocol::DHT::Message->new(
                        type        => FIND_NODE,
                        closerPeers => [
                            map {
                                my $raw_id = $_->{data};
                                my $peer_msg;
                                try {
                                    my $pid_obj = Libp2p::PeerID->from_binary($raw_id);
                                    my @addrs;
                                    if ($pid_obj) {
                                        my $multiaddrs_strings = $host->peer_store->get_addrs($pid_obj);
                                        for my $ma_str (@$multiaddrs_strings) {
                                            my $ma = Libp2p::Multiaddr->new( string => $ma_str );
                                            push @addrs, $ma->to_binary if $ma;
                                        }
                                    }
                                    $peer_msg = Libp2p::Protocol::DHT::Message::Peer->new( id => $raw_id, addrs => \@addrs );
                                }
                                catch ($e) { }

                                # Explicitly return the object to map scope
                                $peer_msg ? ($peer_msg) : ()
                            } @closest
                        ]
                    );
                    return $ss->write_bin( $resp->to_pb() );
                }
                elsif ( $msg->type == ADD_PROVIDER ) {
                    my $provs = $msg->providerPeers // [];
                    for my $p ( $provs->@* ) {
                        $providers{$routing_key}{ $p->id } = { addrs => [ ( $p->addrs // [] )->@* ], expiry => time() + 24 * 3600 };
                    }
                    return Libp2p::Future->resolve();
                }
                elsif ( $msg->type == GET_PROVIDERS ) {
                    my @closest = $routing_table->find_closest( $routing_key, 20 );
                    my @provs;
                    if ( exists $providers{$routing_key} ) {
                        for my $pid_bin ( keys $providers{$routing_key}->%* ) {
                            if ( $providers{$routing_key}{$pid_bin}{expiry} > time() ) {
                                push @provs,
                                    Libp2p::Protocol::DHT::Message::Peer->new(
                                    id    => $pid_bin,
                                    addrs => [ ( $providers{$routing_key}{$pid_bin}{addrs} // [] )->@* ]
                                    );
                            }
                            else {
                                delete $providers{$routing_key}{$pid_bin};
                            }
                        }
                    }
                    my $resp = Libp2p::Protocol::DHT::Message->new(
                        type          => GET_PROVIDERS,
                        providerPeers => \@provs,
                        closerPeers   => [
                            map {
                                my $raw_id = $_->{data};
                                my $peer_msg;
                                try {
                                    my $pid_obj = Libp2p::PeerID->from_binary($raw_id);
                                    my @addrs;
                                    if ($pid_obj) {
                                        my $multiaddrs_strings = $host->peer_store->get_addrs($pid_obj);
                                        for my $ma_str (@$multiaddrs_strings) {
                                            my $ma = Libp2p::Multiaddr->new( string => $ma_str );
                                            push @addrs, $ma->to_binary if $ma;
                                        }
                                    }
                                    $peer_msg = Libp2p::Protocol::DHT::Message::Peer->new( id => $raw_id, addrs => \@addrs );
                                }
                                catch ($e) { }

                                # Explicitly return the object to map scope
                                $peer_msg ? ($peer_msg) : ()
                            } @closest
                        ]
                    );
                    return $ss->write_bin( $resp->to_pb() );
                }
                return Libp2p::Future->resolve();
            }
        );
    }
};
#
1;
