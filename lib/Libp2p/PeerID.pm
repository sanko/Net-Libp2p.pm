use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::PeerID {
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Digest::SHA   qw[sha256];
    use Scalar::Util  qw[openhandle];
    #
    field $version : param : reader;
    field $codec   : param : reader;
    field $hash    : param : reader;
    field $digest  : param : reader;
    field $raw     : param : reader;
    #
    method to_string () {

        # Canonical libp2p PeerID string is based on the multihash.
        # We use 'f' + hex(multihash) for a stable internal string representation.
        'f' . unpack 'H*', $self->multihash();
    }

    sub from_binary ( $class, $bin ) {
        my $pos = 0;
        my ( $v, $br ) = decode_varint( $bin, $pos );
        return undef unless defined $v;
        if ( $v == 0x01 ) {    # CIDv1 prefix
            my $version = $v;
            $pos += $br;
            my ( $codec, $cbr ) = decode_varint( $bin, $pos );
            $pos += $cbr;
            my $mh_start = $pos;
            my ( $mh_type, $tbr ) = decode_varint( $bin, $pos );
            $pos += $tbr;
            my ( $mh_len, $mlbr ) = decode_varint( $bin, $pos );
            $pos += $mlbr;
            my $digest = substr( $bin, $pos, $mh_len );
            $pos += $mh_len;
            my $raw = substr( $bin, 0, $pos );
            return $class->new( version => $version, codec => $codec, hash => $mh_type, digest => $digest, raw => $raw );
        }
        else {    # Raw Multihash (CIDv0 / legacy standard)
            my $mh_type = $v;
            $pos += $br;
            my ( $mh_len, $lbr ) = decode_varint( $bin, $pos );
            $pos += $lbr;
            my $digest = substr( $bin, $pos, $mh_len );
            $pos += $mh_len;
            my $raw = substr( $bin, 0, $pos );
            return $class->new( version => 0, codec => 0x72, hash => $mh_type, digest => $digest, raw => $raw );
        }
    }

    sub from_public_key ( $class, $pk_pb ) {
        my ( $hash, $digest );
        if ( length($pk_pb) <= 42 ) {
            $digest = $pk_pb;
            $hash   = 0x00;     # identity
        }
        else {
            $digest = sha256($pk_pb);
            $hash   = 0x12;             # sha2-256
        }
        my $multihash = encode_varint($hash) . encode_varint( length($digest) ) . $digest;

        # Peer IDs on the wire are purely the multihash, version 0 by default.
        return $class->new( version => 0, codec => 0x72, hash => $hash, digest => $digest, raw => $multihash );
    }
    method multihash () { encode_varint($hash) . encode_varint( length($digest) ) . $digest }

    #~ https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md#decoding
    # Helper to decode Base58BTC (used for legacy Qm... and 1... strings)
    sub decode_base58btc ( $class, $str ) {
        require Math::BigInt;
        my $alphabet         = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
        my %map              = map { substr( $alphabet, $_, 1 ) => $_ } 0 .. 57;
        my $num              = Math::BigInt->new(0);
        my $leading_zeros    = 0;
        my $counting_leading = 1;
        for my $char ( split //, $str ) {
            if ( $counting_leading && $char eq '1' ) {
                $leading_zeros++;
            }
            else {
                $counting_leading = 0;
                $num->bmul(58);
                $num->badd( $map{$char} );
            }
        }
        my $hex = $num->as_hex;
        $hex =~ s/^0x//;
        $hex = '0' . $hex if length($hex) % 2 != 0;
        return ( "\x00" x $leading_zeros ) . pack( 'H*', $hex );
    }

    sub decode_multibase_base32 ( $class, $str ) {
        $str =~ s/^b//;    # Strip the 'b' multibase prefix
        my $alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
        my %map      = map { substr( $alphabet, $_, 1 ) => $_ } 0 .. 31;
        my $bits     = '';
        for my $char ( split //, lc($str) ) {
            return undef unless exists $map{$char};
            $bits .= sprintf( "%05b", $map{$char} );
        }

        # Drop trailing zero bits (Base32 without padding)
        my $len = int( length($bits) / 8 ) * 8;
        $bits = substr( $bits, 0, $len );
        return pack( 'B*', $bits );
    }

    sub decode ( $class, $input ) {
        my $str = $input;

        # Accept filehandles just like the old version
        if ( openhandle($input) || ( blessed($input) && $input->can('read') ) ) {
            local $/;
            $str = <$input>;
        }

        # Auto-detect format
        my $bin;
        if ( $str =~ /^b[a-z2-7]+$/ ) {
            $bin = $class->decode_multibase_base32($str);
        }
        elsif ( $str =~ /^(Qm|1)[1-9A-HJ-NP-Za-km-z]+$/ ) {
            $bin = $class->decode_base58btc($str);
        }
        else {
            $bin = $str;    # Fall back to raw binary
        }
        return $class->from_binary($bin);
    }
};
#
1;
