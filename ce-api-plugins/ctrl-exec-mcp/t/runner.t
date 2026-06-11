#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP ();

use CtrlExecMCP::Runner;

# A catalogue stub exposing tool descriptors.
{
    package FakeCatalog;
    sub new { bless { tools => $_[1] }, $_[0] }
    sub tool { $_[0]{tools}{ $_[1] } }
}

# A scripted API: records run() calls, and returns queued status() responses.
{
    package FakeApi;
    sub new {
        my ($class, %o) = @_;
        bless { run_resp => $o{run}, status_queue => $o{status} || [], runs => [] }, $class;
    }
    sub run {
        my ($self, %o) = @_;
        push @{ $self->{runs} }, \%o;
        return $self->{run_resp};
    }
    sub status {
        my ($self) = @_;
        my $next = shift @{ $self->{status_queue} };
        return $next // { ok => 1, data => { complete => JSON::PP::true, hosts => {} } };
    }
}

my $TYPED = {
    script => 'check-disk',
    hosts  => ['web-01', 'web-02'],
    argv   => [ { arg => 'threshold' } ],
    schema => { arguments => { properties => { threshold => { type => 'integer', default => 90 } } } },
};
my $GENERIC = { script => 'env-dump', hosts => ['web-01'], argv => undef, schema => undef };

sub runner {
    my (%o) = @_;
    return CtrlExecMCP::Runner->new(
        catalog => FakeCatalog->new($o{tools}),
        api     => $o{api},
        sleeper => sub { },      # no real sleeping
        now     => $o{now} // sub { 0 },
    );
}

my $ACCEPT = { ok => 1, status => 202, data => { reqid => 'r1' } };

# --- typed tool: renders argv, dispatches, polls running->done, shapes result ---
{
    my $api = FakeApi->new(
        run    => $ACCEPT,
        status => [
            { ok => 1, data => { complete => JSON::PP::false, hosts => { 'web-01' => { status => 'running' } } } },
            { ok => 1, data => { complete => JSON::PP::true, hosts => {
                'web-01' => { status => 'done', exit => 0, stdout => "disk ok\n", stderr => '' } } } },
        ],
    );
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => $api);
    my $res = $r->call('check-disk', { hosts => ['web-01'], threshold => 85 });

    is_deeply $api->{runs}[0]{hosts}, ['web-01'],   'explicit host subset used';
    is $api->{runs}[0]{script}, 'check-disk',       'script dispatched';
    is_deeply $api->{runs}[0]{args}, ['85'],        'argv rendered named arg -> positional';
    like $res->{content}[0]{text}, qr/disk ok/,     'stdout surfaced';
    like $res->{content}[0]{text}, qr/\[web-01\] done \(exit 0\)/, 'per-host status line';
    ok !$res->{isError},                            'success is not an error';
    is $res->{structuredContent}{reqid}, 'r1',      'structuredContent carries reqid';
}

# --- default host set when hosts omitted; default arg applied ---
{
    my $api = FakeApi->new(run => $ACCEPT, status => [
        { ok => 1, data => { complete => JSON::PP::true, hosts => {
            'web-01' => { status => 'done', exit => 0, stdout => '', stderr => '' },
            'web-02' => { status => 'done', exit => 0, stdout => '', stderr => '' } } } },
    ]);
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => $api);
    $r->call('check-disk', {});   # no hosts, no threshold
    is_deeply $api->{runs}[0]{hosts}, ['web-01', 'web-02'], 'defaults to all version hosts';
    is_deeply $api->{runs}[0]{args}, ['90'],                'argv default applied';
}

# --- host not in the tool's enum is rejected ---
{
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => FakeApi->new(run => $ACCEPT));
    eval { $r->call('check-disk', { hosts => ['evil-01'] }) };
    like $@, qr/hosts not available/, 'out-of-enum host rejected';
}

