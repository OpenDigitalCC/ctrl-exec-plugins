#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use CtrlExecMCP::Catalog;

# A discovery hosts map: check-disk is typed and split across two schema
# versions; env-dump is untyped; a down host is ignored.
sub sample_hosts {
    return {
        'web-01' => { status => 'ok', scripts => [
            { name => 'check-disk', schema_version => '2',
              schema => {
                  description => 'Check disk usage',
                  read_only   => JSON::PP::true,
                  arguments   => { type => 'object',
                                   properties => { threshold => { type => 'integer' } },
                                   required   => ['threshold'] },
                  argv        => [ { arg => 'threshold' } ],
              } },
            { name => 'env-dump' },
        ] },
        'web-02' => { status => 'ok', scripts => [
            { name => 'check-disk', schema_version => '2',
              schema => { description => 'Check disk usage',
                          arguments => { type => 'object',
                                         properties => { threshold => { type => 'integer' } } } } },
        ] },
        'web-03' => { status => 'ok', scripts => [
            { name => 'check-disk', schema_version => 'sha256:abc123def456',
              schema => { description => 'Check disk (old)' } },
        ] },
        'down-01' => { status => 'error', error => 'unreachable' },
    };
}

sub catalog_for {
    my ($hosts) = @_;
    return CtrlExecMCP::Catalog->new(source => sub { $hosts });
}

sub by_name {
    my ($tools) = @_;
    return { map { $_->{name} => $_ } @$tools };
}

# --- versioned split + generic tool ---
{
    my $cat   = catalog_for(sample_hosts());
    my $tools = $cat->list_tools;
    my $t     = by_name($tools);

    ok $t->{'check-disk@2'},               'split tool check-disk@2 present';
    ok $t->{'check-disk@abc123def456'},    'derived-version suffix drops sha256: prefix';
    ok !$t->{'check-disk'},                'no bare check-disk tool while split';
    ok $t->{'env-dump'},                   'untyped script gets a bare tool';

    is_deeply $t->{'check-disk@2'}{inputSchema}{properties}{hosts}{items}{enum},
        ['web-01', 'web-02'], 'v2 hosts enum scoped to its hosts';
    ok exists $t->{'check-disk@2'}{inputSchema}{properties}{threshold},
        'typed argument exposed in inputSchema';
    is_deeply $t->{'check-disk@2'}{inputSchema}{required}, ['threshold'],
        'required args carried';
    ok $t->{'check-disk@2'}{annotations}{readOnlyHint}, 'read_only -> readOnlyHint';
    ok !$t->{'check-disk@2'}{annotations}{destructiveHint},
        'read_only implies not destructive';
    is $t->{'check-disk@2'}{description}, 'Check disk usage', 'description surfaced';
}

# --- generic (untyped) tool exposes a positional args array ---
{
    my $cat = catalog_for(sample_hosts());
    my $t   = by_name($cat->list_tools);
    my $ed  = $t->{'env-dump'}{inputSchema};
    is $ed->{properties}{args}{type}, 'array',        'generic tool has args array';
    is $ed->{properties}{args}{items}{type}, 'string','args are strings';
    ok exists $ed->{properties}{hosts},               'generic tool still has hosts';
    ok $t->{'env-dump'}{annotations}{destructiveHint},
        'untyped script defaults to destructive';
}

# --- has_tool / tool index for the runner ---
{
    my $cat = catalog_for(sample_hosts());
    $cat->list_tools;
    ok  $cat->has_tool('check-disk@2'),     'has_tool true for a real tool';
    ok !$cat->has_tool('check-disk'),       'has_tool false for the split bare name';
    ok !$cat->has_tool('nope'),             'has_tool false for unknown';

    my $idx = $cat->tool('check-disk@2');
    is $idx->{script}, 'check-disk',         'index maps back to the script';
    is_deeply $idx->{hosts}, ['web-01', 'web-02'], 'index carries the hosts';
    is $idx->{schema_version}, '2',          'index carries the version';
    is_deeply $idx->{argv}, [ { arg => 'threshold' } ], 'index carries the argv template';

    my $gen = $cat->tool('env-dump');
    ok !defined $gen->{argv}, 'generic tool has no argv template';
}

# --- homogeneous fleet -> bare tool name (no suffix) ---
{
    my $hosts = {
        'a' => { status => 'ok', scripts => [ { name => 'check-disk', schema_version => '2',
                   schema => { arguments => { type => 'object' } } } ] },
        'b' => { status => 'ok', scripts => [ { name => 'check-disk', schema_version => '2',
                   schema => { arguments => { type => 'object' } } } ] },
    };
    my $t = by_name(catalog_for($hosts)->list_tools);
    ok  $t->{'check-disk'},      'homogeneous version -> bare name';
    ok !$t->{'check-disk@2'},    'no suffix when not split';
    is_deeply $t->{'check-disk'}{inputSchema}{properties}{hosts}{items}{enum},
        ['a', 'b'], 'bare tool spans all hosts';
}

# --- refresh detects change ---
{
    my @datasets = ( sample_hosts() );
    my $cat = CtrlExecMCP::Catalog->new(source => sub { $datasets[0] });
    $cat->list_tools;                          # initial build

    is $cat->refresh, 0, 'refresh with unchanged data reports no change';

    # Add a new host running a new script -> the tool set changes.
    $datasets[0]{'web-04'} = { status => 'ok',
        scripts => [ { name => 'restart-svc' } ] };
    is $cat->refresh, 1, 'refresh after a fleet change reports a change';
    ok by_name($cat->list_tools)->{'restart-svc'}, 'new tool appears after refresh';
}

done_testing;
