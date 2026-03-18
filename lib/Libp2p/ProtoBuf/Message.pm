use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ProtoBuf::Message v0.0.1 {
    use Libp2p::ProtoBuf;

    # Package-global registries shared across all files
    our %REGISTRY;
    our %SYNTAX;
    sub pb_syntax ( $class, $syntax ) { $SYNTAX{$class} = $syntax }

    sub pb_field ( $class, $tag, $name, $type, %opts ) {
        $REGISTRY{$class}{$tag}
            = { name => $name, type => $type, class => $opts{class}, repeated => $opts{repeated}, writer => $opts{writer}, packed => $opts{packed} };
    }

    sub pb_map ( $class, $tag, $name, $key_type, $val_type, %opts ) {
        $REGISTRY{$class}{$tag} = { name => $name, type => 'map', key_type => $key_type, val_type => $val_type, writer => $opts{writer} };
    }

    method _pb_fields () {
        my $class = ref($self) || $self;
        return %{ $REGISTRY{$class} // {} };
    }

    method _pb_syntax () {
        my $class = ref($self) || $self;
        return $SYNTAX{$class} // 'proto2';
    }

    method to_pb () {
        state $pp //= Libp2p::ProtoBuf->new();
        return $pp->encode($self);
    }

    sub from_pb ( $class, $data ) {
        state $pp //= Libp2p::ProtoBuf->new();
        return $pp->decode( $class, $data );
    }
};
#
1;
