use v5.42;
use feature 'class';
no warnings 'experimental::class';
use warnings::register;
#
class Libp2p::Stream v0.2.0 {
    use Libp2p::Utils qw[decode_varint encode_varint];
    use Libp2p::Future;
    use Libp2p::Loop;
    use Errno        qw[EAGAIN EWOULDBLOCK];
    use Scalar::Util qw[weaken refaddr];
    #
    field $handle : param : reader;
    field $handle_id = refaddr $handle;
    field $loop     : param  : reader;
    field $peer_id  : param  : writer : reader //= undef;
    field $protocol : reader : writer = undef;
    field @on_close_callbacks;

    # Static shared state mapping handle refaddr to state
    my %STREAM_STATE;
    my %ALL_STREAMS;    # handle_id -> weak_stream_obj
    ADJUST {
        $STREAM_STATE{$handle_id} = { read_buffer => '', pending_reads => [] };
        weaken( my $weak_self = $self );
        $ALL_STREAMS{$handle_id} = $weak_self;
        $loop->add_read_handler(
            $handle,
            sub ($h) {
                $weak_self->_on_read_ready() if $weak_self;
            }
        );
    }

    sub all_streams ($class) {    # Clean up dead weakrefs while we're here
        for my $id ( keys %ALL_STREAMS ) {
            delete $ALL_STREAMS{$id} unless defined $ALL_STREAMS{$id};
        }
        values %ALL_STREAMS;
    }
    method _state () { $STREAM_STATE{$handle_id} }

    method write ($data) {
        my $f    = Libp2p::Future->new;
        my $sent = blessed($handle) ? $handle->syswrite($data) : syswrite $handle, $data;
        if ( defined $sent ) {
            $loop->poll(0);
            $f->done($sent);
        }
        else {
            if ( $! == EAGAIN || $! == EWOULDBLOCK ) {
                $f->fail('EAGAIN on write');
            }
            else {
                $f->fail($!);
            }
        }
        $f;
    }

    method write_msg ($data) {
        my $payload = $data . "\n";
        $self->write( encode_varint( length($payload) ) . $payload );
    }

    method read_msg () {
        my $f     = Libp2p::Future->new;
        my $state = $self->_state;
        return $f->fail('Stream closed') unless $state;
        push $state->{pending_reads}->@*, { future => $f, type => 'msg' };
        $self->_process_pending_reads();
        $f;
    }
    method write_bin ($data) { $self->write( pack( 'n', length($data) ) . $data ) }

    method read_bin () {
        my $f     = Libp2p::Future->new;
        my $state = $self->_state;
        return $f->fail('Stream closed') unless $state;
        push $state->{pending_reads}->@*, { future => $f, type => 'bin' };
        $self->_process_pending_reads();
        $f;
    }

    method read_bin_fixed ($len) {
        my $f     = Libp2p::Future->new;
        my $state = $self->_state;
        return $f->fail('Stream closed') unless $state;
        push $state->{pending_reads}->@*, { future => $f, type => 'fixed', len => $len };
        $self->_process_pending_reads();
        $f;
    }

    method trigger_read_check () {
        $self->_on_read_ready();
        $self->_process_pending_reads();
    }

    method _on_read_ready () {
        my $buf  = '';
        my $read = blessed($handle) ? $handle->sysread( $buf, 65536 ) : sysread( $handle, $buf, 65536 );
        if ( defined $read && $read > 0 ) {
            my $state = $self->_state;
            return unless $state;
            $state->{read_buffer} .= $buf;
            #~ warnings::warnif  sprintf '[Stream] handle %s READ %d bytes, buffer_len now %d', ( $handle // 'undef' ), $read, length $state->{read_buffer};
            $self->_process_pending_reads();
        }
        elsif ( defined $read && $read == 0 ) {
            $loop->remove_read_handler($handle);
            my $state = $self->_state;
            if ($state) {
                $_->{future}->fail('EOF') for $state->{pending_reads}->@*;
                $state->{pending_reads} = [];
            }
        }
        elsif ( !defined $read && !( $! == EAGAIN || $! == EWOULDBLOCK ) ) {
            $loop->remove_read_handler($handle);
            my $state = $self->_state;
            if ($state) {
                $_->{future}->fail($!) for $state->{pending_reads}->@*;
                $state->{pending_reads} = [];
            }
        }
    }

    method _process_pending_reads () {
        my $state = $self->_state or return;
        while ( $state->{pending_reads}->@* ) {
            my $pr = $state->{pending_reads}[0];
            if ( $pr->{type} eq 'msg' ) {
                my ( $len, $vlen ) = decode_varint( $state->{read_buffer} );
                if ( defined $len && length( $state->{read_buffer} ) >= $vlen + $len ) {
                    shift $state->{pending_reads}->@*;
                    substr $state->{read_buffer}, 0, $vlen, '';
                    my $msg = substr $state->{read_buffer}, 0, $len, '';
                    $msg =~ s/\n$//;
                    #~ warnings::warnif sprintf '[Stream] handle %s DONE msg=[%s]', ( $handle // 'undef' ), $msg;
                    $pr->{future}->done($msg);
                }
                else {
                    last;
                }
            }
            elsif ( $pr->{type} eq 'bin' ) {
                if ( length( $state->{read_buffer} ) >= 2 ) {
                    my $len = unpack 'n', substr $state->{read_buffer}, 0, 2;
                    if ( length( $state->{read_buffer} ) >= 2 + $len ) {
                        shift $state->{pending_reads}->@*;
                        substr $state->{read_buffer}, 0, 2, '';
                        my $data = substr $state->{read_buffer}, 0, $len, '';
                        $pr->{future}->done($data);
                    }
                    else { last; }
                }
                else { last; }
            }
            elsif ( $pr->{type} eq 'fixed' ) {
                if ( length( $state->{read_buffer} ) >= $pr->{len} ) {
                    shift $state->{pending_reads}->@*;
                    my $data = substr $state->{read_buffer}, 0, $pr->{len}, '';
                    $pr->{future}->done($data);
                }
                else { last; }
            }
        }
    }

    method negotiate ($protocol) {
        my $f = $self->write_msg('/multistream/1.0.0')->then(
            sub {
                return $self->read_msg();
            }
        )->then(
            sub ($ack) {
                return $self->write_msg($protocol);
            }
        )->then(
            sub {
                return $self->read_msg();
            }
        )->then(
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

    method on_close ($cb) {
        push @on_close_callbacks, $cb;
        $self;
    }

    method close () {
        if ($handle) {
            $loop->remove_read_handler($handle);
            close($handle);
        }
        delete $STREAM_STATE{$handle_id};
        delete $ALL_STREAMS{$handle_id};
        my @cbs = @on_close_callbacks;
        @on_close_callbacks = ();
        $_->() for @cbs;
    }

    method DESTROY () {
        #~ warnings::warnif '[Stream] DESTROY handle ' . ( $handle // 'undef' );
        if ( $loop && $handle ) {
            try { $loop->remove_read_handler($handle); } catch ($e) {
            }
        }
        delete $STREAM_STATE{$handle_id};
        delete $ALL_STREAMS{$handle_id};
    }
} 1;
