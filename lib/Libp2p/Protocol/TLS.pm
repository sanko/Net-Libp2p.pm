use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Protocol::TLS::ASN1 v0.0.1 {
    method encode_octet_string ($data) {
        pack( 'C', 0x04 ) . $self->_encode_length( length($data) ) . $data;
    }

    method encode_sequence (@parts) {
        my $data = join( '', @parts );
        pack( 'C', 0x30 ) . $self->_encode_length( length($data) ) . $data;
    }

    method _encode_length ($len) {
        return pack( 'C', $len ) if $len < 128;
        my $bin = '';
        while ( $len > 0 ) {
            $bin = pack( 'C', $len & 0xff ) . $bin;
            $len >>= 8;
        }
        pack( 'C', 0x80 | length($bin) ) . $bin;
    }
};
class Libp2p::Protocol::TLS::SecureStream v0.0.1 : isa(Libp2p::Stream) {
    use Scalar::Util qw[blessed];
    use Errno qw[EAGAIN EWOULDBLOCK];
    field $initial_buffer : param //= '';
    ADJUST {
        # If we had bytes left over from multistream,
        # we manually inject them into the parent stream's buffer.
        if ($initial_buffer) {
            $self->_state->{read_buffer} = $initial_buffer;
            $self->_process_pending_reads();
        }
    }

    # TLS does NOT use length prefixes. We just use syswrite on the SSL handle.
    method syswrite ($data) {
        my $h = $self->handle;

        # IO::Socket::SSL overrides syswrite to encrypt automatically
        return blessed($h) ? $h->syswrite($data) : syswrite( $h, $data );
    }

