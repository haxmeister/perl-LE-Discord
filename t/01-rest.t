use v5.36;
use Test::More;
use lib 'lib';
use LE::Discord;

{
    package T::Response;
    use v5.36;
    sub new ($class, $status, $body, $headers) {
        bless { status => $status, body => $body, headers => $headers }, $class;
    }
    sub status ($self) { $self->{status} }
    sub body ($self) { $self->{body} }
    sub header ($self, $key) { $self->{headers}{lc $key} }
}
{
    package T::Operation;
    use v5.36;
    sub cancel ($self) {
        return if $self->{done}++;
        $self->{on_finish}->();
    }
}
{
    package T::HTTP;
    use v5.36;
    sub new ($class) { bless { calls => [], pending => [] }, $class }
    sub request ($self, %args) {
        push @{ $self->{calls} }, \%args;
        my $op = bless {
            on_finish => $args{on_finish},
            options => \%args,
            done => 0,
        }, 'T::Operation';
        push @{ $self->{pending} }, $op;
        return $op;
    }
    sub complete ($self, $status, $body, %headers) {
        my $op = shift @{ $self->{pending} };
        die 'expected pending request' unless $op;
        return if $op->{done}++;
        my %h = map { lc($_) => $headers{$_} } keys %headers;
        $op->{options}{on_response}->(undef,
            T::Response->new($status, $body, \%h));
        $op->{on_finish}->();
    }
    sub fail ($self) {
        my $op = shift @{ $self->{pending} };
        die 'expected pending request' unless $op;
        return if $op->{done}++;
        $op->{options}{on_error}->(undef, 'fake broken connection');
        $op->{on_finish}->();
    }
}
sub fixture {
    my $http = T::HTTP->new;
    my $now = 10;
    my @timers;
    my $client = LE::Discord->new(
        loop => bless({}, 'T::Loop'),
        token => 'test-only-token',
        http_client => $http,
        clock => sub { $now },
        schedule => sub ($delay, $callback) {
            my $timer = { at => $now + $delay, callback => $callback, canceled => 0 };
            push @timers, $timer;
            return sub { $timer->{canceled} = 1 };
        },
        on_error => sub ($error) { die "unexpected error: $error" },
    );
    my $advance = sub ($seconds) {
        $now += $seconds;
        for my $timer (@timers) {
            next if $timer->{canceled} || $timer->{at} > $now;
            $timer->{canceled} = 1;
            $timer->{callback}->();
        }
    };
    return ($client, $http, $advance);
}

