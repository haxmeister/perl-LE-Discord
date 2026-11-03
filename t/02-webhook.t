use v5.36;
use Test::More;
use lib 'lib';
use LE::Discord::Webhook;

{
    package WebhookT::Response;
    use v5.36;
    sub new ($class, $status, $body, $headers) {
        bless { status => $status, body => $body, headers => $headers }, $class;
    }
    sub status ($self) { $self->{status} }
    sub body ($self) { $self->{body} }
    sub header ($self, $name) { $self->{headers}{lc $name} }
}
{
    package WebhookT::Op;
    use v5.36;
    sub cancel ($self) {
        return if $self->{done}++;
        $self->{args}{on_finish}->();
    }
}
{
    package WebhookT::HTTP;
    use v5.36;
    sub new ($class) { bless { calls => [], pending => [] }, $class }
    sub request ($self, %args) {
        push @{ $self->{calls} }, \%args;
        my $op = bless { args => \%args, done => 0 }, 'WebhookT::Op';
        push @{ $self->{pending} }, $op;
        return $op;
    }
    sub complete ($self, $status, $body, %headers) {
        my $op = shift @{ $self->{pending} };
        die 'missing pending HTTP request' unless $op;
        return if $op->{done}++;
        my %h = map { lc($_) => $headers{$_} } keys %headers;
        $op->{args}{on_response}->(undef, WebhookT::Response->new($status, $body, \%h));
        $op->{args}{on_finish}->();
    }
    sub fail ($self) {
        my $op = shift @{ $self->{pending} };
        die 'missing pending HTTP request' unless $op;
        return if $op->{done}++;
        $op->{args}{on_error}->(undef, 'simulated network error');
        $op->{args}{on_finish}->();
    }
}

my $id = '111111111111111111';
my $secret = 'fake-webhook-secret_AAA';
my $url = "https://discord.com/api/webhooks/$id/$secret";

sub fixture {
    my (%options) = @_;
    my $http = WebhookT::HTTP->new;
    my $now = 10;
    my @timers;
    my $webhook = LE::Discord::Webhook->new(
        loop => bless({}, 'WebhookT::Loop'),
        url => $url,
        http_client => $http,
        clock => sub { $now },
        schedule => sub ($delay, $callback) {
            my $t = { at => $now + $delay, callback => $callback, cancelled => 0 };
            push @timers, $t;
            return sub { $t->{cancelled} = 1 };
        },
        on_error => sub ($error) { die "unhandled: $error" },
        %options,
    );
    my $advance = sub ($seconds) {
        $now += $seconds;
        for my $t (@timers) {
            next if $t->{cancelled} || $t->{at} > $now;
            $t->{cancelled} = 1;
            $t->{callback}->();
        }
    };
    return ($webhook, $http, $advance);
}

{
    my ($w, $http) = fixture();
    my $message;
    my $op = $w->execute(
        json => { content => 'News', allowed_mentions => { parse => [] } },
        on_response => sub ($m) { $message = $m },
    );
    is($op->state, 'active', 'webhook execute returns active request');
    is($http->{calls}[0]{method}, 'POST', 'uses POST');
    is($http->{calls}[0]{url},
       "https://discord.com/api/v10/webhooks/$id/$secret?wait=true",
       'webhook URL resolved and requests confirmation');
    my %headers = map { lc($_->[0]) => $_->[1] } @{ $http->{calls}[0]{headers} };
    ok(!exists $headers{authorization}, 'no Bot authorization header');
    is($headers{'content-type'}, 'application/json', 'JSON header');
    like($http->{calls}[0]{body}, qr/"content":"News"/, 'JSON body');
    $http->complete(200, '{"id":"888888888888888888"}');
    is($message->{id}, '888888888888888888', 'webhook message returned');
    ok($op->is_terminal, 'request finished');
    $w->shutdown;
}

{
    my ($w, $http) = fixture();
    my $response = 'unset';
    $w->execute(
        json => { content => 'No wait' },
        query => { wait => 'false', thread_id => '222222222222222222' },
        on_response => sub ($v) { $response = $v },
    );
    is($http->{calls}[0]{url},
       "https://discord.com/api/v10/webhooks/$id/$secret?thread_id=222222222222222222&wait=false",
       'thread ID and optional wait parameter');
    $http->complete(204, '');
    ok(!defined $response, '204 returns undef');
    $w->shutdown;
}

