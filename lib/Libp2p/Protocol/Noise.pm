use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Protocol::Noise::HandshakePayload v0.0.1 : isa(Libp2p::ProtoBuf::Message) {
    field $identityKey : param : reader : writer(set_identityKey) //= undef;
    field $identitySig : param : reader : writer(set_identitySig) //= undef;
    __PACKAGE__->pb_field( 1, 'identityKey', 'bytes', writer => 'set_identityKey' );
    __PACKAGE__->pb_field( 2, 'identitySig', 'bytes', writer => 'set_identitySig' );
};
#
class Libp2p::Protocol::Noise::SecureStream v0.0.1 : isa(Libp2p::Stream) {
    use Scalar::Util qw[weaken blessed];
    use Errno qw[EAGAIN EWOULDBLOCK];
    field $c_send : param;
    field $c_recv : param;
    field $initial_buffer : param //= '';
    field $raw_read_buffer = $initial_buffer;
    ADJUST {
        # Decrypt anything passed in during the handshake immediately
        $self->_decrypt_available_packets();
    }

    method syswrite ($data) {
        my $empty_ad = "";
        my $h        = $self->handle;
        my $offset   = 0;
        my $len      = length($data);

        # Handle empty write/ACK packet correctly
        if ( $len == 0 ) {
            my $cipher = $c_send->encrypt_with_ad( $empty_ad, "" );
            my $packet = pack( 'n', length($cipher) ) . $cipher;
            blessed($h) ? $h->syswrite($packet) : syswrite( $h, $packet );
            return 0;
        }

        # Chunk packets per the Noise specs (Maximum protocol message length is 65535,
        # subtracting 16 bytes for auth tag leaves 65519)
        while ( $offset < $len ) {
            my $chunk_size = $len - $offset;
            $chunk_size = 65519 if $chunk_size > 65519;
            my $chunk  = substr( $data, $offset, $chunk_size );
            my $cipher = $c_send->encrypt_with_ad( $empty_ad, $chunk );
            my $packet = pack( 'n', length($cipher) ) . $cipher;
            my $sent   = blessed($h) ? $h->syswrite($packet) : syswrite( $h, $packet );
            if ( !defined $sent ) {
                return undef if $offset == 0;
                last;
            }
            $offset += $chunk_size;
        }
        return $offset;
    }

    # Robust read handler
    method _on_read_ready () {
        my $buf  = '';
        my $h    = $self->handle;
        my $read = blessed($h) ? $h->sysread( $buf, 65536 ) : sysread( $h, $buf, 65536 );
        if ( defined $read && $read > 0 ) {
            $raw_read_buffer .= $buf;
        }
        elsif ( defined $read && $read == 0 ) {
            $self->close();
            return;
        }
        elsif ( !defined $read && !( $! == EAGAIN || $! == EWOULDBLOCK ) ) {
            $self->close();
            return;
        }

        # ALWAYS try to decrypt, even if 0 bytes were read,
        # because there might be a full packet waiting in $raw_read_buffer
        $self->_decrypt_available_packets();
    }

    method _decrypt_available_packets () {
        my $state          = $self->_state;
        my $found_new_data = 0;
        while ( length($raw_read_buffer) >= 2 ) {
            my $packet_len = unpack( 'n', substr( $raw_read_buffer, 0, 2 ) );
            if ( length($raw_read_buffer) >= 2 + $packet_len ) {
                substr( $raw_read_buffer, 0, 2, '' );
                my $cipher = substr( $raw_read_buffer, 0, $packet_len, '' );

                # Explicitly pass empty string for decryption as well
                my $empty_ad = "";
                my $plain    = eval { $c_recv->decrypt_with_ad( $empty_ad, $cipher ) };
                if ($@) {
                    warn "[SECURE] Decryption failed (possibly wrong AD): $@";
                    $self->close();
                    return;
                }
                $state->{read_buffer} .= $plain;
                $found_new_data = 1;
            }
            else { last; }
        }
        $self->_process_pending_reads() if $found_new_data;
    }

    # Ensure the parent's loop-level triggers work for the secure layer
    method trigger_read_check () {
        $self->_on_read_ready();
        $self->SUPER::trigger_read_check();
    }
};
#
class Libp2p::Protocol::Noise v0.0.1 {
    use Noise;
    use Libp2p::Future;
    #
    field $host : param;
    #
    method register () {
        $host->set_handler( '/noise', sub { $self->handle_stream( $_[0] ) } );
    }

