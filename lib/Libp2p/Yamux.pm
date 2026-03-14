use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Yamux v0.0.1 {

    # Types
    use constant TYPE_DATA       => 0;
    use constant TYPE_WIN_UPDATE => 1;
    use constant TYPE_PING       => 2;
    use constant TYPE_GO_AWAY    => 3;

    # Flags
    use constant FLAG_SYN => 1;
    use constant FLAG_ACK => 2;
    use constant FLAG_FIN => 4;
    use constant FLAG_RST => 8;

    method parse_header ($bytes) {
        return undef unless length($bytes) == 12;
        my ( $ver, $type, $flags, $sid, $len ) = unpack 'CCnNN', $bytes;
        { version => $ver, type => $type, flags => $flags, sid => $sid, length => $len };
    }

    method build_header ( $type, $flags, $sid, $len, $ver //= 0 ) {    # Some implementations prefer version 0
        pack 'CCnNN', $ver, $type, $flags, $sid, $len;
    }
};
#
1;