{
    my ($d, $http) = fixture();
    my ($message, $error);
    my $op = $d->rest->post(
        '/channels/{channel.id}/messages',
        'channel.id' => '123456789012345678',
        json => { content => 'Hello' },
        on_response => sub ($result) { $message = $result },
        on_error => sub ($err) { $error = $err },
    );
    is($op->state, 'active', 'returns an active request handle');
    is($http->{calls}[0]{url},
        'https://discord.com/api/v10/channels/123456789012345678/messages',
        'route template expanded');
    my %headers = map { lc($_->[0]) => $_->[1] } @{ $http->{calls}[0]{headers} };
    is($headers{authorization}, 'Bot test-only-token', 'Bot authorization attached');
    like($http->{calls}[0]{body}, qr/"content":"Hello"/, 'JSON encoded');
    $http->complete(201, '{"id":"999"}');
    is($message->{id}, '999', 'decoded response delivered');
    ok(!$error, 'no success error');
    ok($op->is_terminal, 'handle terminates');
}
{
    my ($d, $http) = fixture();
    my $result = 1;
    $d->rest->get(
        '/channels/{channel.id}/messages/{message.id}',
        'channel.id' => 12, 'message.id' => 34,
        query => { limit => 3, before => 'a b' },
        on_response => sub ($data) { $result = $data },
    );
    is($http->{calls}[0]{url},
        'https://discord.com/api/v10/channels/12/messages/34?before=a%20b&limit=3',
        'multiple placeholders and query encoding');
    $http->complete(204, '');
    ok(!defined $result, 'empty HTTP response becomes undef');
    eval { $d->rest->get('/channels/{channel.id}', on_error => sub {}) };
    like($@, qr/missing route parameter channel.id/, 'missing placeholder rejected');
}
{
    my ($d, $http) = fixture();
    my $error;
    $d->rest->get('/users/@me', on_error => sub ($err) { $error = $err });
    $http->complete(403, '{"message":"Missing Access"}');
    is($error->kind, 'http', '403 becomes HTTP error');
    is($error->status, 403, 'HTTP error retains status');
}
{
    my ($d, $http) = fixture();
    my $error;
    $d->rest->get('/users/@me', on_error => sub ($err) { $error = $err });
    $http->complete(200, '{broken-json');
    is($error->kind, 'json', 'malformed JSON detected');
}
{
    my ($d, $http) = fixture();
    my $error;
    $d->rest->post('/channels/{channel.id}/messages',
        'channel.id' => 12, json => { content => 'possibly received' },
        on_error => sub ($err) { $error = $err });
    $http->fail;
    is($error->kind, 'transport', 'transport failure reported');
    is(scalar @{ $http->{calls} }, 1, 'no retry on ambiguous transport failure');
}
{
    my ($d, $http, $advance) = fixture();
    my $result;
    $d->rest->get('/users/@me', on_response => sub ($data) { $result = $data });
    $http->complete(429, '{"retry_after":1.5,"global":true}',
        'X-RateLimit-Scope' => 'global', 'Retry-After' => '1.5');
    is(scalar @{ $http->{calls} }, 1, '429 does not retry immediately');
    $advance->(1);
    is(scalar @{ $http->{calls} }, 1, 'retry waits for deadline');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, 2, 'retry runs after deadline');
    $http->complete(200, '{"id":"42"}');
    is($result->{id}, '42', '429 retry eventually succeeds');
}
{
    my ($d, $http) = fixture();
    my $second;
    $d->rest->get('/users/@me', on_response => sub {});
    my $pending = $d->rest->get('/channels/{channel.id}',
        'channel.id' => 17, on_response => sub ($v) { $second = $v });
    is($pending->state, 'queued', 'second request queues');
    is(scalar @{ $http->{calls} }, 1, 'scheduler has one in-flight request');
    $http->complete(200, '{"id":"1"}');
    is(scalar @{ $http->{calls} }, 2, 'queue advances after completion');
    $http->complete(200, '{"id":"2"}');
    is($second->{id}, '2', 'next response delivered');
}
{
    my ($d, $http) = fixture();
    my $error;
    $d->rest->get('/users/@me', on_response => sub {});
    my $pending = $d->rest->get('/channels/{channel.id}',
        'channel.id' => 17, on_error => sub ($err) { $error = $err });
    $pending->cancel;
    $http->complete(200, '{"id":"1"}');
    is($error->kind, 'cancelled', 'cancelled queued request gets error');
    is(scalar @{ $http->{calls} }, 1, 'cancelled queued request never sent');
}
{
    my ($d, $http) = fixture();
    my ($auth_error, $blocked);
    $d->rest->get('/users/@me', on_error => sub ($err) { $auth_error = $err });
    $d->rest->get('/users/@me', on_error => sub ($err) { $blocked = $err });
    $http->complete(401, '{"message":"Unauthorized"}');
    is($auth_error->status, 401, '401 returned');
    is($blocked->kind, 'authentication', 'queued requests fail closed after 401');
    is(scalar @{ $http->{calls} }, 1, '401 prevents subsequent dispatch');
}


{
    my ($d, $http, $advance) = fixture();
    $d->rest->get('/users/@me', on_response => sub {});
    $d->rest->get('/users/@me', on_response => sub {});
    $http->complete(200, '{"id":"1"}',
        'X-RateLimit-Bucket' => 'sample-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '2.0');
    is(scalar @{ $http->{calls} }, 1, 'empty bucket delays next request');
    $advance->(1.5);
    is(scalar @{ $http->{calls} }, 1, 'bucket still blocked before reset');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, 2, 'bucket resumes at reset');
    $http->complete(200, '{"id":"2"}');
}
{
    my ($d, $http) = fixture();
    my $error;
    my $op = $d->rest->get('/users/@me',
        on_error => sub ($err) { $error = $err });
    $op->cancel;
    is($error->kind, 'cancelled', 'active cancellation delivered');
    ok($op->is_terminal, 'cancelled active operation terminates');
}
{
    my ($d, $http) = fixture();
    $d->rest->put('/channels/{channel.id}/messages/{message.id}/reactions/{emoji.id}/@me',
        'channel.id' => 111, 'message.id' => 222, 'emoji.id' => 'name:333',
        on_response => sub {});
    like($http->{calls}[0]{url}, qr{/reactions/name%3A333/\@me\z},
        'path values are URL-encoded individually');
    $http->complete(204, '');
}


