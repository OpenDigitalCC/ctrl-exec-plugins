package CtrlExecMCP::Catalog;

use strict;
use warnings;
use JSON::PP ();

# Turns a ctrl-exec /discovery response into the MCP tool set, using versioned
# Model A: one tool per (script name, schema version). A homogeneous fleet
# yields one tool per script; a script split across schema versions becomes
# `name@<version>` tools, each scoped to the hosts running that version, so
# fleet drift is visible rather than silently reconciled.
#
# The discovery data is supplied by an injected `source` coderef returning the
# hosts map { hostname => { status, scripts => [ {name, schema?,
# schema_version?}, ... ] } }, so synthesis is testable without networking.
#
# Alongside the MCP tool definitions it keeps an index mapping each tool name
# to { script, hosts, schema_version, schema, argv } for the runner to dispatch.

sub new {
    my ($class, %opts) = @_;
    die "source required" unless ref $opts{source} eq 'CODE';
    return bless {
        source    => $opts{source},
        tools     => undef,
        index     => undef,
        signature => undef,
    }, $class;
}

# MCP catalog interface used by the server.
sub list_tools {
    my ($self) = @_;
    $self->_build;                 # refresh on each list so it reflects the fleet
    return $self->{tools};
}

sub has_tool {
    my ($self, $name) = @_;
    $self->_ensure_built;
    return exists $self->{index}{$name} ? 1 : 0;
}

# Internal descriptor for a tool name (script, hosts, version, schema, argv).
sub tool {
    my ($self, $name) = @_;
    $self->_ensure_built;
    return $self->{index}{$name};
}

# Re-fetch and rebuild; returns 1 if the tool set changed since last build.
sub refresh { return $_[0]->_build }

# --- build ---

sub _ensure_built { $_[0]->_build unless defined $_[0]->{tools} }

sub _build {
    my ($self) = @_;
    my $hosts = $self->{source}->() // {};
    my ($tools, $index) = _synthesize($hosts);
    my $sig = JSON::PP->new->canonical->encode($tools);
    my $changed = (!defined $self->{signature} || $self->{signature} ne $sig) ? 1 : 0;
    $self->{tools}     = $tools;
    $self->{index}     = $index;
    $self->{signature} = $sig;
    return $changed;
}

# --- synthesis (pure) ---

sub _synthesize {
    my ($hosts) = @_;

    # Group hosts (and the schema) by (script name, schema version).
    my %groups;   # name => { version_key => { hosts => {h=>1}, schema, schema_version } }
    for my $host (sort keys %$hosts) {
        my $h = $hosts->{$host};
        next unless ($h->{status} // '') eq 'ok';
        next unless ref $h->{scripts} eq 'ARRAY';
        for my $s (@{ $h->{scripts} }) {
            my $name = $s->{name} or next;
            my $ver  = $s->{schema_version};
            my $key  = defined $ver ? $ver : '';     # '' == no schema
            my $g = $groups{$name}{$key} ||= { hosts => {} };
            $g->{hosts}{$host}     = 1;
            $g->{schema_version}   = $ver if defined $ver;
            $g->{schema}           = $s->{schema}
                if ref $s->{schema} eq 'HASH' && !$g->{schema};
        }
    }

    my (@tools, %index);
    for my $name (sort keys %groups) {
        my @keys  = sort keys %{ $groups{$name} };
        my $split = @keys > 1;                        # versions in flight -> suffix
        for my $key (@keys) {
            my $g     = $groups{$name}{$key};
            my @hlist = sort keys %{ $g->{hosts} };
            my $tname = $split ? $name . '@' . _suffix($key) : $name;

            my ($input_schema, $argv) = _input_schema($g->{schema}, \@hlist);

            my $tool = {
                name        => $tname,
                inputSchema => $input_schema,
                annotations => _annotations($g->{schema}),
            };
            $tool->{description} = $g->{schema}{description}
                if ref $g->{schema} eq 'HASH'
                && defined $g->{schema}{description}
                && !ref $g->{schema}{description};

            push @tools, $tool;
            $index{$tname} = {
                script         => $name,
                hosts          => \@hlist,
                schema_version => $g->{schema_version},
                schema         => $g->{schema},
                argv           => $argv,              # undef => generic args passthrough
            };
        }
    }

    return (\@tools, \%index);
}

# A tool-name-safe suffix for a schema version (drop the reserved sha256:
# prefix; replace anything outside [A-Za-z0-9_.-]).
sub _suffix {
    my ($key) = @_;
    return 'unversioned' if $key eq '';
    (my $s = $key) =~ s/^sha256://;
    $s =~ s/[^A-Za-z0-9_.\-]/_/g;
    return length $s ? $s : 'unversioned';
}

# Build the MCP inputSchema (and return the argv template, if any). With a
# sidecar `arguments` schema the named inputs are exposed and typed; without
# one the tool falls back to a positional `args` string array. `hosts` is added
# in both cases, enum-scoped to the hosts running this version.
sub _input_schema {
    my ($schema, $hosts) = @_;

    my %props = (
        hosts => {
            type        => 'array',
            items       => { type => 'string', enum => $hosts },
            description => 'Target hosts. Defaults to all hosts running this version if omitted.',
        },
    );
    my @required;
    my $argv;

    if (ref $schema eq 'HASH' && ref $schema->{arguments} eq 'HASH') {
        my $a = $schema->{arguments};
        if (ref $a->{properties} eq 'HASH') {
            $props{$_} = $a->{properties}{$_} for keys %{ $a->{properties} };
        }
        @required = @{ $a->{required} } if ref $a->{required} eq 'ARRAY';
        $argv = $schema->{argv} if ref $schema->{argv} eq 'ARRAY';
    }
    else {
        $props{args} = {
            type        => 'array',
            items       => { type => 'string' },
            description => 'Positional arguments passed to the script.',
        };
    }

    my %out = (type => 'object', properties => \%props);
    $out{required} = \@required if @required;
    return (\%out, $argv);
}

# MCP behavioural-hint annotations from the sidecar flags. destructive defaults
# true (safe) unless the script is read_only.
sub _annotations {
    my ($schema) = @_;
    my $ro = (ref $schema eq 'HASH' && $schema->{read_only}) ? 1 : 0;
    my $de;
    if (ref $schema eq 'HASH' && exists $schema->{destructive}) {
        $de = $schema->{destructive} ? 1 : 0;
    }
    else {
        $de = $ro ? 0 : 1;
    }
    my $id = (ref $schema eq 'HASH' && $schema->{idempotent}) ? 1 : 0;
    return {
        readOnlyHint    => $ro ? JSON::PP::true : JSON::PP::false,
        destructiveHint => $de ? JSON::PP::true : JSON::PP::false,
        idempotentHint  => $id ? JSON::PP::true : JSON::PP::false,
    };
}

1;
