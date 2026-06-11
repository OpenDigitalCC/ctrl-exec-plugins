#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP ();

use CtrlExecMCP::Validate qw();

sub ok_valid {
    my ($schema, $value, $label) = @_;
    my $e = CtrlExecMCP::Validate::check($schema, $value);
    is scalar(@$e), 0, $label or diag "errors: @$e";
}
sub ok_invalid {
    my ($schema, $value, $label, $re) = @_;
    my $e = CtrlExecMCP::Validate::check($schema, $value);
    ok scalar(@$e) > 0, $label;
    like "@$e", $re, "$label (message)" if $re;
}

# --- types ---
ok_valid   ({ type => 'integer' }, 5,      'integer accepts number');
ok_valid   ({ type => 'integer' }, '5',    'integer accepts numeric string');
ok_invalid ({ type => 'integer' }, '5.5',  'integer rejects float', qr/expected integer/);
ok_invalid ({ type => 'integer' }, 'x',    'integer rejects non-numeric');
ok_valid   ({ type => 'number' },  '1.5',  'number accepts float');
ok_valid   ({ type => 'string' },  'hi',   'string accepts text');
ok_invalid ({ type => 'string' },  { a => 1 }, 'string rejects object', qr/expected string/);
ok_valid   ({ type => 'array' },   [1, 2], 'array accepts list');
ok_invalid ({ type => 'array' },   'no',   'array rejects scalar');
ok_valid   ({ type => 'boolean' }, JSON::PP::true,  'boolean accepts true');
ok_valid   ({ type => 'boolean' }, JSON::PP::false, 'boolean accepts false');
ok_valid   ({ type => ['string', 'null'] }, undef,  'union type accepts null');

# --- enum / const ---
ok_valid   ({ enum => ['a', 'b'] }, 'a', 'enum member ok');
ok_invalid ({ enum => ['a', 'b'] }, 'c', 'enum non-member rejected', qr/allowed values/);
ok_valid   ({ const => 'x' }, 'x', 'const match ok');
ok_invalid ({ const => 'x' }, 'y', 'const mismatch rejected');

# --- numeric bounds ---
ok_valid   ({ type => 'integer', minimum => 1, maximum => 100 }, 50, 'in range');
ok_invalid ({ type => 'integer', minimum => 1 }, 0, 'below minimum', qr/below minimum/);
ok_invalid ({ type => 'integer', maximum => 100 }, 101, 'above maximum', qr/above maximum/);

# --- string length / pattern ---
ok_invalid ({ type => 'string', minLength => 2 }, 'a', 'too short', qr/minLength/);
ok_invalid ({ type => 'string', pattern => '^[a-z]+$' }, 'AB', 'pattern mismatch', qr/pattern/);
ok_valid   ({ type => 'string', pattern => '^[a-z]+$' }, 'ab', 'pattern match');

# --- objects: required, properties, additionalProperties ---
my $obj = {
    type       => 'object',
    required   => ['name'],
    properties => {
        name      => { type => 'string' },
        threshold => { type => 'integer', minimum => 1, maximum => 100 },
    },
};
ok_valid   ($obj, { name => 'web', threshold => 90 }, 'valid object');
ok_invalid ($obj, { threshold => 90 }, 'missing required', qr/missing required property 'name'/);
ok_invalid ($obj, { name => 'web', threshold => 200 }, 'nested bound violated', qr/threshold: above maximum/);
ok_invalid ($obj, { name => 'web', threshold => 'big' }, 'nested type violated', qr/threshold: expected integer/);

my $closed = { type => 'object', properties => { a => { type => 'string' } }, additionalProperties => JSON::PP::false };
ok_valid   ($closed, { a => 'x' }, 'closed object: known prop ok');
ok_invalid ($closed, { a => 'x', b => 1 }, 'closed object: unknown prop rejected', qr/unknown property 'b'/);
ok_valid   ({ type => 'object', properties => { a => { type => 'string' } } },
            { a => 'x', extra => 1 }, 'open object: unknown prop allowed by default');

# --- arrays: items, bounds ---
ok_valid   ({ type => 'array', items => { type => 'integer' } }, [1, 2, 3], 'typed array ok');
ok_invalid ({ type => 'array', items => { type => 'integer' } }, [1, 'x'], 'array item type', qr/\[1\]: expected integer/);
ok_invalid ({ type => 'array', minItems => 1 }, [], 'minItems', qr/minItems/);

# --- empty schema accepts anything ---
ok_valid   ({}, { anything => [1, 2] }, 'empty schema permits all');

done_testing;