{
    my ($d, $http) = fixture();
    my ($error, $count);
    $d->rest->get('/users/@me', on_response => sub { $count++ });
    my $pending = $d->rest->get('/channels/{channel.id}',
        'channel.id' => 19, on_error => sub ($e) { $error = $e });
    $pending->cancel;
    is($error->kind, 'cancelled', 'queued cancel completes immediately, even with active request');
    ok($pending->is_terminal, 'cancelled queued handle is already terminal');
    is(scalar @{ $http->{calls} }, 1, 'cancelled queued request never starts');
    $http->complete(200, '{"id":"123"}');
    is($count, 1, 'earlier active request still completes normally');
    is(scalar @{ $http->{calls} }, 1, 'no extra request after cancellation');
}
{
    my ($d, $http, $advance) = fixture();
    my ($error, $second);
    $d->rest->get('/users/@me', on_error => sub ($e) { $error = $e });
    $d->rest->get('/users/@me', on_response => sub ($v) { $second = $v });
    for my $attempt (1..3) {
        $http->complete(429, '{"retry_after":1,"global":true}',
            'Retry-After' => '1',
            'X-RateLimit-Scope' => 'global');
        is(scalar @{ $http->{calls} }, $attempt,
            "429 attempt $attempt does not dispatch the next request immediately");
        if ($attempt < 3) {
            $advance->(1);
            is(scalar @{ $http->{calls} }, $attempt + 1, 'bounded retry dispatched after one second');
        }
    }
    is($error->status, 429, 'third 429 finishes original request with an error');
    is(scalar @{ $http->{calls} }, 3, 'exhausted retry still holds queued work');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, 3, 'remaining global delay respected');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, 4, 'next request starts only after global delay');
    $http->complete(200, '{"id":"after-limit"}');
    is($second->{id}, 'after-limit', 'subsequent queued request succeeds');
}


{
    my ($d, $http, $advance) = fixture();
    # Different methods can share a Discord-assigned bucket. The route
    # templates must be retained until the server teaches us that mapping.
    $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 111, on_response => sub {});
    $http->complete(200, '[]',
        'X-RateLimit-Bucket' => 'shared-method-bucket',
        'X-RateLimit-Remaining' => '1');
    $d->rest->post('/channels/{channel.id}/messages',
        'channel.id' => 111,
        json => { content => 'hello' }, on_response => sub {});
    $http->complete(201, '{"id":"42"}',
        'X-RateLimit-Bucket' => 'shared-method-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '3');
    my $count = scalar @{ $http->{calls} };
    $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 111, on_response => sub {});
    is(scalar @{ $http->{calls} }, $count,
        'learned shared bucket blocks a different method');
    $advance->(3);
    is(scalar @{ $http->{calls} }, $count + 1,
        'shared bucket permits request at reset');
    $http->complete(200, '[]');
}
{
    my ($d, $http) = fixture();
    $d->rest->post('/channels/{channel.id}/messages',
        'channel.id' => 111,
        json => { content => 'one' }, on_response => sub {});
    $http->complete(201, '{"id":"1"}',
        'X-RateLimit-Bucket' => 'per-channel-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '30');
    my $count = scalar @{ $http->{calls} };
    $d->rest->post('/channels/{channel.id}/messages',
        'channel.id' => 222,
        json => { content => 'two' }, on_response => sub {});
    is(scalar @{ $http->{calls} }, $count + 1,
        'exhausting one channel does not block another major resource');
    $http->complete(201, '{"id":"2"}');
}


{
    my ($d, $http, $advance) = fixture();
    $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 111, on_response => sub {});
    $http->complete(200, '[]',
        'X-RateLimit-Bucket' => 'same-route-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '10');
    $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 222, on_response => sub {});
    $http->complete(200, '[]',
        'X-RateLimit-Bucket' => 'same-route-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '2');

    my $cancelled;
    my $first = $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 111,
        on_response => sub {},
        on_error => sub ($error) { $cancelled = $error });
    my $second = $d->rest->get('/channels/{channel.id}/messages',
        'channel.id' => 222, on_response => sub {});
    is($second->state, 'queued', 'second blocked request is queued');
    $first->cancel;
    is($cancelled->kind, 'cancelled', 'expected queued cancellation is handled');
    ok($first->is_terminal, 'first blocked request cancels immediately');
    my $before = scalar @{ $http->{calls} };
    $advance->(1.5);
    is(scalar @{ $http->{calls} }, $before, 'new head still waits before its reset');
    $advance->(0.5);
    is(scalar @{ $http->{calls} }, $before + 1,
        'cancel changes queue head and reschedules earlier timer');
    $http->complete(200, '[]');
}


