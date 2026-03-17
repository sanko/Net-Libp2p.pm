requires 'Algorithm::Kademlia', 'v1.1.1';
requires 'Crypt::PK::Ed25519';
requires 'Errno';
requires 'Math::BigInt';
requires 'Noise';
requires 'Scalar::Util';
requires 'Socket';
recommends 'IO::Socket::SSL';
recommends 'Net::DNS';
recommends 'Net::SSLeay';
on configure => sub {
    requires 'Module::Build::Tiny', '0.034';
    requires 'perl',                'v5.40.0';
};
on test => sub {
    requires 'Test2::Plugin::UTF8';
    requires 'Test2::Tools::Compare';
    requires 'Test2::V0';
};
