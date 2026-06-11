package CtrlExecMCP::Validate;

use strict;
use warnings;

# A pragmatic JSON Schema validator covering the subset the ctrl-exec sidecar
# argument schemas actually use - enough to fail bad tool-call arguments fast
# with a clear message, so the model can self-correct, before anything is
# dispatched. It is not a full draft-2020-12 implementation.
#
# Supported keywords: type (string/integer/number/boolean/object/array/null,
# or an array of types), enum, const, required, properties,
# additionalProperties (boolean), items, minimum, maximum, minLength, maxLength,
# pattern, minItems, maxItems. Unknown keywords are ignored. JSON numbers are
# compared leniently (a numeric string satisfies integer/number).
#
# check($schema, $value) returns an arrayref of human-readable error strings
# (empty when valid).

sub check {
    my ($schema, $value) = @_;
    my @errors;
    _check($schema, $value, '', \@errors);
    return \@errors;
}

sub _check {
    my ($schema, $value, $path, $err) = @_;
    return unless ref $schema eq 'HASH';
    my $where = $path eq '' ? 'value' : $path;

    if (defined $schema->{type}) {
        my @types = ref $schema->{type} eq 'ARRAY' ? @{ $schema->{type} } : ($schema->{type});
        unless (grep { _type_ok($_, $value) } @types) {
            push @$err, "$where: expected " . join('/', @types);
            return;   # other checks are meaningless once the type is wrong
        }
    }

    if (ref $schema->{enum} eq 'ARRAY') {
        push @$err, "$where: not one of the allowed values"
            unless grep { _eq($_, $value) } @{ $schema->{enum} };
    }
    if (exists $schema->{const}) {
        push @$err, "$where: must equal the allowed constant"
            unless _eq($schema->{const}, $value);
    }

    if (defined $value && !ref $value && _looks_numeric($value)) {
        push @$err, "$where: below minimum $schema->{minimum}"
            if defined $schema->{minimum} && $value < $schema->{minimum};
        push @$err, "$where: above maximum $schema->{maximum}"
            if defined $schema->{maximum} && $value > $schema->{maximum};
    }
    if (defined $value && !ref $value) {
        push @$err, "$where: shorter than minLength $schema->{minLength}"
            if defined $schema->{minLength} && length($value) < $schema->{minLength};
        push @$err, "$where: longer than maxLength $schema->{maxLength}"
            if defined $schema->{maxLength} && length($value) > $schema->{maxLength};
        if (defined $schema->{pattern}) {
            my $re = $schema->{pattern};
            push @$err, "$where: does not match pattern" unless eval { $value =~ /$re/ };
        }
    }

    if (ref $value eq 'HASH') {
        if (ref $schema->{required} eq 'ARRAY') {
            for my $r (@{ $schema->{required} }) {
                push @$err, "$where: missing required property '$r'"
                    unless exists $value->{$r};
            }
        }
        my $props = ref $schema->{properties} eq 'HASH' ? $schema->{properties} : {};
        for my $k (sort keys %$value) {
            if (exists $props->{$k}) {
                _check($props->{$k}, $value->{$k}, ($path eq '' ? $k : "$path.$k"), $err);
            }
            elsif (exists $schema->{additionalProperties} && !_truthy($schema->{additionalProperties})) {
                push @$err, "$where: unknown property '$k'";
            }
        }
    }

    if (ref $value eq 'ARRAY') {
        push @$err, "$where: fewer than minItems $schema->{minItems}"
            if defined $schema->{minItems} && @$value < $schema->{minItems};
        push @$err, "$where: more than maxItems $schema->{maxItems}"
            if defined $schema->{maxItems} && @$value > $schema->{maxItems};
        if (ref $schema->{items} eq 'HASH') {
            my $i = 0;
            for my $el (@$value) {
                _check($schema->{items}, $el, ($path eq '' ? "[$i]" : "$path\[$i]"), $err);
                $i++;
            }
        }
    }
}

# --- helpers ---

sub _type_ok {
    my ($type, $v) = @_;
    return ref $v eq 'HASH'  if $type eq 'object';
    return ref $v eq 'ARRAY' if $type eq 'array';
    return !defined $v       if $type eq 'null';
    return _is_bool($v) || (defined $v && !ref $v && ($v eq '0' || $v eq '1'))
        if $type eq 'boolean';
    return defined $v && !ref $v && $v =~ /^-?\d+$/ if $type eq 'integer';
    return defined $v && !ref $v && _looks_numeric($v) if $type eq 'number';
    return defined $v && !ref $v if $type eq 'string';
    return 1;   # unknown type: do not fail
}

sub _looks_numeric {
    my ($v) = @_;
    return $v =~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/;
}

sub _is_bool { return ref $_[0] eq 'JSON::PP::Boolean' }

sub _truthy { return $_[0] ? 1 : 0 }

sub _eq {
    my ($a, $b) = @_;
    return "$a" eq "$b" if _is_bool($a) && _is_bool($b);
    return 0 if ref $a || ref $b;
    return 0 unless defined $a && defined $b;
    return "$a" eq "$b";
}

1;
