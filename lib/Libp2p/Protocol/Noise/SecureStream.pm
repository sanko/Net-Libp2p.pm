use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Protocol::Noise::SecureStream v0.0.1 : isa(Noise::Stream) {
    use Scalar::Util qw[weaken refaddr];
    use Errno qw[EAGAIN EWOULDBLOCK];
    #
    field $loop : param : reader;
    field $raw_read_buffer = '';
    field $read_buffer = '';
    field @on_data_callbacks;
    field @on_close_callbacks;
    #
    ADJUST {
        weaken( my $weak_self = $self );
        $loop->add_read_handler( $self->socket, sub { $weak_self->_on_read_ready() if $weak_self } );
    }

    method syswrite ($data) {
        my $cipher = $self->c_send->encrypt_with_ad( '', $data );
        my $packet = pack( 'n', length($cipher) ) . $cipher;
        return syswrite( $self->socket, $packet );
    }

    method sysread ( $bufref, $len ) {
        if ( length($read_buffer) > 0 ) {
            my $chunk = substr( $read_buffer, 0, $len, '' );
            $$bufref = $chunk;
            return length($chunk);
        }
        $! = EAGAIN;
        return undef;
    }

    method _on_read_ready () {
        my $buf = '';
        my $read = sysread( $self->socket, $buf, 65536 );

        if ( defined $read && $read > 0 ) {
            $raw_read_buffer .= $buf;

            # Extract and decrypt as many complete noise packets as possible
            while ( length($raw_read_buffer) >= 2 ) {
                my $packet_len = unpack('n', substr($raw_read_buffer, 0, 2));

                if ( length($raw_read_buffer) >= 2 + $packet_len ) {
                    substr($raw_read_buffer, 0, 2, ''); # Remove length prefix
                    my $cipher = substr($raw_read_buffer, 0, $packet_len, ''); # Extract payload

                    my $plain = $self->c_recv->decrypt_with_ad( '', $cipher );
                    $read_buffer .= $plain;
                } else {
                    last; # Wait for the rest of the packet to arrive over TCP
                }
            }
            $self->_trigger_data() if length($read_buffer) > 0;
        }
        elsif ( defined $read && $read == 0 ) {
            $self->close();
        }
        elsif ( !defined $read && !( $! == EAGAIN || $! == EWOULDBLOCK ) ) {
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
