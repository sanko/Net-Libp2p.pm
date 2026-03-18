use v5.40;
use feature 'class';
no warnings 'experimental::class';

package Libp2p::Crypto::PublicKeyMsg {
    use feature 'class';

    class Libp2p::Crypto::PublicKeyMsg : isa(Libp2p::ProtoBuf::Message) {
        field $Type : reader : writer(set_Type) = undef;
        field $Data : reader : writer(set_Data) = undef;
        __PACKAGE__->pb_field( 1, 'Type', 'enum',  writer => 'set_Type' );
        __PACKAGE__->pb_field( 2, 'Data', 'bytes', writer => 'set_Data' );
    }
}

class Libp2p::Crypto {
    use Crypt::PK::Ed25519;
    use Crypt::PK::X25519;
    use Crypt::PK::RSA;
    use Crypt::PK::ECC;
    use Libp2p::PeerID;
    field $key  : reader;
    field $type : param : reader //= 'Ed25519';
    field $static_x25519 : reader = Crypt::PK::X25519->new();
    ADJUST {
        if    ( $type eq 'Ed25519' )   { $key = Crypt::PK::Ed25519->new(); $key->generate_key(); }
        elsif ( $type eq 'RSA' )       { $key = Crypt::PK::RSA->new();     $key->generate_key(256); }           # 256 bytes = 2048 bits
        elsif ( $type eq 'Secp256k1' ) { $key = Crypt::PK::ECC->new();     $key->generate_key('secp256k1'); }
        $static_x25519->generate_key();
    }

    method public_key_raw () {
        my ( $raw, $t_val );
        if    ( $type eq 'Ed25519' )   { $t_val = 1; $raw = $key->export_key_raw('public'); }
        elsif ( $type eq 'RSA' )       { $t_val = 0; $raw = $key->export_key_der('public'); }
        elsif ( $type eq 'Secp256k1' ) { $t_val = 2; $raw = $key->export_key_raw('public'); }
        my $msg = Libp2p::Crypto::PublicKeyMsg->new();
        $msg->set_Type($t_val);
        $msg->set_Data($raw);
        return $msg->to_pb();
    }

    method sign ($data) {
        if ( $type eq 'RSA' ) {
            return $key->sign_message( $data, 'SHA256', 'v1.5' );
        }
        return $key->sign_message($data);
    }

    method verify ( $data, $sig, $pub_key_pb //= undef ) {
        if ($pub_key_pb) {
            my $msg = Libp2p::Crypto::PublicKeyMsg->from_pb($pub_key_pb);
            my $t   = $msg->Type // 0;
            my $d   = $msg->Data;
            return 0 unless defined $d;

            # Force binary mode
            utf8::downgrade( $data, 1 );
            utf8::downgrade( $sig,  1 );
            utf8::downgrade( $d,    1 );
            my $vkey;
            if ( $t == 0 ) {    # RSA
                $vkey = Crypt::PK::RSA->new();

                # IMPORTANT: Pass \$d (reference) to avoid "Invalid \0 in pathname"
                eval { $vkey->import_key( \$d ) };
                if ($@) {
                    warn "[DEBUG] RSA Key Import Failed: $@" if $ENV{DEBUG};
                    return 0;
                }

                # libp2p uses PKCS1 v1.5 padding and SHA256 for RSA identities
                # Use eval because verify_message can croak on malformed signatures
                my $result = eval { $vkey->verify_message( $sig, $data, 'SHA256', 'v1.5' ) };
                return $result // 0;
            }
            elsif ( $t == 1 ) {    # Ed25519
                $vkey = Crypt::PK::Ed25519->new();
                eval { $vkey->import_key_raw( $d, 'public' ) };
                return 0 if $@;
                return eval { $vkey->verify_message( $sig, $data ) } // 0;
            }
            elsif ( $t == 2 ) {    # Secp256k1
                $vkey = Crypt::PK::ECC->new();
                eval { $vkey->import_key_raw( $d, 'public', 'secp256k1' ) };
                return 0 if $@;
                return eval { $vkey->verify_message( $sig, $data ) } // 0;
            }
        }

        # Fallback for self-verification
        if ( $type eq 'RSA' ) {
            return eval { $key->verify_message( $sig, $data, 'SHA256', 'v1.5' ) } // 0;
        }
        return eval { $key->verify_message( $sig, $data ) } // 0;
    }
    method static_x25519_pub_raw () { $static_x25519->export_key_raw('public') }
    method peer_id ()               { Libp2p::PeerID->from_public_key( $self->public_key_raw() ) }
}
1;
