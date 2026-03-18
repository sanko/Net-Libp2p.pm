use Test2::V0;
use blib;
use Libp2p::Muxer::Yamux;
#
subtest 'Yamux Header' => sub {
    my $yamux  = Libp2p::Muxer::Yamux->new();
    my $type   = Libp2p::Muxer::Yamux::TYPE_DATA;
    my $flags  = Libp2p::Muxer::Yamux::FLAG_SYN;
    my $sid    = 12345;
    my $len    = 67890;
    my $header = $yamux->build_header( $type, $flags, $sid, $len );
    is length($header), 12, 'header length is 12 bytes';
    my $parsed = $yamux->parse_header($header);
    ok $parsed, 'header parsed';
    is $parsed->{version}, 0,      'version is 0';
    is $parsed->{type},    $type,  'type matches';
    is $parsed->{flags},   $flags, 'flags match';
    is $parsed->{sid},     $sid,   'stream id matches';
    is $parsed->{length},  $len,   'length matches';
};
subtest 'Yamux Types' => sub {
    is Libp2p::Muxer::Yamux::TYPE_DATA,       0, 'TYPE_DATA is 0';
    is Libp2p::Muxer::Yamux::TYPE_WIN_UPDATE, 1, 'TYPE_WIN_UPDATE is 1';
    is Libp2p::Muxer::Yamux::TYPE_PING,       2, 'TYPE_PING is 2';
    is Libp2p::Muxer::Yamux::TYPE_GO_AWAY,    3, 'TYPE_GO_AWAY is 3';
};
subtest 'Yamux Flags' => sub {
    is Libp2p::Muxer::Yamux::FLAG_SYN, 1, 'FLAG_SYN is 1';
    is Libp2p::Muxer::Yamux::FLAG_ACK, 2, 'FLAG_ACK is 2';
    is Libp2p::Muxer::Yamux::FLAG_FIN, 4, 'FLAG_FIN is 4';
    is Libp2p::Muxer::Yamux::FLAG_RST, 8, 'FLAG_RST is 8';
};
#
done_testing;
