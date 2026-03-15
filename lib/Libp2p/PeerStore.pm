use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::PeerStore v0.0.1 {
    use Libp2p::PeerID;
    field %peers;    # Canonical PeerID string -> { addrs => [], protocols => [], metadata => {} }

    method _to_id_key ($peer_id) {
        $peer_id // return '';
        return $peer_id->to_string if ref($peer_id) && $peer_id->isa('Libp2p::PeerID');

        # If it's already a canonical multibase string (starts with f, z, b, Qm, 1, etc.)
        return $peer_id if $peer_id =~ /^[a-zA-Z0-9]+$/;

        # If it's binary data, try to decode to canonical string
        if ( length($peer_id) >= 32 ) {
            try { return Libp2p::PeerID->from_binary($peer_id)->to_string } catch ($e) {

                # TODO: warn? ignore?
            }
        }
        return $peer_id;
    }

    method add_addr ( $peer_id, $multiaddr ) {
        my $pid = $self->_to_id_key($peer_id);
        return unless $pid;
        $peers{$pid} //= { addrs => [], protocols => [], metadata => {} };
        unless ( grep { $_ eq $multiaddr } $peers{$pid}{addrs}->@* ) {
            push $peers{$pid}{addrs}->@*, $multiaddr;
        }
    }

    method add_protocol ( $peer_id, $protocol ) {
        my $pid = $self->_to_id_key($peer_id);
        return unless $pid;
        $peers{$pid} //= { addrs => [], protocols => [], metadata => {} };
        push $peers{$pid}{protocols}->@*, $protocol unless grep { $_ eq $protocol } $peers{$pid}{protocols}->@*;
    }

    method get_addrs ($peer_id) {
        my $pid = $self->_to_id_key($peer_id);
        return [] unless exists $peers{$pid};
        return $peers{$pid}{addrs} // [];
    }

    method get_protocols ($peer_id) {
        my $pid = $self->_to_id_key($peer_id);
        return [] unless exists $peers{$pid};
        return $peers{$pid}{protocols} // [];
    }

    method peers_supporting ($protocol) {
        my @matching;
        for my $pid ( keys %peers ) {
            push @matching, $pid if exists $peers{$pid}{protocols} && grep { $_ eq $protocol } $peers{$pid}{protocols}->@*;
        }
        return \@matching;
    }

    method set_metadata ( $peer_id, $key, $val ) {
        my $pid = $self->_to_id_key($peer_id);
        return unless $pid;
        $peers{$pid} //= { addrs => [], protocols => [], metadata => {} };
        $peers{$pid}{metadata}{$key} = $val;
    }

    method get_metadata ( $peer_id, $key ) {
        my $pid = $self->_to_id_key($peer_id);
        return undef unless exists $peers{$pid};
        return $peers{$pid}{metadata}{$key};
    }

    method stats () {
        my %copy;
        for my $k ( keys %peers ) {
            $copy{$k} = { addrs => [ $peers{$k}{addrs}->@* ], protocols => [ $peers{$k}{protocols}->@* ] };
        }
        return \%copy;
    }
};
#
1;
