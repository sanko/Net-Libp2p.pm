use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ProtoBuf v0.0.1 {
    use Libp2p::Utils qw[encode_varint decode_varint];
    use constant { TYPE_VARINT => 0, TYPE_64BIT => 1, TYPE_LENGTH => 2, TYPE_32BIT => 5 };

    method encode ($msg_obj) {
        my $out    = '';
        my %fields = $msg_obj->_pb_fields();
        my $syntax = $msg_obj->_pb_syntax();
        for my $tag ( sort { $a <=> $b } keys %fields ) {
            my $info = $fields{$tag};
            my $name = $info->{name};
            my $val  = $msg_obj->$name();
            next unless defined $val;

            # Proto3 omits default values from the wire entirely
            if ( $syntax eq 'proto3' ) {
                if ( $info->{type} eq 'map' ) {
                    next if ref($val) eq 'HASH' && !keys(%$val);
                }
                elsif ( $info->{repeated} ) {
                    next if ref($val) eq 'ARRAY' && !@$val;
                }
                elsif ( $info->{type} eq 'message' ) {

                    # Empty messages are encoded but skipped if totally undef
                }
                elsif ( $info->{type} eq 'string' || $info->{type} eq 'bytes' ) {
                    next if $val eq '';
                }
                else {
                    next if $val == 0;
                }
            }
            if ( $info->{type} eq 'map' ) {
                while ( my ( $k, $v ) = each %$val ) {
                    my $entry = $self->_encode_field( 1, $info->{key_type}, $k ) . $self->_encode_field( 2, $info->{val_type}, $v );
                    $out .= pack( 'C', ( $tag << 3 ) | TYPE_LENGTH ) . encode_varint( length($entry) ) . $entry;
                }
            }
            elsif ( $info->{repeated} ) {

                # In proto3, repeated scalars are packed by default
                my $is_packed = $info->{packed} // ( $syntax eq 'proto3' && $info->{type} =~ /int|uint|enum|bool/ );
                if ($is_packed) {
                    my $payload = '';
                    for my $v (@$val) {
                        if ( $info->{type} =~ /int|uint|enum|bool/ ) {
                            $payload .= encode_varint($v);
                        }
                        elsif ( $info->{type} =~ /fixed32|sfixed32|float/ ) {
                            $payload .= pack( 'V', $v );
                        }
                        elsif ( $info->{type} =~ /fixed64|sfixed64|double/ ) {
                            $payload .= pack( 'Q<', $v );
                        }
                    }
                    $out .= pack( 'C', ( $tag << 3 ) | TYPE_LENGTH ) . encode_varint( length($payload) ) . $payload;
                }
                else {
                    $out .= $self->_encode_field( $tag, $info->{type}, $_ ) for @$val;
                }
            }
            else {
                $out .= $self->_encode_field( $tag, $info->{type}, $val );
            }
        }
        return $out;
    }

    method decode ( $class_name, $data, $depth //= 0 ) {
        my $msg_obj  = $class_name->new();
        my %fields   = $msg_obj->_pb_fields();
        my $pos      = 0;
        my $data_len = length($data);
        while ( $pos < $data_len ) {
            my ( $tag_wire, $vlen ) = decode_varint( $data, $pos );
            last unless defined $tag_wire;
            $pos += $vlen;
            my $tag  = $tag_wire >> 3;
            my $wire = $tag_wire & 0x07;
            my $info = $fields{$tag};
            if ($info) {
                my $reader = $info->{name};
                my $writer = $info->{writer} // 'set_' . $info->{name};
                if ( $info->{type} eq 'map' ) {
                    ( my $len, my $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                    my $entry_data = substr( $data, $pos, $len );
                    $pos += $len;
                    my ( $k, $v ) = $self->_decode_map_entry( $entry_data, $info->{key_type}, $info->{val_type} );
                    my $current = $msg_obj->$reader() // {};
                    $current->{$k} = $v;
                    $msg_obj->$writer($current);
                }
                elsif ( $info->{repeated} && $wire == TYPE_LENGTH && $info->{type} =~ /int|uint|enum|bool/ ) {

                    # Decoding packed repeated scalars
                    ( my $len, my $vl ) = decode_varint( $data, $pos );
                    $pos += $vl;
                    my $end     = $pos + $len;
                    my $current = $msg_obj->$reader() // [];
                    while ( $pos < $end ) {
                        my ( $val, $vvl ) = decode_varint( $data, $pos );
                        $pos += $vvl;
                        push @$current, $val;
                    }
                    $msg_obj->$writer($current);
                }
                else {
                    my $val;
                    if ( $wire == TYPE_VARINT ) {
                        ( $val, my $vl ) = decode_varint( $data, $pos );
                        $pos += $vl;
                    }
                    elsif ( $wire == TYPE_LENGTH ) {
                        ( my $len, my $vl ) = decode_varint( $data, $pos );
                        $pos += $vl;
                        $val = substr( $data, $pos, $len );
                        $pos += $len;
                        $val = $self->decode( $info->{class}, $val, $depth + 1 ) if $info->{type} eq 'message';
                    }
                    if ( $info->{repeated} ) {
                        my $current = $msg_obj->$reader() // [];
                        push @$current, $val;
                        $msg_obj->$writer($current);
                    }
                    else {
                        $msg_obj->$writer($val);
                    }
                }
            }
            else {
                # Skip unknown fields
                if    ( $wire == TYPE_VARINT ) { my ( undef, $vl ) = decode_varint( $data, $pos ); $pos += $vl; }
                elsif ( $wire == TYPE_LENGTH ) { my ( $len, $vl ) = decode_varint( $data, $pos ); $pos  += $vl + $len; }
                elsif ( $wire == TYPE_64BIT )  { $pos                                                   += 8; }
                elsif ( $wire == TYPE_32BIT )  { $pos                                                   += 4; }
            }
        }
        return $msg_obj;
    }

    method _decode_map_entry ( $entry_data, $ktype, $vtype ) {
        my $pos = 0;
        my $k;
        my $v;
        while ( $pos < length($entry_data) ) {
            my ( $tag_wire, $vl ) = decode_varint( $entry_data, $pos );
            $pos += $vl;
            my $tag  = $tag_wire >> 3;
            my $wire = $tag_wire & 0x07;
            my $val;
            if ( $wire == TYPE_VARINT ) {
                ( $val, my $vvl ) = decode_varint( $entry_data, $pos );
                $pos += $vvl;
            }
            elsif ( $wire == TYPE_LENGTH ) {
                ( my $len, my $vvl ) = decode_varint( $entry_data, $pos );
                $pos += $vvl;
                $val = substr( $entry_data, $pos, $len );
                $pos += $len;
            }
            if ( $tag == 1 ) {
                $k = $val;
            }
            elsif ( $tag == 2 ) {
                $v = $val;
            }
        }
        $k //= ( $ktype =~ /int|uint/ ? 0 : '' );
        $v //= ( $vtype =~ /int|uint/ ? 0 : '' );
        return ( $k, $v );
    }

    method _encode_field ( $tag, $type, $val ) {
        my ( $wire, $data );
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
};
#
1;
