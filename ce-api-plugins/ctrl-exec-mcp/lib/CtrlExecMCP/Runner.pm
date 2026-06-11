package CtrlExecMCP::Runner;

use strict;
use warnings;
use JSON::PP ();

# Executes an MCP tools/call against the ctrl-exec API. It resolves the tool to
# its script and target hosts (via the shared catalogue), renders the named
# arguments into the script's positional argv, dispatches asynchronously
# (POST /run with async), polls GET /status until the run completes, and shapes
# the per-host outcome into an MCP tool result.
#
# Dispatching async means a long-running script is not bound by the API read
# timeout: the bridge holds the MCP call open and polls while the agent runs
# the job detached.

sub new {
    my ($class, %opts) = @_;
    die "catalog required" unless $opts{catalog};
    die "api required"     unless $opts{api};
    return bless {
        catalog       => $opts{catalog},
        api           => $opts{api},
        poll_interval => $opts{poll_interval} // 2,
        timeout       => $opts{timeout}       // 300,
        # injectable clock/sleep so the poll loop is testable without waiting
        sleeper       => $opts{sleeper} // sub { sleep $_[0] },
        now           => $opts{now}     // sub { time },
    }, $class;
}

# Returns an MCP tool result: { content => [...], isError, structuredContent }.
# Argument/host errors die and are surfaced as an isError result by the server.
sub call {
    my ($self, $name, $args) = @_;
    my $tool = $self->{catalog}->tool($name) or die "unknown tool: $name\n";

    my $hosts    = _resolve_hosts($tool, $args);
    my $run_args = defined $tool->{argv}
        ? _render_argv($tool->{argv}, $args, _defaults($tool))
        : _generic_args($args);

    my $sub = $self->{api}->run(hosts => $hosts, script => $tool->{script}, args => $run_args);
    unless ($sub->{ok}) {
        return _error_result(
            "dispatch failed (HTTP $sub->{status})" .
            (ref $sub->{data} eq 'HASH' && $sub->{data}{error} ? ": $sub->{data}{error}" : ''));
    }
    my $reqid = ref $sub->{data} eq 'HASH' ? $sub->{data}{reqid} : undef;
    return _error_result('dispatch returned no reqid') unless defined $reqid;

    my $record = $self->_poll($reqid);
    return _shape_result($record, $reqid);
}

# --- host resolution ---

sub _resolve_hosts {
    my ($tool, $args) = @_;
    my $allowed = $tool->{hosts} || [];
    my $req     = $args->{hosts};

    return $allowed if !defined $req || (ref $req eq 'ARRAY' && !@$req);
    die "hosts must be an array\n" unless ref $req eq 'ARRAY';

    my %ok = map { $_ => 1 } @$allowed;
    my @bad = grep { !$ok{$_} } @$req;
    die "hosts not available for this tool: @{[ join ', ', @bad ]}\n" if @bad;
    return $req;
}

# --- argv rendering (named MCP arguments -> positional /run args) ---

sub _defaults {
    my ($tool) = @_;
    my $props = eval { $tool->{schema}{arguments}{properties} };
    return {} unless ref $props eq 'HASH';
    my %d;
    for my $p (keys %$props) {
        $d{$p} = $props->{$p}{default} if ref $props->{$p} eq 'HASH' && exists $props->{$p}{default};
    }
    return \%d;
}

sub _render_argv {
    my ($argv, $args, $defaults) = @_;
    $defaults //= {};
    my @out;
    for my $tok (@$argv) {
        if (!ref $tok) { push @out, "$tok"; next; }      # literal
        next unless ref $tok eq 'HASH';
        my $name = $tok->{arg};
        next unless defined $name;

        my $val = exists $args->{$name}     ? $args->{$name}
                : exists $defaults->{$name} ? $defaults->{$name}
                : undef;

        if (defined $tok->{flag}) {
            if (_is_boolish($val)) {
                push @out, $tok->{flag} if _is_true($val);   # boolean flag
            }
            elsif (defined $val) {
                push @out, $tok->{flag}, "$val";              # flag + value
            }
            next;
        }
        if ($tok->{repeat} && ref $val eq 'ARRAY') {
            push @out, map { "$_" } @$val;
            next;
        }
        push @out, "$val" if defined $val;
    }
    return \@out;
}

sub _generic_args {
    my ($args) = @_;
    my $a = $args->{args};
    return ref $a eq 'ARRAY' ? [ map { "$_" } @$a ] : [];
}

sub _is_boolish {
    my ($v) = @_;
    return 1 if ref $v && (ref $v eq 'JSON::PP::Boolean');
    return 0;
}

sub _is_true { my ($v) = @_; return $v ? 1 : 0 }

# --- polling ---

sub _poll {
    my ($self, $reqid) = @_;
    my $deadline = $self->{now}->() + $self->{timeout};
    while (1) {
        my $st  = $self->{api}->status($reqid);
        my $rec = $st->{ok} ? $st->{data} : undef;
        return $rec if ref $rec eq 'HASH' && $rec->{complete};
        return $rec if $self->{now}->() >= $deadline;
        $self->{sleeper}->($self->{poll_interval});
    }
}

# --- result shaping ---

sub _text { return { type => 'text', text => $_[0] } }

sub _error_result {
    my ($msg) = @_;
    return { content => [ _text($msg) ], isError => JSON::PP::true };
}

sub _shape_result {
    my ($record, $reqid) = @_;
    unless (ref $record eq 'HASH' && ref $record->{hosts} eq 'HASH') {
        return _error_result(
            "No result for request $reqid (timed out before any host completed).");
    }

    my $hosts    = $record->{hosts};
    my $complete = $record->{complete} ? 1 : 0;
    my $success  = 0;
    my @lines    = ("Request $reqid" . ($complete ? '' : ' (incomplete - timed out while polling)'));

    for my $h (sort keys %$hosts) {
        my $e  = $hosts->{$h};
        my $st = $e->{status} // 'unknown';
        if ($st eq 'done') {
            my $exit = $e->{exit} // -1;
            $success++ if $exit == 0;
            push @lines, "[$h] done (exit $exit)";
            push @lines, $e->{stdout}
                if defined $e->{stdout} && $e->{stdout} =~ /\S/;
            push @lines, "stderr: $e->{stderr}"
                if defined $e->{stderr} && $e->{stderr} =~ /\S/;
        }
        elsif ($st eq 'busy' || $st eq 'error' || $st eq 'expired') {
            push @lines, "[$h] $st" . (defined $e->{error} ? ": $e->{error}" : '');
        }
        else {
            push @lines, "[$h] $st" . ($complete ? '' : ' (still running)');
        }
    }

    my $is_error = (!$complete || $success == 0) ? JSON::PP::true : JSON::PP::false;
    return {
        content           => [ _text(join "\n", @lines) ],
        isError           => $is_error,
        structuredContent => {
            reqid    => $reqid,
            complete => ($complete ? JSON::PP::true : JSON::PP::false),
            hosts    => $hosts,
        },
    };
}

1;
