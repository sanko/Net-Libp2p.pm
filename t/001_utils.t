use v5.40;
use Test2::V0;
use Libp2p::Utils qw(encode_varint decode_varint);
subtest 'encode_varint' => sub {
    is( encode_varint(0),   "\x00",     '0 -> 0x00' );
    is( encode_varint(1),   "\x01",     '1 -> 0x01' );
    is( encode_varint(127), "\x7f",     '127 -> 0x7f' );
    is( encode_varint(128), "\x80\x01", '128 -> 0x80 0x01' );
    is( encode_varint(255), "\xff\x01", '255 -> 0xff 0x01' );
    is( encode_varint(300), "\xAC\x02", '300 -> 0xAC 0x02' );
};
subtest 'decode_varint string' => sub {
    my ( $val, $bytes ) = decode_varint("\x00");
    is( $val,   0, 'decode 0' );
    is( $bytes, 1, '1 byte read' );
    ( $val, $bytes ) = decode_varint("\xAC\x02");
    is( $val,   300, 'decode 300' );
    is( $bytes, 2,   '2 bytes read' );
    ( $val, $bytes ) = decode_varint("\x80\x01");
    is( $val,   128, 'decode 128' );
    is( $bytes, 2,   '2 bytes read' );
};
subtest 'decode_varint with offset' => sub {
    my $data = "junk" . "\xAC\x02";
    my ( $val, $bytes ) = decode_varint( $data, 4 );
    is( $val,   300, 'decode 300 with offset' );
    is( $bytes, 2,   '2 bytes read' );
};
subtest 'decode_varint filehandle' => sub {
    my $data = "\xAC\x02" . "\x01";
    open my $fh, '<', \$data;
    my ( $val, $bytes ) = decode_varint($fh);
    is( $val,   300, 'decode 300 from FH' );
    is( $bytes, 2,   '2 bytes read' );

    # Read next
    ( $val, $bytes ) = decode_varint($fh);
    is( $val,   1, 'decode 1 from FH (next)' );
    is( $bytes, 1, '1 byte read' );
};
done_testing;
