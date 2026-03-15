use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';
use blib;
use Libp2p::ProtoBuf::Message;

# Define test messages
class Test::Inner : isa(Libp2p::ProtoBuf::Message) {
    field $val : param : reader : writer(set_val) //= undef;
    __PACKAGE__->pb_field( 1, 'val', 'string', writer => 'set_val' );
}

class Test::Outer : isa(Libp2p::ProtoBuf::Message) {
    field $id    : param : reader : writer(set_id)    //= undef;
    field $inner : param : reader : writer(set_inner) //= undef;
    field $tags  : param : reader : writer            //= [];
    __PACKAGE__->pb_field( 1, 'id',    'int32',   writer   => 'set_id' );
    __PACKAGE__->pb_field( 2, 'inner', 'message', class    => 'Test::Inner', writer => 'set_inner' );
    __PACKAGE__->pb_field( 3, 'tags',  'string',  repeated => 1 );
}
subtest 'Scalar fields' => sub {
    my $msg = Test::Inner->new( val => 'hello' );
    my $pb  = $msg->to_pb();
    ok( length($pb) > 0, 'encoded data' );
    my $dec = Test::Inner->from_pb($pb);
    is $dec->val, 'hello', 'decoded correctly';
};
subtest 'Nested and Repeated' => sub {
    my $msg = Test::Outer->new( id => 123, inner => Test::Inner->new( val => 'sub' ), tags => [qw[a b c]] );
    my $pb  = $msg->to_pb();
    my $dec = Test::Outer->from_pb($pb);
    is $dec->id,         123,         'id';
    is $dec->inner->val, 'sub',       'nested val';
    is $dec->tags,       [qw[a b c]], 'repeated tags';
};
done_testing;
