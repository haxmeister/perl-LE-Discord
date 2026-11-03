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

# Credential-scoped webhook and message management, no Bot auth header.
{
    my ($w, $http) = fixture();
    my $details;
    my $req = $w->get('', on_response => sub ($data) { $details = $data });
    is($req->state, 'active', 'inspect webhook returns operation');
    is($http->{calls}[0]{method}, 'GET', 'inspect webhook sends GET');
    is($http->{calls}[0]{url},
        "https://discord.com/api/v10/webhooks/$id/$secret",
        'inspect webhook uses webhook-token route');
    my %h = map { lc($_->[0]) => $_->[1] } @{ $http->{calls}[0]{headers} };
    ok(!exists $h{authorization}, 'no bot auth for webhook inspect');
    $http->complete(200, '{"id":"111111111111111111","name":"Announcements"}');
    is($details->{name}, 'Announcements', 'inspect metadata decoded');

    my $updated;
    $w->patch('',
        json => { name => 'Announcements 2' },
        on_response => sub ($data) { $updated = $data });
    is($http->{calls}[1]{method}, 'PATCH', 'token can edit own webhook');
    like($http->{calls}[1]{body}, qr/"name":"Announcements 2"/,
        'metadata patch JSON encoded');
    $http->complete(200, '{"name":"Announcements 2"}');
    is($updated->{name}, 'Announcements 2', 'metadata updated');

    my $deleted = 'not yet';
    $w->delete('', on_response => sub ($data) { $deleted = $data });
    is($http->{calls}[2]{method}, 'DELETE', 'token can delete own webhook');
    $http->complete(204, '');
    ok(!defined $deleted, 'deleting webhook yields no body');
    $w->shutdown;
}
{
    my ($w, $http) = fixture();
    my $message;
    $w->get('/messages/{message.id}',
        'message.id' => '222222222222222222',
        query => { thread_id => '333333333333333333' },
        on_response => sub ($data) { $message = $data });
    is($http->{calls}[0]{url},
        "https://discord.com/api/v10/webhooks/$id/$secret/messages/222222222222222222?thread_id=333333333333333333",
        'get own message supports thread_id');
    $http->complete(200, '{"id":"222222222222222222","content":"Before"}');
    is($message->{content}, 'Before', 'message fetched');

    my $edited;
    $w->patch('/messages/{message.id}',
        'message.id' => '222222222222222222',
        json => {
            content => 'After',
            allowed_mentions => { parse => [] },
        },
        on_response => sub ($data) { $edited = $data });
    is($http->{calls}[1]{method}, 'PATCH', 'edit own message uses PATCH');
    like($http->{calls}[1]{body}, qr/"content":"After"/, 'edit content encoded');
    like($http->{calls}[1]{body}, qr/"allowed_mentions":\{"parse":\[\]\}/,
        'allowed_mentions retained in edit');
    $http->complete(200, '{"id":"222222222222222222","content":"After"}');
    is($edited->{content}, 'After', 'message edit returned');

    my $deleted = 'not yet';
    $w->delete('/messages/{message.id}',
        'message.id' => '222222222222222222',
        on_response => sub ($data) { $deleted = $data });
    is($http->{calls}[2]{method}, 'DELETE', 'delete own message uses DELETE');
    $http->complete(204, '');
    ok(!defined $deleted, 'delete message returns no response body');
    $w->shutdown;
}
{
    my ($w, $http) = fixture();
    eval { $w->get('/channels/{channel.id}', 'channel.id' => '5') };
    like($@, qr/invalid webhook-token route/,
        'token sender cannot access unrelated API routes');
    eval { $w->get('/messages/5') };
    like($@, qr/invalid webhook-token route/,
        'token message route requires documented template');
    eval { $w->get('', 'webhook.token' => 'wrong') };
    like($@, qr/webhook credentials cannot be overridden/,
        'cannot substitute webhook token through route arguments');
    eval { $w->execute(
        json => { content => 'Hello' },
        'webhook.token' => 'wrong',
    ) };
    like($@, qr/webhook credentials cannot be overridden/,
        'execute cannot override webhook token');
    is(scalar @{ $http->{calls} }, 0,
        'invalid operations rejected before HTTP dispatch');
    $w->shutdown;
}
{
    my ($w, $http) = fixture();
    my ($missing, $sent);
    $w->get('/messages/{message.id}', 'message.id' => 'not-found',
        on_error => sub ($e) { $missing = $e });
    $http->complete(404, '{"message":"Unknown Message"}');
    is($missing->status, 404, 'missing message returns 404');
    $w->execute(json => { content => 'Webhook still works' },
        on_response => sub ($data) { $sent = $data });
    is(scalar @{ $http->{calls} }, 2,
        'missing message does not disable otherwise valid webhook');
    $http->complete(200, '{"id":"new-message"}');
    is($sent->{id}, 'new-message', 'webhook send still succeeds after message 404');
    $w->shutdown;
}

done_testing();
