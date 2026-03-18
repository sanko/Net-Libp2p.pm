use v5.40;
use feature 'class';
no warnings 'experimental::class';

# --- AutoNAT v1 Protobuf Messages ---
class Libp2p::Protocol::AutoNAT::V1::Message::Peer : isa(Libp2p::ProtoBuf::Message) {
    field $id : param : reader : writer(set_id) = undef;
    field $addrs : param : reader : writer(set_addrs) //= [];
    __PACKAGE__->pb_field( 1, 'id',    'bytes', repeated => 0, writer => 'set_id' );
    __PACKAGE__->pb_field( 2, 'addrs', 'bytes', repeated => 1, writer => 'set_addrs' );
}

class Libp2p::Protocol::AutoNAT::V1::Message::Dial : isa(Libp2p::ProtoBuf::Message) {
    field $peer : param : reader : writer(set_peer) = undef;
    __PACKAGE__->pb_field( 1, 'peer', 'message', class => 'Libp2p::Protocol::AutoNAT::V1::Message::Peer', writer => 'set_peer' );
}

class Libp2p::Protocol::AutoNAT::V1::Message::Response : isa(Libp2p::ProtoBuf::Message) {
    field $status     : param : reader : writer(set_status) = undef;
    field $statusText : param : reader : writer(set_text)   = undef;
    field $addr       : param : reader : writer(set_addr)   = undef;
    __PACKAGE__->pb_field( 1, 'status',     'enum',   writer => 'set_status' );
    __PACKAGE__->pb_field( 2, 'statusText', 'string', writer => 'set_text' );
    __PACKAGE__->pb_field( 3, 'addr',       'bytes',  writer => 'set_addr' );
}

class Libp2p::Protocol::AutoNAT::V1::Message : isa(Libp2p::ProtoBuf::Message) {
    field $type     : param : reader : writer(set_type) = undef;
    field $dial     : param : reader : writer(set_dial) = undef;
    field $response : param : reader : writer(set_resp) = undef;
    __PACKAGE__->pb_field( 1, 'type',     'enum',    writer => 'set_type' );
    __PACKAGE__->pb_field( 2, 'dial',     'message', class  => 'Libp2p::Protocol::AutoNAT::V1::Message::Dial',     writer => 'set_dial' );
    __PACKAGE__->pb_field( 3, 'response', 'message', class  => 'Libp2p::Protocol::AutoNAT::V1::Message::Response', writer => 'set_resp' );
}

