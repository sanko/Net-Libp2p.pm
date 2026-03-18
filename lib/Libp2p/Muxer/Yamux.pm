use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Muxer::Yamux::Stream v0.0.1 {
    use Libp2p::Future;
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Scalar::Util  qw[weaken];
    field $session   : param;
    field $stream_id : param  : reader;
    field $protocol  : reader : writer = undef;
    field $peer_id   : reader : writer = undef;
    field $state       = 'INIT';
    field $send_window = 256 * 1024;
    field $recv_window = 256 * 1024;
    field $read_buffer = '';
    field @pending_reads;
    field @on_close_callbacks;
    ADJUST { weaken($session) }

    method write ($data) {
        my $f     = Libp2p::Future->new;
        my $flags = 0;
        if ( $state eq 'INIT' ) {
            $flags = Libp2p::Muxer::Yamux::FLAG_SYN();
            $state = 'OPEN';
        }

        # Return the length of the plaintext sent
        $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_DATA(), $flags, $stream_id, $data )
            ->then( sub { $f->done( length($data) ) } )
            ->catch( sub { $f->fail( $_[0] ) } );
        return $f;
    }

    method _receive_data ($data) {
        $read_buffer .= $data;
        $recv_window -= length($data);
        if ( $recv_window < 128 * 1024 ) {
            my $delta = ( 256 * 1024 ) - $recv_window;
            $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_WIN_UPDATE(), 0, $stream_id, '', $delta );
            $recv_window += $delta;
        }
        $self->_process_pending_reads();
    }
    method _receive_window_update ($delta) { $send_window += $delta }

    method _receive_close () {
        if   ( $state eq 'OPEN' || $state eq 'INIT' ) { $state = 'REMOTE_CLOSE' }
        else                                          { $state = 'CLOSED' }
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

    method write_pb ($data) {
        $self->write( encode_varint( length($data) ) . $data );
    }

    method read_pb () {
        my $f = Libp2p::Future->new;
        return $f->fail('Stream closed') if $state eq 'CLOSED';
        push @pending_reads, { future => $f, type => 'pb' };
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
            elsif ( $pr->{type} eq 'pb' ) {
                my ( $len, $vlen ) = decode_varint($read_buffer);
                if ( defined $len && length($read_buffer) >= $vlen + $len ) {
                    shift @pending_reads;
                    substr $read_buffer, 0, $vlen, '';
                    my $data = substr $read_buffer, 0, $len, '';
                    $pr->{future}->done($data);
                }
                else { last; }
            }
        }
    }

    method negotiate ($protocol) {
        return $self->write_msg('/multistream/1.0.0')
            ->then( sub { return $self->read_msg(); } )
            ->then( sub { return $self->write_msg($protocol); } )
            ->then( sub { return $self->read_msg(); } )
            ->then(
            sub ($ack) {
                if ( $ack eq $protocol ) {
                    $self->set_protocol($protocol);
                    return Libp2p::Future->resolve(1);
                }
                return Libp2p::Future->reject("Negotiation failed: $ack");
            }
            );
    }

    method close () {
        return if $state eq 'CLOSED';
        $session->_send_frame( Libp2p::Muxer::Yamux::TYPE_DATA(), Libp2p::Muxer::Yamux::FLAG_FIN(), $stream_id, '' );
        if ( $state eq 'REMOTE_CLOSE' ) {
            $state = 'CLOSED';
            $session->_remove_stream($stream_id);
            $self->_trigger_close_cbs();
        }
        else {
            $state = 'LOCAL_CLOSE';
        }
    }
    method on_close ($cb)        { push @on_close_callbacks, $cb;  return $self }
    method _trigger_close_cbs () { $_->() for @on_close_callbacks; @on_close_callbacks = () }
};
#
class Libp2p::Muxer::Yamux v0.0.1 {
    use Libp2p::Future;
    use constant { TYPE_DATA => 0, TYPE_WIN_UPDATE => 1, TYPE_PING => 2, TYPE_GO_AWAY => 3 };
    use constant { FLAG_SYN  => 1, FLAG_ACK        => 2, FLAG_FIN  => 4, FLAG_RST     => 8 };
    field $connection : param //= undef;
    field $is_client  : param //= 1;
    field $on_stream  : param //= undef;
    field $next_stream_id = $is_client ? 1 : 2;
    field %streams;
    field $is_closed = 0;
    method start () { $self->_read_loop() if $connection }

