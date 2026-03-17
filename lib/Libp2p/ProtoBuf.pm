use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ProtoBuf v0.0.1 {
    use Libp2p::Utils qw[encode_varint decode_varint];

    # Field types
    use constant { TYPE_VARINT => 0, TYPE_64BIT => 1, TYPE_LENGTH => 2, TYPE_32BIT => 5 };

    # Security Limits
    use constant { MAX_RECURSION_DEPTH => 32, MAX_ARRAY_ELEMENTS => 65536 };

    method encode ($msg_obj) {
        my $out    = '';
        my %fields = $msg_obj->_pb_fields();
        my $syntax = $msg_obj->_pb_syntax() // 'proto2';
        for my $tag ( sort { $a <=> $b } keys %fields ) {
            my $info = $fields{$tag};
            my $val  = $msg_obj->${ \( $info->{name} ) };
            next unless defined $val;
            if ( $info->{type} eq 'map' ) {
                if ( $syntax eq 'proto3' && !scalar keys %$val ) {
                    next;
                }
                while ( my ( $k, $v ) = each %$val ) {
                    my $entry_pb = '';
                    $entry_pb .= $self->_encode_field( 1, $info->{key_type}, $k );
                    $entry_pb .= $self->_encode_field( 2, $info->{val_type}, $v );
                    $out      .= pack( 'C', ( $tag << 3 ) | TYPE_LENGTH ) . encode_varint( length($entry_pb) ) . $entry_pb;
                }
            }
            elsif ( $info->{repeated} ) {
                if ( $syntax eq 'proto3' && !scalar @$val ) {
                    next;
                }
                if ( $info->{packed} || ( $syntax eq 'proto3' && $self->_is_packable( $info->{type} ) ) ) {
                    my $packed_data = '';
                    for my $item (@$val) {
                        $packed_data .= $self->_encode_primitive_data( $info->{type}, $item );
                    }
                    $out .= pack( 'C', ( $tag << 3 ) | TYPE_LENGTH ) . encode_varint( length($packed_data) ) . $packed_data;
                }
                else {
                    $out .= $self->_encode_field( $tag, $info->{type}, $_ ) for @$val;
                }
            }
            else {
                if ( $syntax eq 'proto3' && !$info->{repeated} && !$info->{oneof} ) {
                    next if $info->{type} =~ /int|uint|enum|bool/ && $val == 0;
                    next if $info->{type} =~ /string|bytes/       && $val eq "";
                }
                $out .= $self->_encode_field( $tag, $info->{type}, $val );
            }
        }
        return $out;
    }
    method _is_packable ($type) { $type =~ /int|uint|enum|bool|fixed|sfixed|float|double|sint/ }

    method _encode_primitive_data ( $type, $val ) {
        return encode_varint($val) if $type =~ /int|uint|enum|bool/;
        return '';
    }

    method _encode_field ( $tag, $type, $val ) {
        my $wire;
        my $data = '';
        if ( $type eq 'string' || $type eq 'bytes' ) {
            $wire = TYPE_LENGTH;
            $data = encode_varint( length($val) ) . $val;
        }
        elsif ( $type =~ /int|uint|enum|bool/ ) {
            $wire = TYPE_VARINT;
            $data = encode_varint($val);
        }
        elsif ( $type eq 'message' ) {
            $wire = TYPE_LENGTH;
            my $inner = $self->encode($val);
            $data = encode_varint( length($inner) ) . $inner;
        }
        return pack( 'C', ( $tag << 3 ) | $wire ) . $data;
    }

    method decode ( $class, $data, $depth //= 0 ) {
        die "Protobuf Error: Max recursion depth exceeded" if $depth > MAX_RECURSION_DEPTH;
        my $msg_obj       = $class->new();
        my %fields        = $msg_obj->_pb_fields();
        my %tags_to_names = map { $_ => $fields{$_} } keys %fields;
        my $pos           = 0;
        my $data_len      = length($data);
        while ( $pos < $data_len ) {
            my ( $tag_and_wire, $vlen ) = decode_varint( $data, $pos );
            last unless defined $tag_and_wire;
            $pos += $vlen;
            my $tag  = $tag_and_wire >> 3;
            my $wire = $tag_and_wire & 0x07;
            my $info = $tags_to_names{$tag};
            if ($info) {
                if ( $info->{type} eq 'map' ) {
                    my ( $len, $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                    die "Protobuf Error: Field length exceeds available data" if $pos + $len > $data_len;
                    my $entry_data = substr( $data, $pos, $len );
                    $pos += $len;
                    my ( $mk, $mv ) = $self->_decode_map_entry( $info, $entry_data, $depth + 1 );
                    my $target = $msg_obj->${ \( $info->{name} ) };
                    if ( !defined $target ) {
                        $target = {};
                        my $writer = $info->{writer} // 'set_' . $info->{name};
                        $msg_obj->$writer($target);
                    }
                    die "Protobuf Error: Map exceeds max keys" if scalar( keys %$target ) >= MAX_ARRAY_ELEMENTS;
                    $target->{$mk} = $mv;
                    next;
                }
                my @vals;
                if ( $wire == TYPE_LENGTH && $self->_is_packable( $info->{type} ) && $info->{repeated} ) {
                    my ( $len, $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                    die "Protobuf Error: Packed length exceeds available data" if $pos + $len > $data_len;
                    my $end = $pos + $len;
                    while ( $pos < $end ) {
                        my ( $v, $vl_inner ) = decode_varint( $data, $pos );
                        push @vals, $v;
                        $pos += $vl_inner;
                        die "Protobuf Error: Packed array exceeds max elements" if scalar(@vals) > MAX_ARRAY_ELEMENTS;
                    }
                }
                elsif ( $wire == TYPE_VARINT ) {
                    my ( $v, $vl ) = decode_varint( $data, $pos );
                    push @vals, $v;
                    $pos += $vl;
                }
                elsif ( $wire == TYPE_LENGTH ) {
                    my ( $len, $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                    die "Protobuf Error: Field length exceeds available data" if $pos + $len > $data_len;
                    my $val = substr( $data, $pos, $len );
                    $pos += $len;
                    if ( $info->{type} eq 'message' ) {
                        $val = $self->decode( $info->{class}, $val, $depth + 1 );
                    }
                    push @vals, $val;
                }
                for my $val (@vals) {
                    if ( $info->{repeated} ) {
                        my $target = $msg_obj->${ \( $info->{name} ) };
                        if ( !defined $target ) {
                            $target = [];
                            my $writer = $info->{writer} // 'set_' . $info->{name};
                            $msg_obj->$writer($target);
                        }
                        die "Protobuf Error: Repeated array exceeds max elements" if scalar( $target->@* ) >= MAX_ARRAY_ELEMENTS;
                        push $target->@*, $val;
                    }
                    else {
                        my $writer = $info->{writer} // 'set_' . $info->{name};
                        $msg_obj->$writer($val);
                    }
                }
            }
            else {
                # Skip unknown fields safely
                if ( $wire == TYPE_VARINT ) {
                    my ( undef, $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                }
                elsif ( $wire == TYPE_LENGTH ) {
                    my ( $len, $vl ) = decode_varint( $data, $pos );
                    die "Protobuf Error: Unknown field length exceeds available data" if $pos + $vl + $len > $data_len;
                    $pos += $vl + $len;
                }
                elsif ( $wire == TYPE_64BIT ) { $pos += 8; }
                elsif ( $wire == TYPE_32BIT ) { $pos += 4; }
                else {
                    die "Protobuf Error: Unknown wire type $wire";
                }
            }
        }
        return $msg_obj;
    }

    method _decode_map_entry( $info, $data, $depth ) {
        my ( $k, $v );
        my $pos      = 0;
        my $data_len = length($data);
        while ( $pos < $data_len ) {
            my ( $tw, $vl ) = decode_varint( $data, $pos );
            $pos += $vl;
            my $tag = $tw >> 3;
            if ( $tag == 1 ) {
                if ( $info->{key_type} eq 'string' || $info->{key_type} eq 'bytes' ) {
                    my ( $len, $lvl ) = decode_varint( $data, $pos );
                    $pos += $lvl;
                    die "Protobuf Error: Map key length exceeds available data" if $pos + $len > $data_len;
                    $k = substr( $data, $pos, $len );
                    $pos += $len;
                }
                else {
                    my ( $val, $lvl ) = decode_varint( $data, $pos );
                    $k = $val;
                    $pos += $lvl;
                }
            }
            elsif ( $tag == 2 ) {
                if ( $info->{val_type} eq 'string' || $info->{val_type} eq 'bytes' ) {
                    my ( $len, $lvl ) = decode_varint( $data, $pos );
                    $pos += $lvl;
                    die "Protobuf Error: Map val length exceeds available data" if $pos + $len > $data_len;
                    $v = substr( $data, $pos, $len );
                    $pos += $len;
                }
                else {
                    my ( $val, $lvl ) = decode_varint( $data, $pos );
                    $v = $val;
                    $pos += $lvl;
                }
            }
        }
        return ( $k, $v );
    }
};
#
1;
