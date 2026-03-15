use v5.40;
use Test2::V0;
use feature 'class';
no warnings 'experimental::class';
use blib;
use Libp2p::ProtoBuf::Message;

# Define Proto3 messages
class Test::Proto3 : isa(Libp2p::ProtoBuf::Message) {
    field $id   : param : reader : writer(set_id)   //= 0;
    field $name : param : reader : writer(set_name) //= "";
    field $nums : param : reader : writer(set_nums) //= [];
    field $meta : param : reader : writer(set_meta) //= {};
    __PACKAGE__->pb_syntax('proto3');
    __PACKAGE__->pb_field( 1, 'id',   'int32',  writer   => 'set_id' );
    __PACKAGE__->pb_field( 2, 'name', 'string', writer   => 'set_name' );
    __PACKAGE__->pb_field( 3, 'nums', 'int32',  repeated => 1, writer => 'set_nums' );
    __PACKAGE__->pb_map( 4, 'meta', 'string', 'string', writer => 'set_meta' );
}
subtest Defaults => sub {
    my $msg = Test::Proto3->new();
    my $pb  = $msg->to_pb();
    diag 'Encoded: ' . unpack( 'H*', $pb );
    is length($pb), 0, 'empty message for default values';
};
subtest 'Packed repeated' => sub {
    my $msg = Test::Proto3->new( nums => [ 1, 2, 3 ] );
    my $pb  = $msg->to_pb();
    is unpack( 'H*', $pb ), '1a03010203', 'packed encoding';
    my $dec = Test::Proto3->from_pb($pb);
    is $dec->nums, [ 1, 2, 3 ], 'decoded packed';
};
subtest Maps => sub {
    my $msg = Test::Proto3->new( meta => { foo => 'bar' } );
    my $pb  = $msg->to_pb();
    my $dec = Test::Proto3->from_pb($pb);
    is $dec->meta, { foo => 'bar' }, 'decoded map';
};
#
done_testing;
