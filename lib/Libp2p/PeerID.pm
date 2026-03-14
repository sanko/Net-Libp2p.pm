use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::PeerID {
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Digest::SHA   qw[sha256];
    #
    field $version : param : reader;
    field $codec   : param : reader;
    field $hash    : param : reader;
    field $digest  : param : reader;
    field $raw     : param : reader;
    #
    method to_string () {
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

    sub decode ( $class, $fh ) {
        local $/;
        my $bin = <$fh>;
        $class->from_binary($bin);
    }
};
#
1;
