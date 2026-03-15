use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ProtoBuf::Message v0.0.1 {
    use Libp2p::ProtoBuf;

    # Static registry for fields
    my %REGISTRY;
    my %SYNTAX;
    sub pb_syntax ( $class, $syntax ) { $SYNTAX{$class} = $syntax }

    sub pb_field ( $class, $tag, $name, $type, %opts ) {
        $REGISTRY{$class}{$tag}
            = { name => $name, type => $type, class => $opts{class}, repeated => $opts{repeated}, writer => $opts{writer}, packed => $opts{packed} };
    }

    sub pb_map ( $class, $tag, $name, $key_type, $val_type, %opts ) {
        $REGISTRY{$class}{$tag} = { name => $name, type => 'map', key_type => $key_type, val_type => $val_type, writer => $opts{writer} };
    }
    method _pb_fields () { return %{ $REGISTRY{ ref($self) || $self } // {} } }
    method _pb_syntax () { return $SYNTAX{ ref($self) || $self } // 'proto2' }

    method to_pb () {
        state $pp //= Libp2p::ProtoBuf->new();
        $pp->encode($self);
    }

    sub from_pb ( $class, $data ) {
        state $pp //= Libp2p::ProtoBuf->new();
        $pp->decode( $class, $data );
    }
};
#
1;
