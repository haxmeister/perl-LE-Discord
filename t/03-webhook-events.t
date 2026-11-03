use v5.36;
use Test::More;
use lib 'lib';
use Crypt::PK::Ed25519;
use LE::Discord::Webhook::Events;

{
    package EventTest::Loop;
    use v5.36;
    sub new ($class) { bless { queue => [] }, $class }
    sub defer ($self, $cb) { push @{ $self->{queue} }, $cb; return 1 }
    sub flush ($self) { $_->() for splice @{ $self->{queue} } }
}
{
    package EventTest::Request;
    use v5.36;
    sub new ($class, %args) { bless \%args, $class }
    sub target ($self) { $self->{path} }
    sub method ($self) { $self->{method} }
    sub body ($self) { $self->{body} }
    sub header ($self, $name) { $self->{headers}{lc $name} }
}
{
    package EventTest::Tx;
    use v5.36;
    sub new ($class) { bless {}, $class }
    sub respond ($self, %args) {
        ++$self->{count};
        $self->{status} = $args{status};
        $self->{body} = $args{body};
    }
}

my $signer = Crypt::PK::Ed25519->new->generate_key;
my $key = unpack('H*', $signer->export_key_raw('public'));
my $app_id = '123456789012345678';
my $timestamp = '1793660000';
sub request {
    my (%opt) = @_;
    my $body = exists($opt{body}) ? $opt{body}
        : '{"version":1,"application_id":"123456789012345678","type":0}';
    my $ts = $opt{timestamp} // $timestamp;
    my $sig = unpack('H*', $signer->sign_message($ts.$body));
    $sig = $opt{signature} if exists $opt{signature};
    my %headers = (
        'x-signature-ed25519' => $sig,
        'x-signature-timestamp' => $ts,
    );
    delete $headers{'x-signature-ed25519'} if $opt{missing_signature};
    delete $headers{'x-signature-timestamp'} if $opt{missing_timestamp};
    return EventTest::Request->new(
        method => $opt{method} // 'POST',
        path => $opt{path} // '/discord/events',
        body => $body, headers => \%headers,
    );
}
sub fixture {
    my (%opts) = @_;
    my $loop = EventTest::Loop->new;
    my @seen;
    my $receiver = LE::Discord::Webhook::Events->new(
        loop => $loop,
        public_key => $key,
        application_id => $app_id,
        on_event => sub ($event, $outer) { push @seen, [$event, $outer] },
        %opts,
    );
    return ($receiver, $loop, \@seen);
}
sub send_to {
    my ($receiver, $request) = @_;
    my $tx = EventTest::Tx->new;
    $receiver->handle($tx, $request);
    return $tx;
}

{
    my ($receiver, $loop, $seen) = fixture();
    my $tx = send_to($receiver, request());
    is($tx->{status}, 204, 'signed webhook PING acknowledged');
    is($tx->{body}, '', '204 response has empty body');
    is($tx->{count}, 1, 'PING answered once');
    is(scalar @{$loop->{queue}}, 0, 'PING does not enqueue callback');
    is(scalar @$seen, 0, 'PING never forwarded as event');
}
{
    my ($receiver, $loop, $seen) = fixture();
    my $body = '{"version":1,"application_id":"123456789012345678","type":1,"event":{"type":"APPLICATION_AUTHORIZED","timestamp":"2026-11-02T00:00:00Z","data":{"user":{"id":"987654321987654321"}}}}';
    my $tx = send_to($receiver, request(body => $body));
    is($tx->{status}, 204, 'signed event acknowledged');
    is(scalar @$seen, 0, 'user callback deferred until after ACK');
    is(scalar @{$loop->{queue}}, 1, 'event callback scheduled');
    $loop->flush;
    is($seen->[0][0]{type}, 'APPLICATION_AUTHORIZED', 'inner event delivered');
    is($seen->[0][0]{data}{user}{id}, '987654321987654321',
       'Snowflake preserved as string');
    is($seen->[0][1]{application_id}, $app_id, 'outer payload delivered');
}
{
    my ($receiver, $loop, $seen) = fixture();
    my $r = request();
    substr($r->{body}, 2, 1) = 'X';
    is(send_to($receiver, $r)->{status}, 401, 'tampering with body rejected');
    is(send_to($receiver, request(signature => ('00' x 64)))->{status}, 401,
       'invalid signature rejected');
    is(send_to($receiver, request(missing_signature => 1))->{status}, 401,
       'missing signature rejected');
    is(send_to($receiver, request(missing_timestamp => 1))->{status}, 401,
       'missing timestamp rejected');
    my $r2 = request();
    $r2->{headers}{'x-signature-timestamp'} = '1793661111';
    is(send_to($receiver, $r2)->{status}, 401, 'timestamp tampering rejected');
    is(scalar @{$loop->{queue}}, 0, 'bad signatures dispatch nothing');
}
{
    my ($receiver, $loop, $seen) = fixture();
    is(send_to($receiver, request(method => 'GET'))->{status}, 405,
       'only POST accepted');
    is(send_to($receiver, request(path => '/other'))->{status}, 404,
       'unrelated path rejected');
    is(send_to($receiver, request(body => '{broken'))->{status}, 400,
       'signed malformed JSON rejected');
    is(send_to($receiver, request(body => '[]'))->{status}, 400,
       'signed JSON array rejected');
    is(send_to($receiver, request(body => '{"type":1,"application_id":"123456789012345678"}'))->{status},
       400, 'event object is required');
    is(send_to($receiver, request(body => '{"type":0,"application_id":"999"}'))->{status},
       400, 'unexpected application ID rejected');
    is(send_to($receiver, request(body => '{"type":9,"application_id":"123456789012345678"}'))->{status},
       400, 'unknown envelope type rejected');
    is(scalar @{$loop->{queue}}, 0, 'invalid envelopes never dispatched');
}
{
    my ($receiver) = fixture(max_body_bytes => 4);
    is(send_to($receiver, request())->{status}, 400, 'receiver body limit enforced');
}
{
    my $failures = 0;
    my ($receiver, $loop) = fixture(
        on_event => sub { die "sensitive application error\n" },
        on_error => sub ($message) {
            is($message, 'Discord webhook event callback failed',
               'callback error is redacted');
            ++$failures;
        },
    );
    my $body = '{"type":1,"application_id":"123456789012345678","event":{"type":"TEST"}}';
    is(send_to($receiver, request(body => $body))->{status}, 204,
       'handler error does not block acknowledgement');
    $loop->flush;
    is($failures, 1, 'handler failure reported asynchronously');
}
{
    eval { LE::Discord::Webhook::Events->new(
        loop => EventTest::Loop->new, public_key => 'bad', on_event => sub {},
    ) };
    like($@, qr/public_key must be 64 hexadecimal/, 'invalid public key rejected');
    eval { LE::Discord::Webhook::Events->new(
        loop => EventTest::Loop->new, public_key => $key,
    ) };
    like($@, qr/on_event callback is required/, 'callback required');
}

done_testing();
