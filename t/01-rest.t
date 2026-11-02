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

done_testing();
