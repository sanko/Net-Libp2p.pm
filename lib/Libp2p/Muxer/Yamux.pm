use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Muxer::Yamux::Stream v0.0.1 {
    use Libp2p::Future;
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Scalar::Util  qw[weaken];
    field $session   : param;           # Weak ref to Yamux session
    field $stream_id : param  : reader;
    field $protocol  : reader : writer //= undef;
    field $peer_id   : reader : writer //= undef;
    field $state       = 'INIT';        # INIT, OPEN, LOCAL_CLOSE, REMOTE_CLOSE, CLOSED
    field $send_window = 256 * 1024;    # 256KB default
    field $recv_window = 256 * 1024;
    field $read_buffer = '';
    field @pending_reads;
    field @on_close_callbacks;
    ADJUST { weaken($session) }

    method write ($data) {
        my $f = Libp2p::Future->new;
        return $f->fail('Stream closed') if $state eq 'CLOSED' || $state eq 'LOCAL_CLOSE';

        # Basic chunking if data exceeds window or max frame size
        # A full spec implementation tracks window updates, but for v1
        # we will write it immediately through the session.
        my $flags = 0;
        if ( $state eq 'INIT' ) {
            $flags = Libp2p::Muxer::Yamux::FLAG_SYN();
            $state = 'OPEN';
        }

        # Max frame size in Yamux is typically 64KB, but Yamux session can handle it.
        $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_DATA(), $flags, $stream_id, $data )
            ->then( sub { $f->done( length($data) ) } )
            ->catch( sub ($err) { $f->fail($err) } );
        return $f;
    }

    method _receive_data ($data) {
        $read_buffer .= $data;
        $recv_window -= length($data);

        # Emit Window Update if our window gets low (half of 256KB)
        if ( $recv_window < 128 * 1024 ) {
            my $delta = ( 256 * 1024 ) - $recv_window;
            $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_WIN_UPDATE(), 0, $stream_id, '', $delta );
            $recv_window += $delta;
        }
        $self->_process_pending_reads();
    }

    method _receive_window_update ($delta) {
        $send_window += $delta;
    }

    method _receive_close () {
        if ( $state eq 'OPEN' || $state eq 'INIT' ) {
            $state = 'REMOTE_CLOSE';
        }
        else {
            $state = 'CLOSED';
        }
        $_->{future}->fail('EOF') for @pending_reads;
        @pending_reads = ();
        $self->_trigger_close_cbs() if $state eq 'CLOSED';
    }

    method write_msg ($data) {
        my $payload = $data . "\n";
        $self->write( encode_varint( length($payload) ) . $payload );
    }

    method read_msg () {
        my $f = Libp2p::Future->new;
        return $f->fail('Stream closed') if $state eq 'CLOSED';
        push @pending_reads, { future => $f, type => 'msg' };
        $self->_process_pending_reads();
        return $f;
    }
    method write_bin ($data) { $self->write( pack( 'n', length($data) ) . $data ) }

    method read_bin () {
        my $f = Libp2p::Future->new;
        return $f->fail('Stream closed') if $state eq 'CLOSED';
        push @pending_reads, { future => $f, type => 'bin' };
        $self->_process_pending_reads();
        return $f;
    }

    method _process_pending_reads () {
        while (@pending_reads) {
            my $pr = $pending_reads[0];
            if ( $pr->{type} eq 'msg' ) {
                my ( $len, $vlen ) = decode_varint($read_buffer);
                if ( defined $len && length($read_buffer) >= $vlen + $len ) {
                    shift @pending_reads;
                    substr $read_buffer, 0, $vlen, '';
                    my $msg = substr $read_buffer, 0, $len, '';
                    $msg =~ s/\n$//;
                    $pr->{future}->done($msg);
                }
                else { last; }
            }
            elsif ( $pr->{type} eq 'bin' ) {
                if ( length($read_buffer) >= 2 ) {
                    my $len = unpack 'n', substr $read_buffer, 0, 2;
                    if ( length($read_buffer) >= 2 + $len ) {
                        shift @pending_reads;
                        substr $read_buffer, 0, 2, '';
                        my $data = substr $read_buffer, 0, $len, '';
                        $pr->{future}->done($data);
                    }
                    else { last; }
                }
                else { last; }
            }
        }
    }

    method negotiate ($protocol) {

        # Exactly the same multistream-select handshake logic from Stream.pm,
        # but riding over this virtual Yamux stream instead.
        my $f
            = $self->write_msg('/multistream/1.0.0')
            ->then( sub { return $self->read_msg(); } )
            ->then( sub ($ack) { return $self->write_msg($protocol); } )
            ->then( sub { return $self->read_msg(); } )
            ->then(
            sub ($p_ack) {
                if ( $p_ack eq $protocol ) {
                    $self->set_protocol($protocol);
                    return Libp2p::Future->new->done(1);
                }
                else {
                    return Libp2p::Future->new->fail( 'Negotiation failed: ' . $p_ack );
                }
            }
            );
        return $f;
    }

    method close () {
        return if $state eq 'CLOSED';
        if ( $state eq 'OPEN' || $state eq 'INIT' ) {
            $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_DATA(), Libp2p::Muxer::Yamux::FLAG_FIN(), $stream_id, '' );
            $state = 'LOCAL_CLOSE';
        }
        elsif ( $state eq 'REMOTE_CLOSE' ) {
            $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_DATA(), Libp2p::Muxer::Yamux::FLAG_FIN(), $stream_id, '' );
            $state = 'CLOSED';
            $session->_remove_stream($stream_id);
            $self->_trigger_close_cbs();
        }
    }

    method on_close ($cb) {
        push @on_close_callbacks, $cb;
        return $self;
    }

    method _trigger_close_cbs () {
        $_->() for @on_close_callbacks;
        @on_close_callbacks = ();
    }
} class Libp2p::Muxer::Yamux v0.0.1 {
    use Libp2p::Future;

    # Types
    use constant TYPE_DATA       => 0;
    use constant TYPE_WIN_UPDATE => 1;
    use constant TYPE_PING       => 2;
    use constant TYPE_GO_AWAY    => 3;

    # Flags
    use constant FLAG_SYN => 1;
    use constant FLAG_ACK => 2;
    use constant FLAG_FIN => 4;
    use constant FLAG_RST => 8;
    field $connection : param //= undef;    # The underlying SecureStream (Noise/TLS)
    field $is_client  : param //= 1;        # 1 = client (odd IDs), 0 = server (even IDs)
    field $on_stream  : param //= undef;    # Callback for incoming streams
    field $next_stream_id = $is_client ? 1 : 2;
    field %streams;                         # Active Yamux::Stream objects
    field $is_closed = 0;

    method start () {
        $connection // return;
        say "[NETWORK] [Yamux] Starting multiplexer session..." if $ENV{DEBUG};
        $self->_read_loop();
    }

    method open_stream () {
        my $sid = $next_stream_id;
        $next_stream_id += 2;
        my $stream = Libp2p::Muxer::Yamux::Stream->new( session => $self, stream_id => $sid );
        $streams{$sid} = $stream;
        return $stream;
    }
    method _remove_stream ($sid) { delete $streams{$sid} }

    method _read_loop () {
        return if $is_closed || !$connection;

        # Because Futures unroll the stack in Libp2p::Loop via next_tick,
        # this recursive loop pattern is safe from stack overflow!
        $connection->read_bin_fixed(12)->then(
            sub ($hdr_bin) {
                my $hdr = $self->parse_header($hdr_bin);
                return Libp2p::Future->resolve() unless $hdr;    # Ignore bad headers
                if ( $hdr->{type} == TYPE_DATA && $hdr->{length} > 0 ) {

                    # Read payload
                    return $connection->read_bin_fixed( $hdr->{length} )->then(
                        sub ($payload) {
                            $self->_handle_frame( $hdr, $payload );
                            return;
                        }
                    );
                }
                else {
                    # Frame with no payload (Window Update, Ping, GoAway, or empty FIN)
                    $self->_handle_frame( $hdr, '' );
                    return Libp2p::Future->resolve();
                }
            }
        )->then(
            sub {
                $self->_read_loop() unless $is_closed;
            }
        )->catch(
            sub ($err) {
                say "[NETWORK] [Yamux] Session closed: $err" if $ENV{DEBUG};
                $self->close_all($err);
            }
        );
    }

    method _handle_frame ( $hdr, $payload ) {
        my $sid = $hdr->{sid};

        # 0 is the session control channel (Ping, GoAway)
        if ( $sid == 0 ) {
            if ( $hdr->{type} == TYPE_PING ) {
                if ( $hdr->{flags} & FLAG_SYN ) {

                    # Reply to ping
                    $self->_send_frame( TYPE_PING, FLAG_ACK, 0, '', $hdr->{length} );
                }
            }
            elsif ( $hdr->{type} == TYPE_GO_AWAY ) {
                $self->close_all("Received GoAway");
            }
            return;
        }

        # Handle Stream SYN (Remote opened a stream)
        if ( $hdr->{flags} & FLAG_SYN ) {
            unless ( exists $streams{$sid} ) {
                say '[NETWORK] [Yamux] Received SYN for new stream ' . $sid if $ENV{DEBUG};
                my $stream = Libp2p::Muxer::Yamux::Stream->new( session => $self, stream_id => $sid );
                $streams{$sid} = $stream;

                # Notify Host via callback
                if ($on_stream) {
                    try { $on_stream->($stream) } catch ($e) {
                        warn 'Yamux on_stream error: ' . $e
                    }
                }

                # Send ACK back
                $self->_send_frame( TYPE_WIN_UPDATE, FLAG_ACK, $sid, '', 0 );
            }
        }
        my $stream = $streams{$sid};
        return unless $stream;    # Ignore frames for unknown/closed streams

        # Dispatch Frame
        if ( $hdr->{type} == TYPE_DATA ) {
            $stream->_receive_data($payload) if length($payload) > 0;
        }
        elsif ( $hdr->{type} == TYPE_WIN_UPDATE ) {
            $stream->_receive_window_update( $hdr->{length} );
        }

        # Check for teardown flags
        if ( $hdr->{flags} & FLAG_FIN ) {
            $stream->_receive_close();
        }
        if ( $hdr->{flags} & FLAG_RST ) {
            $stream->_receive_close();
            delete $streams{$sid};
        }
    }

    method build_header ( $type, $flags, $sid, $len, $ver //= 0 ) {
        pack 'CCnNN', $ver, $type, $flags, $sid, $len;
    }

    method _send_frame ( $type, $flags, $sid, $payload //= '', $len_override //= undef ) {
        return Libp2p::Future->reject('Not connected') unless $connection;
        my $len = defined $len_override ? $len_override : length($payload);
        my $hdr = $self->build_header( $type, $flags, $sid, $len );
        return $connection->write( $hdr . $payload );
    }

    method parse_header ($bytes) {
        return undef unless length($bytes) == 12;
        my ( $ver, $type, $flags, $sid, $len ) = unpack 'CCnNN', $bytes;
        { version => $ver, type => $type, flags => $flags, sid => $sid, length => $len };
    }

    method close_all ( $reason //= 'Session Closed' ) {
        return if $is_closed;
        $is_closed = 1;

        # Tell remote we are going away gracefully if possible
        try { $self->_send_frame( TYPE_GO_AWAY, 0, 0, '', 0 ) } catch ($e) {
            ;
        }
        for my $sid ( keys %streams ) {
            my $s = $streams{$sid};
            $s->_receive_close() if $s;
        }
        %streams = ();
        $connection->close() if $connection && $connection->can('close');
    }
};
#
1;
