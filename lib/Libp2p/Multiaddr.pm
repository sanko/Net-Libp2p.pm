use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::Multiaddr v0.0.1 {
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Socket qw[inet_aton inet_ntoa inet_pton inet_ntop AF_INET6];
    #
    field $string : param : reader = undef;
    field $bytes  : param : reader = undef;

    # Protocol Registry
    my %PROTOCOLS = (
        ip4           => { code => 4,   size =>  32, type => 'ipv4' },
        ip6           => { code => 41,  size => 128, type => 'ipv6' },
        tcp           => { code => 6,   size =>  16, type => 'uint16' },
        udp           => { code => 273, size =>  16, type => 'uint16' },
        p2p           => { code => 421, size => -1,  type => 'multihash' },
        ipfs          => { code => 421, size => -1,  type => 'multihash' },    # Alias for p2p
        ws            => { code => 477, size =>  0,  type => 'none' },
        wss           => { code => 478, size =>  0,  type => 'none' },
        'p2p-circuit' => { code => 290, size =>  0,  type => 'none' },
        dns4          => { code => 54,  size => -1,  type => 'string' },
        dns6          => { code => 55,  size => -1,  type => 'string' }
    );

    # Map codes back to canonical names (force 421 back to 'p2p')
    my %CODES = map { $PROTOCOLS{$_}{code} => $_ } keys %PROTOCOLS;
    $CODES{421} = 'p2p';
    ADJUST {
        if ( defined $string ) {
            $self->_parse_string($string);
        }
        elsif ( defined $bytes ) {
            $self->_parse_bytes($bytes);
        }
    }
    sub from_string ( $class, $str ) { $class->new( string => $str ) }
    sub from_bytes  ( $class, $bin ) { $class->new( bytes  => $bin ) }
    method to_binary () {$bytes}

    method _parse_string ($str) {
        $string = $str;
        my @parts = split( '/', $str );
        shift @parts if @parts && $parts[0] eq '';
        my $bin = '';
        while (@parts) {
            my $name  = shift @parts;
            my $proto = $PROTOCOLS{$name} or die 'Unknown protocol: ' . $name;
            $bin .= Libp2p::Utils::encode_varint( $proto->{code} );
            if ( $proto->{type} eq 'ipv4' ) {
                my $val = shift @parts;
                $bin .= inet_aton($val);
            }
            elsif ( $proto->{type} eq 'ipv6' ) {
                my $val = shift @parts;
                $bin .= inet_pton( AF_INET6, $val ) || die 'Invalid IPv6 address: ' . $val;
            }
            elsif ( $proto->{type} eq 'uint16' ) {
                my $val = shift @parts;
                $bin .= pack 'n', $val;
            }
            elsif ( $proto->{type} eq 'string' ) {
                my $val = shift @parts;
                $bin .= Libp2p::Utils::encode_varint( length($val) ) . $val;
            }
            elsif ( $proto->{type} eq 'multihash' ) {
                my $val = shift @parts;
                require Libp2p::PeerID;
                my $peer = Libp2p::PeerID->decode($val);
                die 'Invalid peer ID: ' . $val unless $peer;

                # The p2p multiaddr spec requires the raw binary multihash
                my $mh = $peer->multihash;
                $bin .= Libp2p::Utils::encode_varint( length($mh) ) . $mh;
            }
        }
        $bytes = $bin;
    }

    method _parse_bytes ($bin) {
        $bytes = $bin;
        my $str = '';
        my $pos = 0;
        while ( $pos < length($bin) ) {
            my ( $code, $vlen ) = Libp2p::Utils::decode_varint( $bin, $pos );
            $pos += $vlen;
            my $name  = $CODES{$code} or die 'Unknown protocol code: ' . $code;
            my $proto = $PROTOCOLS{$name};
            $str .= '/' . $name;
            if ( $proto->{type} eq 'ipv4' ) {
                $str .= '/' . inet_ntoa( substr( $bin, $pos, 4 ) );
                $pos += 4;
            }
            elsif ( $proto->{type} eq 'ipv6' ) {
                $str .= '/' . inet_ntop( AF_INET6, substr( $bin, $pos, 16 ) );
                $pos += 16;
            }
            elsif ( $proto->{type} eq 'uint16' ) {
                $str .= '/' . unpack( 'n', substr( $bin, $pos, 2 ) );
                $pos += 2;
            }
            elsif ( $proto->{type} eq 'string' ) {
                my ( $len, $lvlen ) = Libp2p::Utils::decode_varint( $bin, $pos );
                $pos += $lvlen;
                $str .= '/' . substr( $bin, $pos, $len );
                $pos += $len;
            }
            elsif ( $proto->{type} eq 'multihash' ) {
                my ( $len, $lvlen ) = Libp2p::Utils::decode_varint( $bin, $pos );
                $pos += $lvlen;
                my $mh = substr( $bin, $pos, $len );
                $pos += $len;
                require Libp2p::PeerID;
                my $peer = Libp2p::PeerID->from_binary($mh);

                # Reconstruct canonical Base58BTC string for Version 0
                my $peer_str = $peer->version == 0 ? $self->_encode_base58btc($mh) : $peer->to_string;
                $str .= '/' . $peer_str;
            }
        }
        $string = $str;
    }

    method _encode_base58btc ($bin) {
        require Math::BigInt;
        my $alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
        my @chars    = split //, $alphabet;
        my $num      = Math::BigInt->from_hex( '0x' . unpack 'H*', $bin );
        my $str      = '';
        while ( $num->bcmp(0) > 0 ) {
            my ( $quo, $rem ) = $num->bdiv(58);
            $str = $chars[ $rem->numify ] . $str;
            $num = $quo;
        }

        # Prepend '1' for every leading zero byte
        for my $i ( 0 .. length($bin) - 1 ) {
            if ( ord( substr( $bin, $i, 1 ) ) == 0 ) {
                $str = '1' . $str;
            }
            else {
                last;
            }
        }
        return $str;
    }

    # Compatibility methods
    method protocol ()  { ( $string =~ m{^/([^/]+)} )[0] }
    method address ()   { ( $string =~ m{^/[^/]+/([^/]+)} )[0] }
    method transport () { ( $string =~ m{^/[^/]+/[^/]+/([^/]+)} )[0] }
    method port ()      { ( $string =~ m{^/[^/]+/[^/]+/[^/]+/([^/]+)} )[0] }
};
#
1;