{
    my ($d, $http) = fixture();
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $d->rest->get('/users/@me',
        on_response => sub ($result) { die "failed on purpose: test-only-token"; });
    $http->complete(200, '{"id":"123"}');
    is(scalar @warnings, 1, 'a callback exception is reported once');
    like($warnings[0], qr/LE::Discord callback failed: failed on purpose:/,
        'the original callback error is visible');
    unlike($warnings[0], qr/test-only-token/,
        'bot token is redacted from callback exceptions');
    like($warnings[0], qr/\[REDACTED\]/, 'redaction marker is present');
}


{
    my ($d, $http) = fixture();
    my ($active_error, $queued_error);
    my $active = $d->rest->post('/channels/{channel.id}/messages',
        'channel.id' => 111, json => { content => 'drop me' },
        on_error => sub ($e) { $active_error = $e });
    my $queued = $d->rest->get('/users/@me',
        on_error => sub ($e) { $queued_error = $e });
    my $rest = $d->rest;
    is($active->state, 'active', 'active request before shutdown');
    is($queued->state, 'queued', 'queued request before shutdown');
    $rest->shutdown;
    is($active_error->kind, 'cancelled', 'shutdown cancels active request');
    is($queued_error->kind, 'cancelled', 'shutdown cancels queued request');
    ok($active->is_terminal && $queued->is_terminal,
        'both requests terminal after synchronous fake cancellation');
    is(scalar @{ $http->{calls} }, 1, 'shutdown does not send queued request');
    is(scalar @{ $rest->{queue} }, 0, 'shutdown clears pending queue');
    ok(!defined $active->{rest} && !defined $queued->{rest},
        'terminal handles detach REST ownership');
    ok(!exists $active->{body}, 'terminal request releases JSON body');
    $rest->shutdown;
    eval { $rest->get('/users/@me') };
    like($@, qr/REST client is shut down/, 'no new work after shutdown');
}
{
    my ($d, $http, $advance) = fixture();
    my $error;
    $d->rest->get('/users/@me', on_response => sub {});
    $http->complete(200, '{"id":"123"}',
        'X-RateLimit-Bucket' => 'stop-bucket',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset-After' => '20');
    my $pending = $d->rest->get('/users/@me',
        on_error => sub ($e) { $error = $e });
    ok(defined $d->rest->{wake}, 'blocked request has wakeup timer');
    $d->rest->shutdown;
    is($error->kind, 'cancelled', 'shutdown cancels blocked request');
    ok(!defined $d->rest->{wake}, 'shutdown clears wakeup timer');
    $advance->(30);
    is(scalar @{ $http->{calls} }, 1, 'cancelled timer never dispatches request');
    ok($pending->is_terminal, 'blocked request terminal');
}


{
    package T::DelayedCancelOperation;
    use v5.36;
    sub cancel ($self) { $self->{cancel_requested} = 1 }
}
{
    my ($d, $http) = fixture();
    my ($error, $success);
    my $request = $d->rest->get('/users/@me',
        on_response => sub { $success++ },
        on_error => sub ($e) { $error = $e });
    bless $http->{pending}[0], 'T::DelayedCancelOperation';
    $request->cancel;
    is($request->state, 'active',
        'cancelled request remains active until delayed HTTP finish');
    $http->complete(200, '{"id":"delayed"}');
    is($error->kind, 'cancelled', 'late HTTP response cannot override cancellation');
    ok(!$success, 'cancelled operation never delivers success');
    ok($request->is_terminal, 'delayed cancellation eventually terminates');
}
{
    my ($d, $http) = fixture();
    my $error;
    {
        no warnings 'redefine';
        local *T::HTTP::request = sub { die "fake request construction error"; };
        my $req = $d->rest->get('/users/@me',
            on_error => sub ($e) { $error = $e });
        is($error->kind, 'transport', 'synchronous HTTP startup error is delivered');
        ok($req->is_terminal, 'HTTP startup failure terminates request');
        ok(!defined $d->rest->{active}, 'startup failure frees active slot');
    }
}

done_testing();
