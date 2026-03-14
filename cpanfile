requires 'Errno';
requires 'Math::BigInt';
requires 'Scalar::Util';
requires 'Socket';
on configure => sub {
    requires 'Module::Build::Tiny', '0.034';
    requires 'perl',                'v5.40.0';
};