{
    my ($w, $http, $advance) = fixture();
    my $second;
    $w->execute(json => { content => 'first' }, on_response => sub {});
    $w->execute(json => { content => 'second' },
        on_response => sub ($m) { $second = $m });
    is(scalar @{ $http->{calls} }, 1, 'requests are serialized');
    $http->complete(200, '{"id":"1"}',
        'X-RateLimit-Bucket' => 'webhook-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '2.5');
    is(scalar @{ $http->{calls} }, 1, 'exhausted bucket holds next send');
    $advance->(2);
    is(scalar @{ $http->{calls} }, 1, 'still waiting');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, 2, 'send proceeds at reset');
    $http->complete(200, '{"id":"2"}');
    is($second->{id}, '2', 'second send succeeds');
    $w->shutdown;
}

{
    my ($w, $http, $advance) = fixture();
    my $message;
    $w->execute(json => { content => '429 retry' },
        on_response => sub ($m) { $message = $m });
    $http->complete(429, '{"retry_after":1.25}',
        'Retry-After' => '1.25',
        'X-RateLimit-Scope' => 'shared');
    is(scalar @{ $http->{calls} }, 1, '429 does not immediately resend');
    $advance->(1);
    is(scalar @{ $http->{calls} }, 1, '429 retry delay respected');
    $advance->(0.25);
    is(scalar @{ $http->{calls} }, 2, 'retry after delay');
    $http->complete(200, '{"id":"3"}');
    is($message->{id}, '3', 'webhook retry completes');
    $w->shutdown;
}

{
    my ($w, $http) = fixture();
    my $error;
    $w->execute(json => { content => 'maybe received' },
        on_error => sub ($e) { $error = $e });
    $http->fail;
    is($error->kind, 'transport', 'transport error delivered');
    is(scalar @{ $http->{calls} }, 1, 'no resend on ambiguous transport error');
    $w->shutdown;
}

{
    my ($w, $http) = fixture(max_queue => 1);
    $w->execute(json => { content => 'first' }, on_response => sub {});
    my $queued = $w->execute(json => { content => 'second' }, on_response => sub {});
    is($queued->state, 'queued', 'second request queued');
    eval { $w->execute(json => { content => 'third' }, on_response => sub {}) };
    like($@, qr/REST request queue is full/, 'bounded backlog');
    $http->complete(200, '{"id":"1"}');
    $http->complete(200, '{"id":"2"}');
    $w->shutdown;
}

{
    my ($w, $http) = fixture();
    my ($a, $b);
    $w->execute(json => { content => 'first' }, on_error => sub ($e) { $a = $e });
    $w->execute(json => { content => 'second' }, on_error => sub ($e) { $b = $e });
    $w->shutdown;
    is($a->kind, 'cancelled', 'active request cancelled');
    is($b->kind, 'cancelled', 'queued request cancelled');
    is(scalar @{ $http->{calls} }, 1, 'shutdown does not send queued message');
}

{
    eval { LE::Discord::Webhook->new(
        loop => bless({}, 'WebhookT::Loop'),
        url => 'https://example.com/api/webhooks/123/secret',
    ) };
    like($@, qr/invalid Discord webhook URL/, 'rejects off-domain URL');
    eval { LE::Discord::Webhook->new(
        loop => bless({}, 'WebhookT::Loop'), url => "$url?wait=true",
    ) };
    like($@, qr/invalid Discord webhook URL/, 'rejects URL with query');
    unlike($@, qr/\Q$secret\E/, 'invalid URL error redacts token');
    eval { LE::Discord::Webhook->new(
        loop => bless({}, 'WebhookT::Loop'), url => $url, token => 'bot-token',
    ) };
    like($@, qr/do not pass bot credentials/, 'cannot mix auth modes');
}
{
    my ($w, $http) = fixture();
    my $error;
    $w->execute(json => { content => 'test' },
        on_error => sub ($e) { $error = $e });
    $http->complete(403, '{"message":"bad token: fake-webhook-secret_AAA"}');
    is($error->status, 403, 'HTTP failure propagated');
    unlike("$error", qr/\Q$secret\E/, 'Discord response redacts credential');
    like("$error", qr/\[REDACTED\]/, 'redaction marker present');
    $w->shutdown;
}


{
    my ($w, $http) = fixture();
    my ($first, $blocked);
    $w->execute(json => { content => 'invalid webhook' },
        on_error => sub ($e) { $first = $e });
    $w->execute(json => { content => 'must not send' },
        on_error => sub ($e) { $blocked = $e });
    $http->complete(404, '{"message":"Unknown Webhook"}');
    is($first->status, 404, 'invalid webhook reports original 404');
    is($blocked->kind, 'webhook', 'subsequent queued send fails closed');
    is(scalar @{ $http->{calls} }, 1, 'no repeated HTTP calls to invalid webhook');
    my $later;
    $w->execute(json => { content => 'after failure' },
        on_error => sub ($e) { $later = $e });
    is($later->kind, 'webhook', 'new sends fail closed on disabled sender');
    is(scalar @{ $http->{calls} }, 1, 'no invalid webhook retry storm');
    $w->shutdown;
}
done_testing();
