use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ConnectionManager {
    field $host            : param;
    field $max_connections : param //= 50;
    field $min_connections : param //= 10;
    field %connections;    # peer_id => stream

    #
    method add_connection ( $peer_id, $stream ) {
        if ( scalar keys %connections >= $max_connections ) {
            $self->prune_connections();
            if ( scalar keys %connections >= $max_connections ) {

                # Still full, reject
                return 0;
            }
        }

        #~ say "[NETWORK] [ConnMgr] Added connection to $peer_id (Total: " . ( scalar keys %connections ) . ")" if $ENV{DEBUG};
        $connections{$peer_id} = $stream;
        return 1;
    }

    method remove_connection ($peer_id) {
        if ( exists $connections{$peer_id} ) {
            delete $connections{$peer_id};

            #~ say "[NETWORK] [ConnMgr] Removed connection to $peer_id (Total: " . ( scalar keys %connections ) . ")" if $ENV{DEBUG};
        }
    }
    method get_connection ($peer_id) { $connections{$peer_id} // () }

    method prune_connections () {

        # Simple strategy: Close random connections until we are below max
        # Real impl will prioritize protected peers, high scores, etc.
        #~ say "[NETWORK] [ConnMgr] Pruning connections..." if $ENV{DEBUG};
        my @peers = keys %connections;
        while ( scalar keys %connections > $min_connections ) {
            my $p = shift @peers;
            last unless defined $p;

            # Close stream
            my $stream = delete $connections{$p};
            try { $stream->close() } catch ($e) {
                ;
            }

            #~ say "[NETWORK] [ConnMgr] Pruned $p" if $ENV{DEBUG};
        }
    }
    method connection_count () { scalar keys %connections }
};
#
1;
