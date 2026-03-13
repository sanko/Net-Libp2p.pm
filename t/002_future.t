use v5.40;
use Test2::V0;
use Libp2p::Future;
use Libp2p::Loop;
subtest 'basic future' => sub {
    my $f = Libp2p::Future->new;
    ok( !$f->is_ready, 'future is pending' );
    $f->done('ok');
    ok( $f->is_ready, 'future is ready' );
    is( [ $f->get ], ['ok'], 'result matches' );
};
subtest 'callbacks' => sub {
    my $f = Libp2p::Future->new;
    my $res;
    $f->then( sub { $res = shift } );
    $f->done('foo');

    # Callback is deferred via next_tick
    ok( !$res, 'callback deferred' );
    Libp2p::Loop->get->tick();
    is( $res, 'foo', 'callback ran after tick' );
};
subtest 'chaining' => sub {
    my $f1 = Libp2p::Future->new;
    my $f2 = $f1->then( sub { return shift . 'bar' } );
    $f1->done('foo');
    Libp2p::Loop->get->tick();    # Run f1 callback which resolves f2
    ok( $f2->is_ready, 'chained future is ready' );
    is( [ $f2->get ], ['foobar'], 'chaining works' );
};
subtest 'fail' => sub {
    my $f = Libp2p::Future->new;
    my $err;
    $f->catch( sub { $err = shift } );
    $f->fail('error');
    Libp2p::Loop->get->tick();
    is( $err, 'error', 'catch works' );
    like( dies { $f->get }, qr/error/, 'get throws on failed future' );
};
done_testing;
