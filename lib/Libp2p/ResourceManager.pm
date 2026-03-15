use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Libp2p::ResourceManager v0.1.0 {
    field $max_memory      : param  //= 1024 * 1024 * 1024;    # 1GB
    field $max_streams     : param //= 1000;
    field $max_connections : param //= 100;
    field $current_memory      = 0;
    field $current_streams     = 0;
    field $current_connections = 0;
    #
    method reserve_memory ($amount) {
        return 0 if $current_memory + $amount > $max_memory;
        $current_memory += $amount;
        return 1;
    }

    method release_memory ($amount) {
        $current_memory -= $amount;
        $current_memory = 0 if $current_memory < 0;
    }

    method open_stream () {
        return 0 if $current_streams >= $max_streams;
        $current_streams++;
        return 1;
    }

    method close_stream () {
        $current_streams--;
        $current_streams = 0 if $current_streams < 0;
    }

    method open_connection () {
        return 0 if $current_connections >= $max_connections;
        $current_connections++;
        return 1;
    }

    method close_connection () {
        $current_connections--;
        $current_connections = 0 if $current_connections < 0;
    }

    method stats () {
        return { memory => $current_memory, streams => $current_streams, connections => $current_connections, };
    }
};
#
1;