    method open_stream () {
        my $sid = $next_stream_id;
        $next_stream_id += 2;
        my $s = Libp2p::Muxer::Yamux::Stream->new( session => $self, stream_id => $sid );
        $streams{$sid} = $s;
        return $s;
    }
    method _remove_stream ($sid) { delete $streams{$sid} }

    method _read_loop () {
        return if $is_closed || !$connection;
        $connection->read_bin_fixed(12)->then(
            sub ($hdr_bin) {
                my $hdr = $self->parse_header($hdr_bin);
                return Libp2p::Future->resolve() unless $hdr;
                if ( $hdr->{type} == TYPE_DATA && $hdr->{length} > 0 ) {
                    return $connection->read_bin_fixed( $hdr->{length} )->then(
                        sub ($payload) {
                            $self->_handle_frame( $hdr, $payload );
                        }
                    );
                }
                $self->_handle_frame( $hdr, '' );
                return Libp2p::Future->resolve();
            }
        )->then( sub { $self->_read_loop() unless $is_closed } )->catch( sub ($err) { $self->close_all($err) } );
    }

    method _handle_frame ( $hdr, $payload ) {
        my $sid = $hdr->{sid};
        if ( $sid == 0 ) {
            if ( $hdr->{type} == TYPE_PING && ( $hdr->{flags} & FLAG_SYN ) ) {
                $self->_send_frame( TYPE_PING, FLAG_ACK, 0, '', $hdr->{length} );
            }
            elsif ( $hdr->{type} == TYPE_GO_AWAY ) {
                $self->close_all("GoAway");
            }
            return;
        }
        if ( ( $hdr->{flags} & FLAG_SYN ) && !exists $streams{$sid} ) {
            my $s = Libp2p::Muxer::Yamux::Stream->new( session => $self, stream_id => $sid );
            $streams{$sid} = $s;
            $on_stream->($s) if $on_stream;
            $self->_send_frame( TYPE_WIN_UPDATE, FLAG_ACK, $sid, '', 0 );
        }
        my $s = $streams{$sid} or return;
        if    ( $hdr->{type} == TYPE_DATA )       { $s->_receive_data($payload) if length($payload) > 0 }
        elsif ( $hdr->{type} == TYPE_WIN_UPDATE ) { $s->_receive_window_update( $hdr->{length} ) }
        $s->_receive_close() if $hdr->{flags} & FLAG_FIN;
        if ( $hdr->{flags} & FLAG_RST ) { $s->_receive_close(); delete $streams{$sid} }
    }
    method build_header ( $t, $f, $sid, $l, $v //= 0 ) { pack 'CCnNN', $v, $t, $f, $sid, $l }

    method parse_header ($b) {
        return undef unless length($b) == 12;
        my ( $v, $t, $f, $sid, $l ) = unpack 'CCnNN', $b;
        { version => $v, type => $t, flags => $f, sid => $sid, length => $l };
    }

    method _send_frame ( $t, $f, $sid, $p //= '', $lo //= undef ) {
        return Libp2p::Future->reject('NC') unless $connection;
        my $hdr = $self->build_header( $t, $f, $sid, defined $lo ? $lo : length($p) );
        return $connection->write( $hdr . $p );
    }

    method close_all ( $reason //= 'Closed' ) {
        return if $is_closed;
        $is_closed = 1;
        try { $self->_send_frame( TYPE_GO_AWAY, 0, 0, '', 0 ) } catch ($e) {
        }
        $_->_receive_close() for values %streams;
        %streams = ();
        $connection->close() if $connection;
    }
} 1;
