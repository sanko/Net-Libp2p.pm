use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Protocol::Noise::SecureStream v0.0.1 : isa(Noise::Stream) {
    use Scalar::Util qw[weaken refaddr];
    use Errno qw[EAGAIN EWOULDBLOCK];
    #
    field $loop : param : reader;
    field $read_buffer = '';
    field @on_data_callbacks;
    field @on_close_callbacks;
    #
    ADJUST {
        weaken( my $weak_self = $self );
        $loop->add_read_handler( $self->socket, sub { $weak_self->_on_read_ready() if $weak_self } );
    }

    method syswrite ($data) {

        # Encrypt data using Noise CipherState
        my $cipher = $self->c_send->encrypt_with_ad( '', $data );

        # Prefix with 2-byte length (standard libp2p noise framing)
        my $packet = pack( 'n', length($cipher) ) . $cipher;
        return syswrite( $self->socket, $packet );
    }

    method sysread ( $bufref, $len ) {

        # This is tricky because we need to read full noise packets
        # For now, return what we have in decrypted buffer
        if ( length($read_buffer) > 0 ) {
            my $chunk = substr( $read_buffer, 0, $len, '' );
            $$bufref = $chunk;
            return length($chunk);
        }
        $! = EAGAIN;
        return undef;
    }

    method _on_read_ready () {
        my $header = '';
        my $read   = sysread( $self->socket, $header, 2 );
        if ( defined $read && $read == 2 ) {
            my $packet_len   = unpack 'n', $header;
            my $cipher       = '';
            my $payload_read = sysread( $self->socket, $cipher, $packet_len );
            if ( defined $payload_read && $payload_read == $packet_len ) {
                my $plain = $self->c_recv->decrypt_with_ad( '', $cipher );
                $read_buffer .= $plain;
                $self->_trigger_data();
            }
        }
        elsif ( defined $read && $read == 0 ) {
            $self->close();
        }
    }

    method _trigger_data () {

        # In a real impl, we'd have a higher-level Stream object wrapping this
    }
    method on_close ($cb) { push @on_close_callbacks, $cb; return $self }

    method close () {
        $loop->remove_read_handler( $self->socket );
        close( $self->socket );
        $_->() for @on_close_callbacks;
        @on_close_callbacks = ();
    }
};
#
1;