    # Use standard sysread. IO::Socket::SSL overrides this to decrypt.
    method _on_read_ready () {
        my $buf = '';
        my $h   = $self->handle;

        # IO::Socket::SSL sysread handles the TLS record decryption
        my $read = blessed($h) ? $h->sysread( $buf, 65536 ) : sysread( $h, $buf, 65536 );
        if ( defined $read && $read > 0 ) {
            $self->_state->{read_buffer} .= $buf;
            $self->_process_pending_reads();
        }
        elsif ( defined $read && $read == 0 ) {
            $self->close();
        }
        elsif ( !defined $read && !( $! == EAGAIN || $! == EWOULDBLOCK ) ) {

            # In SSL, EAGAIN might actually be a WANT_READ/WANT_WRITE,
            # but IO::Socket::SSL's sysread usually maps these to EAGAIN for us.
            $self->close();
        }
    }
} class Libp2p::Protocol::TLS v0.0.1 {
    use Libp2p::Future;
    use IO::Socket::SSL;
    use Net::SSLeay;
    use File::Temp qw[tempfile];
    use constant { PROTOCOL_ID => '/tls/1.0.0', LIBP2P_OID => '1.3.6.1.4.1.53594.1.1' };
    field $host : param;

    method register () {
        $host->set_handler( PROTOCOL_ID, sub { $self->handle_stream( $_[0] ) } );
    }

    method handle_stream ($stream) {
        return $self->_upgrade_to_tls( $stream, 1 );
    }

    method initiate_handshake ($stream) {
        return $self->_upgrade_to_tls( $stream, 0 );
    }

    method _upgrade_to_tls ( $stream, $is_server ) {
        my $f          = Libp2p::Future->new;
        my $raw_handle = $stream->handle;
        my $loop       = $host->io_utils->loop;

        # Protect socket handle from being closed when old stream goes out of scope
        my $initial_data = $stream->can('_state') && $stream->_state ? $stream->_state->{read_buffer} // '' : '';
        $stream->set_is_upgraded(1);

        # Generate ephemeral libp2p certificate
        my ( $cert_path, $key_path ) = $self->_generate_ephemeral_cert();
        $loop->remove_read_handler($raw_handle);
        my %ssl_args = (
            SSL_startHandshake => 0,                 # Force non-blocking handshake routine
            SSL_server         => $is_server,
            SSL_version        => 'TLSv13',
            SSL_alpn_protocols => ['libp2p'],
            SSL_cert_file      => $cert_path,
            SSL_key_file       => $key_path,
            SSL_verify_mode    => SSL_VERIFY_NONE,
        );
        $ssl_args{SSL_hostname} = 'libp2p' unless $is_server;
        my $ssl_socket = IO::Socket::SSL->start_SSL( $raw_handle, %ssl_args );
        unless ($ssl_socket) {
            unlink $cert_path, $key_path;
            return $f->fail("TLS Start Failed: $IO::Socket::SSL::SSL_ERROR");
        }
        $self->_drive_handshake( $ssl_socket, $is_server, $f, $cert_path, $key_path, $initial_data );
        return $f;
    }

    method _drive_handshake ( $ssl, $is_server, $f, $cpath, $kpath, $initial_data ) {
        my $loop = $host->io_utils->loop;
        my $res  = $is_server ? $ssl->accept_SSL : $ssl->connect_SSL;
        if ($res) {
            unlink $cpath, $kpath if $cpath;

            # Clear handshake IO handlers
            $loop->remove_read_handler($ssl);
            $loop->remove_write_handler($ssl);
            my $secure_stream = Libp2p::Protocol::TLS::SecureStream->new( handle => $ssl, loop => $loop, initial_buffer => $initial_data );
            $f->done($secure_stream);
            return;
        }
        if ( $IO::Socket::SSL::SSL_ERROR == SSL_WANT_READ ) {
            $loop->add_read_handler(
                $ssl,
                sub {
                    $loop->remove_read_handler($ssl);
                    $self->_drive_handshake( $ssl, $is_server, $f, $cpath, $kpath, $initial_data );
                }
            );
        }
        elsif ( $IO::Socket::SSL::SSL_ERROR == SSL_WANT_WRITE ) {
            $loop->add_write_handler(
                $ssl,
                sub {
                    $loop->remove_write_handler($ssl);
                    $self->_drive_handshake( $ssl, $is_server, $f, $cpath, $kpath, $initial_data );
                }
            );
        }
        else {
            unlink $cpath, $kpath if $cpath;
            $f->fail("TLS Handshake Error: $IO::Socket::SSL::SSL_ERROR / $!");
        }
    }

    method _generate_ephemeral_cert () {

        # Create a temporary key and config
        my ( $kfh,  $key_path )  = tempfile( SUFFIX => '.key', UNLINK => 0 );
        my ( $cfh,  $conf_path ) = tempfile( SUFFIX => '.cnf', UNLINK => 1 );
        my ( $cfh2, $cert_path ) = tempfile( SUFFIX => '.crt', UNLINK => 0 );
        close $cfh2;

        # Use Crypt::PK::Ed25519 to generate the ephemeral TLS key (NOT your identity key)
        use Crypt::PK::Ed25519;
        my $pk = Crypt::PK::Ed25519->new()->generate_key();
        print $kfh $pk->export_key_pem('private');
        close $kfh;
        my $spki_der = $pk->export_key_der('public_x509');

        # Create the libp2p extension: ASN.1 Sequence [PublicKey, Signature]
        my $asn1     = Libp2p::Protocol::TLS::ASN1->new;
        my $payload  = 'libp2p-tls-handshake:' . $spki_der;
        my $sig      = $host->crypto->sign($payload);
        my $ext_data = $asn1->encode_sequence( $asn1->encode_octet_string( $host->crypto->public_key_raw() ), $asn1->encode_octet_string($sig) );
        my $ext_hex  = unpack( 'H*', $ext_data );
        print $cfh "distinguished_name=dn\n[dn]\nCN=libp2p\n[ext]\n" . LIBP2P_OID . "=DER:$ext_hex\n";
        close $cfh;

        # Cross-platform null redirect
        my $devnull = $^O eq 'MSWin32' ? 'NUL' : '/dev/null';

        # Generate cert via openssl CLI
        my $cmd
            = qq[openssl req -x509 -new -key "$key_path" -out "$cert_path" -days 1 -subj "/CN=libp2p" -extensions ext -config "$conf_path" 2>$devnull];
        system($cmd);
        return ( $cert_path, $key_path );
    }
} 1;