# --- generic tool: positional args passthrough ---
{
    my $api = FakeApi->new(run => $ACCEPT, status => [
        { ok => 1, data => { complete => JSON::PP::true, hosts => {
            'web-01' => { status => 'done', exit => 0, stdout => "x\n", stderr => '' } } } },
    ]);
    my $r = runner(tools => { 'env-dump' => $GENERIC }, api => $api);
    $r->call('env-dump', { args => ['-v', 'foo'] });
    is_deeply $api->{runs}[0]{args}, ['-v', 'foo'], 'generic args passed through';
}

# --- partial failure: one host ok keeps it a non-error result ---
{
    my $api = FakeApi->new(run => $ACCEPT, status => [
        { ok => 1, data => { complete => JSON::PP::true, hosts => {
            'web-01' => { status => 'done', exit => 0, stdout => '', stderr => '' },
            'web-02' => { status => 'done', exit => 3, stdout => '', stderr => 'failed' } } } },
    ]);
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => $api);
    my $res = $r->call('check-disk', {});
    ok !$res->{isError},                          'partial success is not a total error';
    like $res->{content}[0]{text}, qr/\[web-02\] done \(exit 3\)/, 'failing host shown';
}

# --- total failure: no host succeeded -> isError ---
{
    my $api = FakeApi->new(run => $ACCEPT, status => [
        { ok => 1, data => { complete => JSON::PP::true, hosts => {
            'web-01' => { status => 'error', error => 'unreachable' },
            'web-02' => { status => 'done', exit => 1 } } } },
    ]);
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => $api);
    my $res = $r->call('check-disk', {});
    ok $res->{isError}, 'no successful host -> isError';
}

# --- dispatch failure -> isError ---
{
    my $api = FakeApi->new(run => { ok => 0, status => 403, data => { error => 'forbidden' } });
    my $r = runner(tools => { 'check-disk' => $TYPED }, api => $api);
    my $res = $r->call('check-disk', {});
    ok $res->{isError},                       'dispatch failure -> isError';
    like $res->{content}[0]{text}, qr/forbidden/, 'dispatch error detail surfaced';
}

# --- timeout: never completes within the deadline -> isError ---
{
    my $t = 0;
    my $api = FakeApi->new(run => $ACCEPT, status => [
        { ok => 1, data => { complete => JSON::PP::false, hosts => { 'web-01' => { status => 'running' } } } },
    ]);
    # now() advances past the timeout after the first poll.
    my $r = CtrlExecMCP::Runner->new(
        catalog => FakeCatalog->new({ 'check-disk' => $TYPED }),
        api => $api, sleeper => sub { }, timeout => 5,
        now => sub { ($t += 10) - 10 },   # 0, then 10 (> deadline 5)
    );
    my $res = $r->call('check-disk', {});
    ok $res->{isError}, 'timeout -> isError';
    like $res->{content}[0]{text}, qr/incomplete/, 'timeout noted as incomplete';
}

# --- argv rendering variants ---
{
    no warnings 'once';
    my $render = \&CtrlExecMCP::Runner::_render_argv;
    is_deeply $render->([ 'backup', { arg => 'db' } ], { db => 'myapp' }, {}),
        ['backup', 'myapp'], 'literal + named value';
    is_deeply $render->([ { arg => 'force', flag => '--force' } ], { force => JSON::PP::true }, {}),
        ['--force'], 'boolean true -> flag emitted';
    is_deeply $render->([ { arg => 'force', flag => '--force' } ], { force => JSON::PP::false }, {}),
        [], 'boolean false -> flag omitted';
    is_deeply $render->([ { arg => 'level', flag => '--level' } ], { level => 3 }, {}),
        ['--level', '3'], 'non-boolean flag -> flag + value';
    is_deeply $render->([ { arg => 'paths', repeat => 1 } ], { paths => ['a', 'b'] }, {}),
        ['a', 'b'], 'repeat -> one token per element';
    is_deeply $render->([ { arg => 'missing' } ], {}, {}),
        [], 'absent optional arg omitted';
}

done_testing;
