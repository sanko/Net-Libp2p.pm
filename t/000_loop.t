use v5.40;
use Test2::V0;
use Libp2p::Loop;
use Time::HiRes qw(time);
subtest 'singleton' => sub {
    my $loop1 = Libp2p::Loop->get;
    my $loop2 = Libp2p::Loop->get;
    is( $loop1, $loop2, 'loop is singleton' );
};
subtest 'next_tick' => sub {
    my $loop = Libp2p::Loop->get;
    my $ran  = 0;
    $loop->next_tick( sub { $ran = 1 } );
    ok( !$ran, 'not run yet' );
    $loop->tick();
    ok( $ran, 'ran after tick' );
};
subtest 'timer' => sub {
    my $loop = Libp2p::Loop->get;
    my $ran  = 0;
    $loop->timer( 0.05, sub { $ran = 1 } );
    ok( !$ran, 'not run yet' );
    my $start = time();
    while ( !$ran && time() - $start < 1.0 ) {
        $loop->tick(0.02);
    }
    ok( $ran, 'timer ran within 1s' );
};
subtest 'wait_all' => sub {
    my $loop = Libp2p::Loop->get;
    my $f1   = $loop->new_future;
    my $f2   = $loop->new_future;
    my $all  = $loop->wait_all( $f1, $f2 );
    $f1->done(1);
    $loop->tick();
    ok( !$all->is_ready, 'not ready yet' );
    $f2->done(2);
    $loop->tick();
    ok( $all->is_ready, 'ready after both done' );
    is( [ $all->get ], [ [1], [2] ], 'results aggregated' );
};
done_testing;
