use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Loop v0.1.0 {
    use warnings::register;
    use Libp2p::Future;
    use IO::Select;
    use Time::HiRes qw[time sleep];
    #
    field $read_set  = IO::Select->new();
    field $write_set = IO::Select->new();
    field %handlers;    # fileno -> { read => sub, write => sub }
    field @timers;      # [ time, sub ] sorted
    field @next_tick_queue;
    field $running = 0;
    field $backend;     # 'native', 'parataxis'

    #
    ADJUST {
        warnings::warnif __CLASS__, '[Loop] ADJUST: loop=' . $self;
        my $forced = $ENV{LIBP2P_LOOP_BACKEND};
        if ( $forced && $forced eq 'native' ) {
            $backend = 'native';
        }
        elsif ( $forced && $forced eq 'parataxis' ) {
            require Acme::Parataxis;
            $backend = 'parataxis';
        }
        else {
            $backend = eval { require Acme::Parataxis; 1 } ? 'parataxis' : 'native';
        }
        warnings::warnif __CLASS__, '[Loop] Backend: ' . $backend;
        @next_tick_queue = ();
    }

    method add_read_handler ( $fh, $cb ) {
        my $fn = eval { fileno($fh) };
        return unless defined $fn;
        warnings::warnif __CLASS__, '[Loop] add_read_handler: fileno=' . $fn;
        $read_set->add($fh);
        $handlers{$fn}{read} = $cb;
    }

    method remove_read_handler ($fh) {
        return unless defined $fh;
        $read_set->remove($fh);
        my $fn = eval { fileno($fh) };
        if ( defined $fn ) {
            warnings::warnif __CLASS__, '[Loop] remove_read_handler: fileno=' . $fn;
            delete $handlers{$fn}{read};
            delete $handlers{$fn} unless keys $handlers{$fn}->%*;
        }
    }

    method add_write_handler ( $fh, $cb ) {
        my $fn = eval { fileno($fh) };
        return unless defined $fn;
        warnings::warnif __CLASS__, '[Loop] add_write_handler: fileno=' . $fn;
        $write_set->add($fh);
        $handlers{$fn}{write} = $cb;
    }

    method remove_write_handler ($fh) {
        return unless defined $fh;
        $write_set->remove($fh);
        my $fn = eval { fileno($fh) };
        if ( defined $fn ) {
            warnings::warnif __CLASS__, '[Loop] remove_write_handler: fileno=' . $fn;
            delete $handlers{$fn}{write};
            delete $handlers{$fn} unless keys $handlers{$fn}->%*;
        }
    }

    method timer ( $delay, $cb ) {
        my $t = time() + $delay;
        push @timers, [ $t, $cb ];
        @timers = sort { $a->[0] <=> $b->[0] } @timers;
    }

    method next_tick ($cb) {
        push @next_tick_queue, $cb;
    }

    method run () {
        $running = 1;
        if ( $backend eq 'parataxis' ) {
            Acme::Parataxis::run( sub { $self->_loop_logic() } );
        }
        else {
            $self->_loop_logic();
        }
    }
    method _loop_logic ()          { $self->tick(0.1) while ( $running && ( $read_set->count || $write_set->count || @timers || @next_tick_queue ) ) }
    method stop ()                 { $running //= 0 }
    method poll ( $timeout //= 0 ) { $self->tick($timeout) }

    method force_poll () {

        # Aggressively check all streams manually.
        # This is a last-resort for Windows loopback select flakiness.
        require Libp2p::Stream;
        for my $stream ( Libp2p::Stream->all_streams ) {
            $stream->trigger_read_check();
        }
    }

    method _handle_ready ( $can_read, $can_write ) {
        if ( $can_read && @$can_read ) {
            for my $fh (@$can_read) {
                my $fn = eval { fileno($fh) };
                if ( defined $fn && exists $handlers{$fn} && $handlers{$fn}{read} ) {
                    try { $handlers{$fn}{read}->($fh) }
                    catch ($e) { warnings::warnif __CLASS__, '[Loop] Read handler exception: ' . $e }
                }
            }
        }
        if ( $can_write && @$can_write ) {
            for my $fh (@$can_write) {
                my $fn = eval { fileno($fh) };
                if ( defined $fn && exists $handlers{$fn} && $handlers{$fn}{write} ) {
                    try { $handlers{$fn}{write}->($fh) }
                    catch ($e) { warnings::warnif __CLASS__, '[Loop] Write handler exception: ' . $e }
                }
            }
        }
    }
    method new_future () { Libp2p::Future->new() }

    method wait_all (@futures) {
        my $f     = $self->new_future();
        my $count = scalar @futures;
        return $f->done() if $count == 0;
        my $done_count = 0;
        my @results;
        $results[ $count - 1 ] = undef;    # Pre-allocate array
        for my $i ( 0 .. $count - 1 ) {
            $futures[$i]->then(
                sub (@res) {
                    $results[$i] = \@res;
                    $done_count++;
                    $f->done(@results) if $done_count == $count && !$f->is_ready;
                    return;    # Prevent implicit Future return chain loop
                },
                sub ($err) {
                    $f->fail($err) if !$f->is_ready;
                    return;    # Prevent implicit Future return chain loop
                }
            );
        }
        $f;
    }

    method tick ( $timeout //= 0 ) {
        my $now = time;

        # Process next_tick queue
        my @to_run = @next_tick_queue;
        @next_tick_queue = ();
        for my $cb (@to_run) {
            try { $cb->() }
            catch ($e) { warnings::warnif __CLASS__, '[Loop] next_tick exception: ' . $e }
        }

        # Process timers
        my @expired_timers;
        while ( @timers && $timers[0][0] <= $now ) {
            push @expired_timers, shift @timers;
        }
        for my $t (@expired_timers) {
            try { $t->[1]->() }
            catch ($e) { warnings::warnif __CLASS__, '[Loop] Timer exception: ' . $e }
        }
        if ( !$read_set->count && !$write_set->count ) {
            return         if @to_run || @expired_timers;
            sleep $timeout if $timeout > 0;
            return;
        }
        my $sel_timeout = $timeout // 0.01;
        my ( $can_read, $can_write ) = IO::Select->select( $read_set, $write_set, undef, $sel_timeout );

        # Windows loopback hack: if select returns nothing, force a poll of all streams
        $self->force_poll() if ( !$can_read || !@$can_read ) && ( !$can_write || !@$can_write ) && $^O eq 'MSWin32' && $read_set->count;
        $can_read  //= [];
        $can_write //= [];
        $self->_handle_ready( $can_read, $can_write );
        Acme::Parataxis->maybe_yield() if $backend eq 'parataxis';
    }

    method await ($future) {
        if ( $backend eq 'parataxis' && Acme::Parataxis->current_fid != -1 ) {
            if ( builtin::blessed($future) && $future->can('then') ) {
                my $pf = Acme::Parataxis::Future->new();
                $future->then( sub { $pf->done(@_) }, sub { $pf->fail(@_) } );
                return $pf->await();
            }
            return Acme::Parataxis->await($future);
        }
        else {
            my $start      = time;
            my $last_print = $start;
            while ( !$future->is_ready ) {
                my $now = time();
                if ( $ENV{DEBUG} && $now - $last_print >= 5 ) {
                    $last_print = $now;
                    my @handles = eval { $read_set->handles } || ();
                    warnings::warnif __CLASS__, '[Loop] await loop: ' . scalar(@handles) . ' handles in read_set';
                }
                $self->tick(0.001);

                # Busy-wait slightly on Windows to prevent select from hanging
                sleep(0.001) if $^O eq 'MSWin32' && !$future->is_ready;
                if ( time() - $start > 60 ) {
                    warnings::warnif __CLASS__, '[Loop] await loop: TIMEOUT REACHED';

                    # Final attempt to see if data was missed
                    $self->force_poll() if $^O eq 'MSWin32';
                    if ( !$future->is_ready ) {
                        $future->fail("await timed out after 60s");
                        last;
                    }
                }
            }
            return $future->get;
        }
    }
    my $INSTANCE;

    sub get ($class) {
        unless ($INSTANCE) {
            $INSTANCE = $class->new();
            warnings::warnif __PACKAGE__, '[Loop] New singleton created: ' . $INSTANCE;
        }
        return $INSTANCE;
    }
};
#
1;
