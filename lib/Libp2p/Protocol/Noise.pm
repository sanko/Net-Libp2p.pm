use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Libp2p::Protocol::Noise::HandshakePayload : isa(Libp2p::ProtoBuf::Message) {
    field $identityKey : param : reader : writer(set_key) //= undef;
    field $identitySig : param : reader : writer(set_sig) //= undef;
    __PACKAGE__->pb_field( 1, 'identityKey', 'bytes', writer => 'set_key' );
    __PACKAGE__->pb_field( 2, 'identitySig', 'bytes', writer => 'set_sig' );
}
class Libp2p::Protocol::Noise v0.0.1 {
    use Noise;
    use Libp2p::Future;
    use Libp2p::Protocol::Noise::SecureStream;
    field $host : param;
    use constant PROTOCOL_ID => '/noise';
    use constant PROLOGUE    => 'libp2p';

    method register () {
        $host->set_handler( PROTOCOL_ID, sub ($ss) { $self->handle_stream($ss) } );
    }

    method initiate_handshake ($stream) {
        say '[NETWORK] [Noise] Initiating handshake...' if $ENV{DEBUG};
        my $noise = Noise->new();

        # Libp2p uses Noise_XX_25519_ChaChaPoly_SHA256
        $noise->initialize_handshake( pattern => 'XX', initiator => 1, prologue => PROLOGUE, s => $host->crypto->static_x25519 );

        # Msg 1: -> e
        my $msg1 = $noise->write_message("");
        return $stream->write_bin($msg1)->then( sub { return $stream->read_bin(); } )->then(
            sub ($msg2) {

                # Msg 2: <- e, ee, s, es
                my $responder_payload_bin = $noise->read_message($msg2);

                # Verify Responder
                return $self->_verify_payload( $responder_payload_bin, $noise )->then(
                    sub {
                        # Msg 3: -> s, se, s(static_key), signature
                        my $payload = $self->_create_handshake_payload($noise);
                        my $msg3    = $noise->write_message($payload);
                        return $stream->write_bin($msg3);
                    }
                );
            }
        )->then(
            sub {
                my ( $c_send, $c_recv ) = $noise->split();
                return Libp2p::Future->resolve(
                    Libp2p::Protocol::Noise::SecureStream->new(
                        socket => $stream->handle,
                        loop   => $host->io_utils->loop,
                        c_send => $c_send,
                        c_recv => $c_recv
                    )
                );
            }
        );
    }

    method handle_stream ($stream) {
        say '[NETWORK] [Noise] Responding to handshake...' if $ENV{DEBUG};
        my $noise = Noise->new();
        $noise->initialize_handshake( pattern => 'XX', initiator => 0, prologue => PROLOGUE, s => $host->crypto->static_x25519 );
        return $stream->read_bin()->then(
            sub ($msg1) {

                # Msg 1: <- e
                $noise->read_message($msg1);

                # Msg 2: -> e, ee, s, es
                my $payload = $self->_create_handshake_payload($noise);
                my $msg2    = $noise->write_message($payload);
                return $stream->write_bin($msg2);
            }
        )->then( sub { return $stream->read_bin(); } )->then(
            sub ($msg3) {

                # Msg 3: <- s, se
                my $payload_bin = $noise->read_message($msg3);

                # Verify Initiator
                return $self->_verify_payload( $payload_bin, $noise )->then(
                    sub {
                        my ( $c_recv, $c_send ) = $noise->split();
                        return Libp2p::Future->resolve(
                            Libp2p::Protocol::Noise::SecureStream->new(
                                socket => $stream->handle,
                                loop   => $host->io_utils->loop,
                                c_send => $c_send,
                                c_recv => $c_recv
                            )
                        );
                    }
                );
            }
        );
    }

    method _create_handshake_payload ($noise) {
        my $pk       = $host->crypto->public_key_raw();
        my $static_k = $host->crypto->static_x25519_pub_raw();

        # libp2p noise spec: sign "noise-libp2p-static-key:" + static_key
        my $to_sign = 'noise-libp2p-static-key:' . $static_k;
        my $sig     = $host->crypto->sign($to_sign);
        my $payload = Libp2p::Protocol::Noise::HandshakePayload->new( identityKey => $pk, identitySig => $sig );
        return $payload->to_pb();
    }

    method _verify_payload ( $payload_bin, $noise_obj ) {
        my $payload = Libp2p::Protocol::Noise::HandshakePayload->from_pb($payload_bin);

        # Access remote static key from the Noise object
        # If your module uses $noise->handshake_state->rs, adjust accordingly:
        my $remote_static_pub = $noise_obj->handshake_state->rs->export_key_raw('public');

        #~ warn sprintf("VERIFY DATA: %s", unpack('H*', 'noise-libp2p-static-key:' . $remote_static_pub));
        #~ warn sprintf("SIGNATURE: %s", unpack('H*', $payload->identitySig));
        #~ warn sprintf("PUBKEY PB: %s", unpack('H*', $payload->identityKey));
        my $to_verify = 'noise-libp2p-static-key:' . $remote_static_pub;

        # Verify the signature
        # We pass the full protobuf bytes of the public key as the 3rd arg
        my $is_valid = $host->crypto->verify( $to_verify, $payload->identitySig, $payload->identityKey );
        return $is_valid ? Libp2p::Future->resolve() : Libp2p::Future->reject("Noise Handshake: Identity verification failed");
    }
};
1;