    method handle_stream ($stream) {
        my $noise = Noise->new( prologue => '' );
        $noise->initialize_handshake( pattern => 'XX', initiator => 0, s => $host->crypto->static_x25519 );
        return $stream->read_bin()->then(
            sub ($msg1) {
                eval { $noise->read_message($msg1) };
                die "Noise Decryption Error: $@" if $@;
                my $payload = $self->_create_handshake_payload();
                my $msg2    = $noise->write_message($payload);
                return $stream->write_bin($msg2);
            }
        )->then(
            sub {
                return $stream->read_bin();
            }
        )->then(
            sub ($msg3) {
                my $payload_bin = eval { $noise->read_message($msg3) };
                die "Noise Decryption Error: $@" if $@;
                return $self->_verify_payload( $payload_bin, $noise );
            }
        )->then(
            sub {
                my ( $c_send, $c_recv ) = $noise->split();
                my $existing = $stream->can('_state') ? $stream->_state->{read_buffer} : '';
                $stream->set_is_upgraded(1);
                my $secure_stream = Libp2p::Protocol::Noise::SecureStream->new(
                    handle         => $stream->handle,
                    loop           => $host->io_utils->loop,
                    c_send         => $c_send,
                    c_recv         => $c_recv,
                    initial_buffer => $existing
                );
                return Libp2p::Future->resolve($secure_stream);
            }
        );
    }

    method initiate_handshake ($stream) {
        my $noise = Noise->new( prologue => '' );
        $noise->initialize_handshake( pattern => 'XX', initiator => 1, s => $host->crypto->static_x25519 );
        my $msg1 = $noise->write_message("");
        return $stream->write_bin($msg1)->then(
            sub {
                return $stream->read_bin();
            }
        )->then(
            sub ($msg2) {
                my $payload_bin = eval { $noise->read_message($msg2) };
                die "Noise Decryption Error: $@" if $@;
                return $self->_verify_payload( $payload_bin, $noise )->then(
                    sub {
                        my $payload = $self->_create_handshake_payload();

                        # write_message transitions the internal state to the end of the handshake
                        my $msg3 = $noise->write_message($payload);
                        return $stream->write_bin($msg3);
                    }
                );
            }
        )->then(
            sub {
                # Split MUST happen after write_message for Msg 3 is called
                my ( $c_send, $c_recv ) = $noise->split();

                # Capture any trailing bytes already in the TCP buffer
                my $existing = $stream->can('_state') ? $stream->_state->{read_buffer} : '';

                # Transfer handle ownership safely
                $stream->set_is_upgraded(1);
                return Libp2p::Protocol::Noise::SecureStream->new(
                    handle         => $stream->handle,
                    loop           => $host->io_utils->loop,
                    c_send         => $c_send,
                    c_recv         => $c_recv,
                    initial_buffer => $existing
                );
            }
        );
    }

    method _create_handshake_payload () {
        my $my_static = $host->crypto->static_x25519_pub_raw();
        my $payload   = Libp2p::Protocol::Noise::HandshakePayload->new();
        $payload->set_identityKey( $host->crypto->public_key_raw() );
        $payload->set_identitySig( $host->crypto->sign( 'noise-libp2p-static-key:' . $my_static ) );
        return $payload->to_pb();
    }

    method _verify_payload ( $bin, $noise ) {
        my $payload = Libp2p::Protocol::Noise::HandshakePayload->from_pb($bin);

        # rs is the Remote Static key from the Noise state
        my $rs_obj        = $noise->handshake_state->rs;
        my $remote_static = $rs_obj->export_key_raw('public');

        # Construct the exact 56-byte buffer:
        # "noise-libp2p-static-key:" (24 bytes) + Remote Static Key (32 bytes)
        my $to_verify = pack( "a24a32", 'noise-libp2p-static-key:', $remote_static );
        return $host->crypto->verify( $to_verify, $payload->identitySig, $payload->identityKey ) ? Libp2p::Future->resolve() :
            Libp2p::Future->reject("Noise Identity verification failed");
    }
};
#
1;
