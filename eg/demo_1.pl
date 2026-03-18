use v5.40;
use lib 'lib', '../lib';
use Libp2p;
use Libp2p::Protocol::Identify;
use Libp2p::Muxer::Yamux;

BEGIN {
    #~ $ENV{DEBUG}               = 1;
    $ENV{LIBP2P_LOOP_BACKEND} = 'native';

    #~ $ENV{NOISE_DEBUG}         = 1;
}
my $sig = 1 ? '/tls/1.0.0' : '/noise';
say '=== Starting Perl libp2p Node (' . ( $sig =~ /tls/ ? 'TLS' : 'Noise' ) . ' Mode) ===';
my $node = Libp2p->new_node( port => 4001 );

# Pluto (IPFS Bootstrap Node)
my $target_ma = "/ip4/104.131.131.82/tcp/4001";
$node->io_utils->loop->new_future->done($node)->then(
    sub ($host) {
        return $host->dial( $target_ma, $sig )->then(
            sub ($stream) {
                return ( $host, $stream );
            }
        );
    }
)->then(
    sub ( $host, $stream ) {
        if ( $sig =~ /tls/ ) {
            say "\n[1] TCP Connected. Negotiated /tls/1.0.0.";
            require Libp2p::Security::TLS;
            my $tls = Libp2p::Security::TLS->new( host => $host );
            return $tls->initiate_handshake($stream)->then(
                sub ($secure_stream) {
                    return ( $host, $secure_stream );
                }
            );
        }
        else {
            say "\n[1] TCP Connected. Negotiated /noise.";
            require Libp2p::Security::Noise;
            my $noise = Libp2p::Security::Noise->new( host => $host );
            return $noise->initiate_handshake($stream)->then(
                sub ($secure_stream) {
                    return ( $host, $secure_stream );
                }
            );
        }
    }
)->then(
    sub ( $host, $secure_stream ) {
        say "\n[2] Noise Handshake Complete! Connection is now encrypted.";
        say "=> Negotiating /yamux/1.0.0 over secure stream...";
        return $secure_stream->negotiate('/yamux/1.0.0')->then(
            sub {
                say "[DEBUG] Yamux/1.0.0 negotiation ACK received successfully.";
                return ( $host, $secure_stream );
            },
            sub ($err) {
                die "Yamux negotiation failed: $err";
            }
        );
    }
)->then(
    sub ( $host, $secure_stream ) {
        say "\n[3] Yamux Negotiated!";
        say "=> Starting Yamux Multiplexer Session...";
        my $yamux = Libp2p::Muxer::Yamux->new( connection => $secure_stream, is_client => 1 );
        $yamux->start();
        say "=> Yamux session started.";
        say "=> Opening a virtual Yamux substream...";
        my $substream = $yamux->open_stream();
        return $substream->negotiate('/ipfs/id/1.0.0')->then(
            sub {
                say "\n[4] Identify Negotiated!";
                my $identify = Libp2p::Protocol::Identify->new( host => $host );
                return $identify->request($substream);
            }
        );
    }
)->then(
    sub ($id_msg) {
        say "\n=== [5] SUCCESS! Remote Node Identified via $sig ===";
        say "Agent Version: " . $id_msg->agentVersion;
        say "Protocols    : " . join( ', ', $id_msg->protocols->@* );
        exit(0);
    }
)->catch(
    sub ($err) {
        warn "\n[!] Dial sequence failed: $err\n";
        exit(1);
    }
);
$node->io_utils->loop->run();
__END__
use v5.40;
use lib '../lib', 'lib';
use Libp2p;
use Libp2p::Security::Noise;
use Libp2p::Protocol::Identify;
use Libp2p::Muxer::Yamux;

# Turn on debug output so we can see the magic happen!
BEGIN {
    $ENV{DEBUG}               = 1;
    $ENV{LIBP2P_LOOP_BACKEND} = 'native';
}


# 1. Start our node
say "=== Starting Perl libp2p Node ===";
my $node = Libp2p->new_node(port => 4001);

my $my_peer_id = $node->peer_id->to_string;
say "My Peer ID: $my_peer_id";
say "Listening on: " . $_->string for $node->listen_addrs->@*;
say "=================================";

# IPFS Bootstrap Node (Pluto)
# We dial the direct IPv4 address to avoid DNS issues in the demo
my $target_ip   = '104.131.131.82';
my $target_port = 4001;
my $target_ma   = "/ip4/$target_ip/tcp/$target_port";

say "\n=> Dialing IPFS Bootstrap Node: $target_ma";

# Orchestrate the stack manually to demonstrate how the layers fit together
$node->dial($target_ma, '/noise')->then(sub ($stream) {
    say "\n[1] TCP Connected. Multistream negotiated /noise.";
    say "=> Initiating Noise XX Handshake...";

    my $noise = Libp2p::Security::Noise->new(host => $node);
    return $noise->initiate_handshake($stream);

})->then(sub ($secure_stream) {
    say "\n[2] Noise Handshake Complete! Connection is now encrypted.";
    say "=> Negotiating /yamux/1.0.0 over secure stream...";

    return $secure_stream->negotiate('/yamux/1.0.0')->then(sub {
        return $secure_stream;
    });

})->then(sub ($secure_stream) {
    say "\n[3] Yamux Negotiated!";
    say "=> Starting Yamux Multiplexer Session...";

    my $yamux = Libp2p::Muxer::Yamux->new(
        connection => $secure_stream,
        is_client  => 1
    );
    $yamux->start();

    say "=> Opening a virtual Yamux substream...";
    my $substream = $yamux->open_stream();

    say "=> Negotiating /ipfs/id/1.0.0 over substream...";
    return $substream->negotiate('/ipfs/id/1.0.0')->then(sub {

        say "\n[4] Identify Negotiated!";
        say "=> Sending Identify request...";

        my $identify = Libp2p::Protocol::Identify->new(host => $node);
        return $identify->request($substream);
    });

})->then(sub ($id_msg) {
    say "\n=== [5] SUCCESS! Remote Node Identified ===";
    say "Agent Version   : " . $id_msg->agentVersion;
    say "Protocol Version: " . $id_msg->protocolVersion;

    my $pid = Libp2p::Crypto->peer_id_from_public_key($id_msg->publicKey);
    say "Remote Peer ID  : " . $pid->to_string;

    say "Protocols Supported:";
    say "  - $_" for @{ $id_msg->protocols };

    say "===========================================";

    # Exit gracefully
    exit(0);

})->catch(sub ($err) {
    warn "\n[!] Dial sequence failed: $err\n";
    exit(1);
});

# Run the event loop
$node->io_utils->loop->run();