# --- AutoNAT v2 Protobuf Messages ---
class Libp2p::Protocol::AutoNAT::V2::Message::DialRequest v0.0.1 : isa(Libp2p::ProtoBuf::Message) {
    field $addrs : param : reader : writer(set_addrs) //= [];
    field $nonce : param : reader : writer(set_nonce) = undef;
    __PACKAGE__->pb_field( 1, 'addrs', 'bytes', repeated => 1, writer => 'set_addrs' );
    __PACKAGE__->pb_field( 2, 'nonce', 'uint64', writer => 'set_nonce' );
} class Libp2p::Protocol::AutoNAT::V2::Message::DialResponse v0.0.1 : isa(Libp2p::Protocol::AutoNAT::V2::Message::DialRequest) {
    field $status   : param : reader : writer(set_status) = undef;
    field $addr_idx : param : reader : writer(set_idx)    = undef;
    __PACKAGE__->pb_field( 1, 'status',   'enum',   writer => 'set_status' );
    __PACKAGE__->pb_field( 2, 'addr_idx', 'uint32', writer => 'set_idx' );
} class Libp2p::Protocol::AutoNAT::V2::Message::DialBack v0.0.1 : isa(Libp2p::ProtoBuf::Message) {
    field $nonce : param : reader : writer(set_nonce) = undef;
    __PACKAGE__->pb_field( 1, 'nonce', 'uint64', writer => 'set_nonce' );
} class Libp2p::Protocol::AutoNAT::V2::Message::DialBackResponse v0.0.1 : isa(Libp2p::ProtoBuf::Message) {
    field $status : param : reader : writer(set_status) = undef;
    __PACKAGE__->pb_field( 1, 'status', 'enum', writer => 'set_status' );
    }
    #
    class Libp2p::Protocol::AutoNAT v0.0.1 {
    use Libp2p::Future;
    use Libp2p::Multiaddr;
    use constant {
        PROTOCOL_V1          => '/libp2p/autonat/1.0.0',
        PROTOCOL_V2          => '/libp2p/autonat/2.0.0',            # v2 usually includes dialback logic
        PROTOCOL_V2_DIALBACK => '/libp2p/autonat/2.0.0/dialback',
    };

    # v1 Status Codes
    use constant { V1_OK => 0, V1_DIAL_ERROR => 100, V1_DIAL_REFUSED => 101, V1_BAD_REQUEST => 102, V1_INTERNAL_ERROR => 103, };

    # v2 Status Codes
    use constant { V2_OK => 0, V2_E_DIAL_ERROR => 1, V2_E_DIAL_REFUSED => 2, V2_E_BAD_REQUEST => 3, V2_E_INTERNAL_ERROR => 4, };
    field $host : param;
    field %v2_nonces;    # Store nonces we are expecting for dialback

    method register () {
        $host->set_handler( PROTOCOL_V1,          sub ($ss) { $self->handle_v1($ss) } );
        $host->set_handler( PROTOCOL_V2,          sub ($ss) { $self->handle_v2($ss) } );
        $host->set_handler( PROTOCOL_V2_DIALBACK, sub ($ss) { $self->handle_v2_dialback($ss) } );

        # v1 dial-back often uses /multistream/1.0.0 as a probe
        $host->set_handler( "/multistream/1.0.0", sub ($ss) { $ss->close(); } );
    }

    method handle_v1 ($ss) {
        return $ss->read_bin()->then(
            sub ($data) {
                my $msg = Libp2p::Protocol::AutoNAT::V1::Message->from_pb($data);
                if ( !$msg || $msg->type != 1 ) {    # 1 = DIAL
                    return $self->_send_v1_resp( $ss, V1_BAD_REQUEST, "Invalid request type" );
                }
                my $peer_info = $msg->dial->peer;
                my @addrs     = map { Libp2p::Multiaddr->new( bytes => $_ )->string } ( $peer_info->addrs // [] )->@*;

                # Attempt to dial back one of the addresses
                return $self->_attempt_dial_back( \@addrs )->then(
                    sub ($success_addr) {
                        if ($success_addr) {
                            return $self->_send_v1_resp( $ss, V1_OK, "OK", $success_addr );
                        }
                        else {
                            return $self->_send_v1_resp( $ss, V1_DIAL_ERROR, "Dial failed" );
                        }
                    }
                );
            }
        );
    }

    method _send_v1_resp ( $ss, $status, $text, $addr = undef ) {
        my $resp = Libp2p::Protocol::AutoNAT::V1::Message::Response->new(
            status     => $status,
            statusText => $text,
            addr       => $addr ? Libp2p::Multiaddr->new( string => $addr )->bytes : undef
        );
        my $msg = Libp2p::Protocol::AutoNAT::V1::Message->new( type => 2, response => $resp );    # 2 = RESPONSE
        return $ss->write_bin( $msg->to_pb() );
    }
    #
    method handle_v2 ($ss) {
        return $ss->read_bin()->then(
            sub ($data) {
                my $req   = Libp2p::Protocol::AutoNAT::V2::Message::DialRequest->from_pb($data);
                my @addrs = map { Libp2p::Multiaddr->new( bytes => $_ )->string } ( $req->addrs // [] )->@*;
                my $nonce = $req->nonce;

                # Attempt dial back with nonce
                return $self->_attempt_v2_dial_back( \@addrs, $nonce )->then(
                    sub ($res) {
                        my ( $status, $idx ) = @$res;
                        my $resp = Libp2p::Protocol::AutoNAT::V2::Message::DialResponse->new( status => $status, addr_idx => $idx );
                        return $ss->write_bin( $resp->to_pb() );
                    }
                );
            }
        );
    }

    method handle_v2_dialback ($ss) {
        return $ss->read_bin()->then(
            sub ($data) {
                my $db     = Libp2p::Protocol::AutoNAT::V2::Message::DialBack->from_pb($data);
                my $nonce  = $db->nonce;
                my $status = V2_OK;
                if ( !exists $v2_nonces{$nonce} ) {
                    $status = V2_E_BAD_REQUEST;
                }
                else {
                    # Resolve the future waiting for this dialback
                    $v2_nonces{$nonce}->done(1);
                    delete $v2_nonces{$nonce};
                }
                my $resp = Libp2p::Protocol::AutoNAT::V2::Message::DialBackResponse->new( status => $status );
                return $ss->write_bin( $resp->to_pb() );
            }
        );
    }

    method _attempt_dial_back ($addrs) {
        my $f    = Libp2p::Future->new;
        my @list = @$addrs;
        my $try_next;
        $try_next = sub {
            if ( !@list ) { return $f->done(undef); }
            my $addr = shift @list;
            $host->dial( $addr, "/multistream/1.0.0" )->then(
                sub ($ss) {
                    $ss->close();
                    $f->done($addr);
                }
            )->else(
                sub {
                    $try_next->();
                }
            );
        };
        $try_next->();
        return $f;
    }

    method _attempt_v2_dial_back ( $addrs, $nonce ) {
        my $f    = Libp2p::Future->new;
        my @list = @$addrs;
        my $try_next;
        $try_next = sub {
            my $idx = shift @list;    # Actually we need the index
            if ( !defined $idx ) { return $f->done( [ V2_E_DIAL_ERROR, 0 ] ); }
            my $addr = $addrs->[$idx];
            $host->dial( $addr, PROTOCOL_V2_DIALBACK )->then(
                sub ($ss) {
                    my $db = Libp2p::Protocol::AutoNAT::V2::Message::DialBack->new( nonce => $nonce );
                    return $ss->write_bin( $db->to_pb() )->then( sub { $ss->read_bin() } );
                }
            )->then(
                sub ($resp_data) {
                    my $resp = Libp2p::Protocol::AutoNAT::V2::Message::DialBackResponse->from_pb($resp_data);
                    if ( $resp->status == V2_OK ) {
                        $f->done( [ V2_OK, $idx ] );
                    }
                    else {
                        $try_next->();
                    }
                }
            )->else(
                sub {
                    $try_next->();
                }
            );
        };

        # Start with a list of indices
        @list = ( 0 .. $#$addrs );
        $try_next->();
        return $f;
    }
    #
    method check_reachability_v1 ($peer_addr) {
        return $host->dial( $peer_addr, PROTOCOL_V1 )->then(
            sub ($ss) {
                my $my_peer = Libp2p::Protocol::AutoNAT::V1::Message::Peer->new(
                    id    => $host->peer_id->raw,
                    addrs => [ map { $_->bytes } $host->listen_addrs->@* ]
                );
                my $dial = Libp2p::Protocol::AutoNAT::V1::Message::Dial->new( peer => $my_peer );
                my $msg  = Libp2p::Protocol::AutoNAT::V1::Message->new( type => 1, dial => $dial );
                return $ss->write_bin( $msg->to_pb() )->then( sub { $ss->read_bin() } );
            }
        )->then(
            sub ($data) {
                my $msg = Libp2p::Protocol::AutoNAT::V1::Message->from_pb($data);
                return Libp2p::Future->resolve( $msg->response );
            }
        );
    }

    method check_reachability_v2 ($peer_addr) {
        my $nonce  = int( rand( 2**64 ) );
        my $wait_f = Libp2p::Future->new;
        $v2_nonces{$nonce} = $wait_f;
        return $host->dial( $peer_addr, PROTOCOL_V2 )->then(
            sub ($ss) {
                my $req = Libp2p::Protocol::AutoNAT::V2::Message::DialRequest->new(
                    addrs => [ map { $_->bytes } $host->listen_addrs->@* ],
                    nonce => $nonce
                );
                return $ss->write_bin( $req->to_pb() )->then( sub { $ss->read_bin() } );
            }
        )->then(
            sub ($data) {
                my $resp = Libp2p::Protocol::AutoNAT::V2::Message::DialResponse->from_pb($data);
                if ( $resp->status == V2_OK ) {

                    # We expect a dialback!
                    # wait_f should resolve when dialback arrives.
                    return $wait_f->then( sub { Libp2p::Future->resolve($resp) } );
                }
                return Libp2p::Future->resolve($resp);
            }
        );
    }
    };
#
1;
