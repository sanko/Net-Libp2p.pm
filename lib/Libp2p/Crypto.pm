use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
# Define the Protobuf Message structure for Public Keys
package Libp2p::Crypto::PublicKeyMsg {
    use feature 'class';
    no warnings 'experimental::class';

    class Libp2p::Crypto::PublicKeyMsg {
        field $Type : reader : writer = undef;
        field $Data : reader : writer = undef;

        method _pb_fields () {
            return ( 1 => { name => 'Type', type => 'enum' }, 2 => { name => 'Data', type => 'bytes' }, );
        }
    }
}

class Libp2p::Crypto {
    use Crypt::PK::Ed25519;
    use Crypt::PK::X25519;
    use Crypt::PK::RSA;
    use Crypt::PK::ECC;
    use Libp2p::PeerID;
    use Libp2p::ProtoBuf;
    use Libp2p::Utils qw[encode_varint decode_varint];
    use Digest::SHA   qw[sha256];
    #
    field $key  : reader;
    field $type : param : reader //= 'Ed25519';
    field $static_x25519 : reader = Crypt::PK::X25519->new();
    #
    ADJUST {
        # Key generation based on type
        if ( $type eq 'Ed25519' ) {
            $key = Crypt::PK::Ed25519->new();
            $key->generate_key();
        }
        elsif ( $type eq 'RSA' ) {
            $key = Crypt::PK::RSA->new();

            # 1024 is sufficient for testing and faster
            $key->generate_key(1024);
        }
        elsif ( $type eq 'Secp256k1' ) {
            $key = Crypt::PK::ECC->new();
            $key->generate_key('secp256k1');
        }
        else {
            die "Unsupported key type: $type";
        }

        # Noise always uses X25519 for ephemeral/static DH, regardless of identity key
        $static_x25519->generate_key();
    }

    method public_key_raw () {

        # libp2p uses a Protobuf 'PublicKey' message:
        # message PublicKey {
        #   required KeyType Type = 1;
        #   required bytes Data = 2;
        # }
        # enum KeyType { RSA=0; Ed25519=1; Secp256k1=2; ECDSA=3; }
        my $raw_key;
        my $key_type_val;
        if ( $type eq 'Ed25519' ) {
            $key_type_val = 1;
            $raw_key      = $key->export_key_raw('public');
        }
        elsif ( $type eq 'RSA' ) {
            $key_type_val = 0;
            $raw_key      = $key->export_key_der('public');    # DER/PKCS#1
        }
        elsif ( $type eq 'Secp256k1' ) {
            $key_type_val = 2;
            $raw_key      = $key->export_key_raw('public');
        }

        # Encode as Protobuf manually (could also use the class, but this is fast)
        my $pb = pack( "C", ( 1 << 3 ) | 0 ) . encode_varint($key_type_val);
        $pb .= pack( "C", ( 2 << 3 ) | 2 ) . encode_varint( length($raw_key) ) . $raw_key;
        return $pb;
    }

    method sign ($data) {
        $key->sign_message($data);
    }

    sub peer_id_from_public_key ( $class, $pk_pb ) {
        Libp2p::PeerID->from_public_key($pk_pb);
    }

    method verify ( $data, $sig, $pub_key_bytes = undef ) {
        if ($pub_key_bytes) {

            # Decode the protobuf wrapper
            my $pb_engine = Libp2p::ProtoBuf->new();
            my $msg       = $pb_engine->decode( 'Libp2p::Crypto::PublicKeyMsg', $pub_key_bytes );
            my $k_type    = $msg->Type;
            my $k_data    = $msg->Data;
            die "Invalid PublicKey Protobuf: Missing Type or Data" unless defined $k_type && defined $k_data;

            # Instantiate the correct CryptX verifier
            if ( $k_type == 1 ) {    # Ed25519
                my $vkey = Crypt::PK::Ed25519->new();
                $vkey->import_key_raw( $k_data, 'public' );
                return $vkey->verify_message( $sig, $data );
            }
            elsif ( $k_type == 0 ) {    # RSA (DER format, new(\$data) works)
                my $vkey = Crypt::PK::RSA->new( \$k_data );
                return $vkey->verify_message( $sig, $data );
            }
            elsif ( $k_type == 2 ) {    # Secp256k1
                my $vkey = Crypt::PK::ECC->new();
                $vkey->import_key_raw( $k_data, 'public', 'secp256k1' );
                return $vkey->verify_message( $sig, $data );
            }
            else {
                die "Unsupported or unknown KeyType ($k_type) during verification.";
            }
        }

        # Self-verification fallback
        return $key->verify_message( $sig, $data );
    }
    method static_x25519_pub_raw () { $static_x25519->export_key_raw('public') }
    method peer_id ()               { Libp2p::PeerID->from_public_key( $self->public_key_raw() ) }
};
#
1;
