use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Future v0.0.1 {
    use warnings::register;
    field $state : reader //= 'pending';    # 'pending', 'ready', 'failed'
    field @results;
    field $error;
    field @on_ready_callbacks;
    field @on_fail_callbacks;
    #
    method is_ready ()  { $state ne 'pending' }
    method is_done ()   { $state eq 'ready' }
    method is_failed () { $state eq 'failed' }

    # Aliases
    sub new_future ($class_or_obj) {
        my $class = ref($class_or_obj) || $class_or_obj;
        $class->new();
    }
    sub resolve ( $class, @args ) { $class->new()->done(@args) }
    sub reject  ( $class, $err )  { $class->new()->fail($err) }

    method done (@args) {
        return $self                                                        if $self->is_ready;
        warn sprintf( '[Future] %s -> done(%d args)', $self, scalar @args ) if $ENV{DEBUG};
        $state   = 'ready';
        @results = @args;
        my @cbs = @on_ready_callbacks;
        @on_ready_callbacks = ();
        @on_fail_callbacks  = ();
        if (@cbs) {

            # Defer execution to break the stack
            require Libp2p::Loop;
            my $loop = Libp2p::Loop->get;
            $loop->next_tick(
                sub {
                    for my $cb (@cbs) {
                        my @copy = @results;                   # Prevent mutation
                        my $ok   = eval { $cb->(@copy); 1 };
                        warn "[DEBUG] [Future] on_done exception: $@\n" if !$ok && $ENV{DEBUG};
                    }
                }
            );
        }
        return $self;
    }

    method fail ($err) {
        return $self                                  if $self->is_ready;
        warn "[DEBUG] [Future] $self -> fail($err)\n" if $ENV{DEBUG};
        $state = 'failed';
        $error = $err;
        my @cbs = @on_fail_callbacks;
        @on_ready_callbacks = ();
        @on_fail_callbacks  = ();
        if (@cbs) {

            # Defer execution to break the stack
            require Libp2p::Loop;
            my $loop = Libp2p::Loop->get;
            $loop->next_tick(
                sub {
                    for my $cb (@cbs) {
                        my $ok = eval { $cb->($error); 1 };
                        warn "[DEBUG] [Future] on_fail exception: $@\n" if !$ok && $ENV{DEBUG};
                    }
                }
            );
        }
        return $self;
    }

    method then ( $on_ready = undef, $on_fail = undef ) {
        my $next          = Libp2p::Future->new;
        my $wrapped_ready = sub (@args) {
            my $ok = eval {
                if ($on_ready) {
                    my @res = $on_ready->(@args);
                    if ( @res && builtin::blessed( $res[0] ) && $res[0]->can('then') ) {
                        $res[0]->then( sub { $next->done(@_) if !$next->is_ready; return; }, sub { $next->fail(@_) if !$next->is_ready; return; } );
                    }
                    else {
                        $next->done(@res) if !$next->is_ready;
                    }
                }
                else {
                    $next->done(@args) if !$next->is_ready;    # Propagate values
                }
                1;
            };
            if ( !$ok ) {
                my $err = $@ || "Unknown error";
                warn "[DEBUG] [Future] then (on_ready) error: $err\n" if $ENV{DEBUG};
                $next->fail($err)                                     if !$next->is_ready;
            }
        };
        my $wrapped_fail = sub ($err) {
            my $ok = eval {
                if ($on_fail) {
                    my @res = $on_fail->($err);
                    if ( @res && builtin::blessed( $res[0] ) && $res[0]->can('then') ) {
                        $res[0]->then( sub { $next->done(@_) if !$next->is_ready; return; }, sub { $next->fail(@_) if !$next->is_ready; return; } );
                    }
                    else {
                        $next->done(@res) if !$next->is_ready;    # Recovered
                    }
                }
                else {
                    $next->fail($err) if !$next->is_ready;        # Propagate failure
                }
                1;
            };
            if ( !$ok ) {
                my $eval_err = $@ || "Unknown error";
                warn "[DEBUG] [Future] then (on_fail) error: $eval_err\n" if $ENV{DEBUG};
                $next->fail($eval_err)                                    if !$next->is_ready;
            }
        };
        if ( $state eq 'ready' ) {

            # Defer execution to break the stack
            require Libp2p::Loop;
            Libp2p::Loop->get->next_tick( sub { $wrapped_ready->(@results) } );
        }
        elsif ( $state eq 'failed' ) {

            # Defer execution to break the stack
            require Libp2p::Loop;
            Libp2p::Loop->get->next_tick( sub { $wrapped_fail->($error) } );
        }
        else {
            push @on_ready_callbacks, $wrapped_ready;
            push @on_fail_callbacks,  $wrapped_fail;
        }
        return $next;
    }

    method catch ($on_fail) {
        return $self->then( undef, $on_fail );
    }

    method finally ($cb) {
        return $self->then(
            sub (@args) {
                eval { $cb->() };
                return @args;
            },
            sub ($err) {
                eval { $cb->() };
                die $err;
            }
        );
    }

    method on_fail ($cb) {
        if ( $state eq 'failed' ) {
            require Libp2p::Loop;
            Libp2p::Loop->get->next_tick(
                sub {
                    try { $cb->($error) } catch ($e) {
                        warnings::warnif 'Libp2p', '[Future] on_fail exception: ' . $e;
                    }
                }
            );
        }
        elsif ( $state eq 'pending' ) { push @on_fail_callbacks, $cb }
        return $self;
    }
    method else     ($cb) { return $self->then( undef, $cb ) }
    method on_ready ($cb) { return $self->on_done($cb) }

    method on_done ($cb) {
        if ( $state eq 'ready' ) {
            require Libp2p::Loop;
            Libp2p::Loop->get->next_tick(
                sub {
                    my @copy = @results;
                    try { $cb->(@copy) } catch ($e) {
                        warnings::warnif 'Libp2p', '[Future] on_done exception: ' . $e
                    }
                }
            );
        }
        elsif ( $state eq 'pending' ) { push @on_ready_callbacks, $cb }
        return $self;
    }

    method get () {
        while ( $state eq 'pending' ) {
            die 'Future->get called on pending future without loop integration';
        }
        die $error if $state eq 'failed';
        return wantarray ? @results : $results[0];
    }
} 1;
