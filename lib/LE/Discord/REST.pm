package LE::Discord::REST;
use v5.36;
use Carp qw(croak);
use JSON::PP ();
use URI::Escape qw(uri_escape_utf8);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use LE::Discord::Error;
use LE::Discord::REST::Request;

our $VERSION = '0.001';

my %REQUEST_OPTION = map { $_ => 1 } qw(json query timeout on_response on_error);
my $JSON = JSON::PP->new->utf8->allow_nonref;
my $BASE = 'https://discord.com/api/v10';

sub new ($class, %args) {
    my $loop = delete $args{loop};
    my $token = delete $args{token} // croak 'token is required';
    croak 'token must not be empty' unless length $token;
    my $http = delete $args{http_client};
    my $clock = delete($args{clock}) // sub { clock_gettime(CLOCK_MONOTONIC) };
    my $schedule = delete $args{schedule};
    my $on_error = delete $args{on_error};
    croak 'unknown REST constructor options: ' . join(', ', sort keys %args) if %args;
    if (!$http) {
        croak 'loop is required' unless $loop;
        require Linux::Event::HTTP::Client;
        $http = Linux::Event::HTTP::Client->new(loop => $loop);
    }
    if (!$schedule) {
        croak 'loop is required' unless $loop;
        $schedule = sub ($delay, $callback) {
            require Linux::Event::Kernel::Timer;
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $loop, after => $delay,
                on_timer => sub ($timer) { $callback->() },
            );
            return sub { $timer->cancel };
        };
    }
    return bless {
        http => $http, token => $token, clock => $clock,
        schedule => $schedule, on_error => $on_error,
        queue => [], active => undef, wake => undef, disabled => 0,
        routes => {}, blocked_until => {}, global_until => 0,
        dispatched => [],
    }, $class;
}

sub get    ($self, $route, %args) { $self->request('GET',    $route, %args) }
sub post   ($self, $route, %args) { $self->request('POST',   $route, %args) }
sub put    ($self, $route, %args) { $self->request('PUT',    $route, %args) }
sub patch  ($self, $route, %args) { $self->request('PATCH',  $route, %args) }
sub delete ($self, $route, %args) { $self->request('DELETE', $route, %args) }

sub request ($self, $method, $route, %args) {
    croak 'invalid HTTP method' unless $method =~ /\A(?:GET|POST|PUT|PATCH|DELETE)\z/;
    croak 'route must be an absolute API path without query or fragment'
        unless defined($route) && $route =~ m{\A/} && $route !~ /[?#]/;
    my @names = ($route =~ /\{([A-Za-z][A-Za-z0-9_.]*)\}/g);
    my %values;
    for my $name (@names) {
        croak "missing route parameter $name" unless exists $args{$name};
        my $value = delete $args{$name};
        croak "route parameter $name must be a scalar"
            if !defined($value) || ref($value);
        $values{$name} = "$value";
    }
    croak 'malformed route template' if $route =~ /[{}]/ && $route !~ /\{[A-Za-z][A-Za-z0-9_.]*\}/;
    my $path = $route;
    $path =~ s/\{([A-Za-z][A-Za-z0-9_.]*)\}/uri_escape_utf8($values{$1})/ge;
    croak 'unexpanded route placeholder' if $path =~ /[{}]/;
    my $query = delete $args{query};
    if (defined $query) {
        croak 'query must be a hash reference' unless ref($query) eq 'HASH';
        my @parts;
        for my $key (sort keys %$query) {
            next unless defined $query->{$key};
            croak "query value $key must be scalar" if ref($query->{$key});
            push @parts, uri_escape_utf8($key) . '=' . uri_escape_utf8("$query->{$key}");
        }
        $path .= '?' . join('&', @parts) if @parts;
    }
    my $body;
    if (exists $args{json}) {
        my $data = delete $args{json};
        croak 'json must be a hash or array reference'
            unless ref($data) eq 'HASH' || ref($data) eq 'ARRAY';
        $body = $JSON->encode($data);
    }
    for my $key (keys %args) {
        croak "unknown request argument $key" unless $REQUEST_OPTION{$key};
    }
    my $on_response = delete $args{on_response};
    my $on_error = delete $args{on_error};
    croak 'on_response must be a callback' if defined($on_response) && ref($on_response) ne 'CODE';
    croak 'on_error must be a callback' if defined($on_error) && ref($on_error) ne 'CODE';
    my $timeout = delete($args{timeout}) // 15;
    croak 'timeout must be a positive number'
        unless $timeout =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ && $timeout > 0;
    my $major = _major($route, \%values);
    my $req = bless {
        rest => $self, state => 'queued', cancelled => 0,
        method => $method, route => $route,
        route_key => "$method $route", major => $major,
        url => $BASE . $path, body => $body, timeout => $timeout,
        on_response => $on_response, on_error => $on_error,
        attempts => 0,
    }, 'LE::Discord::REST::Request';
    push @{ $self->{queue} }, $req;
    $self->_pump;
    return $req;
}

sub _major ($route, $values) {
    return 'channel:' . $values->{'channel.id'}
        if $route =~ m{\A/channels/\{channel\.id\}(?:/|\z)};
    return 'guild:' . $values->{'guild.id'}
        if $route =~ m{\A/guilds/\{guild\.id\}(?:/|\z)};
    if ($route =~ m{\A/webhooks/\{webhook\.id\}(?:/|\z)}) {
        return 'webhook:' . $values->{'webhook.id'}
            . (exists $values->{'webhook.token'} ? ':' . $values->{'webhook.token'} : '');
    }
    return 'other';
}

sub _bucket_key ($self, $req) {
    my $id = $self->{routes}{ $req->{route_key} };
    return (defined($id) ? "bucket:$id" : "route:$req->{route_key}")
        . "\0" . $req->{major};
}

sub _delay ($self, $req, $now) {
    my $until = $self->{blocked_until}{ $self->_bucket_key($req) } // 0;
    $until = $self->{global_until} if $self->{global_until} > $until;
    # Conservative global admission limit; no assumptions about route quotas.
    my $recent = $self->{dispatched};
    shift @$recent while @$recent && $recent->[0] <= $now - 1;
    if (@$recent >= 45) {
        my $budget_reset = $recent->[0] + 1;
        $until = $budget_reset if $budget_reset > $until;
    }
    return $until > $now ? $until - $now : 0;
}

sub _pump ($self) {
    return if $self->{active};
    while (@{ $self->{queue} }) {
        my $req = $self->{queue}[0];
        if ($req->{cancelled}) {
            shift @{ $self->{queue} };
            $self->_deliver($req, undef, LE::Discord::Error->new(
                kind => 'cancelled', message => 'request cancelled'));
            next;
        }
        if ($self->{disabled}) {
            shift @{ $self->{queue} };
            $self->_deliver($req, undef, LE::Discord::Error->new(
                kind => 'authentication', message => 'bot token was rejected'));
            next;
        }
        my $now = $self->{clock}->();
        my $delay = $self->_delay($req, $now);
        if ($delay > 0) {
            if (!$self->{wake}) {
                $self->{wake} = $self->{schedule}->($delay, sub {
                    $self->{wake} = undef;
                    $self->_pump;
                });
            }
            return;
        }
        if (my $cancel = delete $self->{wake}) { $cancel->() }
        shift @{ $self->{queue} };
        $req->{state} = 'active';
        $self->{active} = $req;
        push @{ $self->{dispatched} }, $now;
        $self->_dispatch($req);
        return;
    }
    if (my $cancel = delete $self->{wake}) { $cancel->() }
}

sub _cancel_queued ($self, $req) {
    return unless $req->{state} eq 'queued';
    my @remaining = grep { $_ != $req } @{ $self->{queue} };
    $self->{queue} = \@remaining;
    $self->_deliver($req, undef, LE::Discord::Error->new(
        kind => 'cancelled', message => 'request cancelled'));
    $self->_pump unless $self->{active};
    return;
}

sub _dispatch ($self, $req) {
    my @headers = (
        ['Authorization', 'Bot ' . $self->{token}],
        ['Accept', 'application/json'],
        ['Accept-Encoding', 'identity'],
        ['User-Agent', 'LE-Discord/0.001'],
    );
    push @headers, ['Content-Type', 'application/json'] if defined $req->{body};
    my %http_args = (
        method => $req->{method}, url => $req->{url},
        headers => \@headers, timeout => $req->{timeout},
        on_response => sub ($tx, $res) { $req->{response} = $res },
        on_error => sub ($object, $error, @details) {
            $req->{transport_error} = 'HTTP transport failed';
        },
        on_finish => sub { $self->_finish($req) },
    );
    $http_args{body} = $req->{body} if defined $req->{body};
    my $op = eval { $self->{http}->request(%http_args) };
    if ($@) {
        $req->{transport_error} = 'HTTP transport failed to start';
        $self->_finish($req);
    } elsif ($req->{state} eq 'active') {
        $req->{transport} = $op;
        $op->cancel if $req->{cancelled} && $op;
    }
}

sub _number ($value) {
    return undef unless defined($value)
        && $value =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return 0 + $value;
}

sub _finish ($self, $req) {
    return unless $req->{state} eq 'active';
    $self->{active} = undef;
    my ($data, $error);
    if ($req->{cancelled}) {
        $error = LE::Discord::Error->new(
            kind => 'cancelled', message => 'request cancelled');
    } elsif ($req->{transport_error}) {
        $error = LE::Discord::Error->new(
            kind => 'transport', message => $req->{transport_error});
    } elsif (my $res = $req->{response}) {
        my $status = $res->status;
        my $body = $res->body;
        my $valid_json = !defined($body) || !length($body);
        if (!$valid_json) {
            $valid_json = eval { $data = $JSON->decode($body); 1 };
        }
        my $bucket = $res->header('x-ratelimit-bucket');
        $self->{routes}{ $req->{route_key} } = $bucket
            if defined($bucket) && length($bucket);
        my $key = $self->_bucket_key($req);
        my $reset_after = _number($res->header('x-ratelimit-reset-after'));
        my $remaining = _number($res->header('x-ratelimit-remaining'));
        my $now = $self->{clock}->();
        if (defined($remaining) && $remaining == 0 && defined($reset_after)) {
            my $until = $now + $reset_after;
            $self->{blocked_until}{$key} = $until
                if $until > ($self->{blocked_until}{$key} // 0);
        }
        if ($status == 429 && !$req->{cancelled}) {
            my $retry = _number($res->header('retry-after'));
            $retry //= _number(ref($data) eq 'HASH' ? $data->{retry_after} : undef);
            my $scope = $res->header('x-ratelimit-scope') // '';
            my $global = ($scope eq 'global'
                || lc($res->header('x-ratelimit-global') // '') eq 'true'
                || (ref($data) eq 'HASH' && $data->{global}));
            if (defined($retry) && $retry <= 3600) {
                # Discord's limit still applies after this request has exhausted
                # its retry budget; other queued requests must respect it.
                my $until = $now + $retry;
                if ($global) {
                    $self->{global_until} = $until if $until > $self->{global_until};
                } else {
                    $self->{blocked_until}{$key} = $until
                        if $until > ($self->{blocked_until}{$key} // 0);
                }
                if ($req->{attempts} < 2) {
                    ++$req->{attempts};
                    delete @{$req}{qw(response transport transport_error)};
                    $req->{state} = 'queued';
                    unshift @{ $self->{queue} }, $req;
                    $self->_pump;
                    return;
                }
            }
        }
        if ($status == 401) { $self->{disabled} = 1 }
        if ($status < 200 || $status >= 300) {
            $error = LE::Discord::Error->new(
                kind => 'http', status => $status,
                message => ref($data) eq 'HASH' ? ($data->{message} // 'request rejected') : 'request rejected',
            );
        } elsif (!$valid_json) {
            $error = LE::Discord::Error->new(
                kind => 'json', message => 'invalid JSON response');
        }
    } else {
        $error = LE::Discord::Error->new(
            kind => 'transport', message => 'request finished without a response');
    }
    $self->_deliver($req, $data, $error);
    $self->_pump;
}

sub _deliver ($self, $req, $data, $error) {
    $req->{state} = 'finished';
    delete @{$req}{qw(transport response transport_error)};
    my $cb = $error ? ($req->{on_error} // $self->{on_error})
                    : $req->{on_response};
    if ($cb) {
        eval { $cb->($error // $data); 1 }
            or warn "LE::Discord callback failed\n";
    } elsif ($error) {
        warn "$error\n";
    }
    delete @{$req}{qw(on_response on_error)};
}

1;

__END__

=head1 NAME

LE::Discord::REST - Call Discord REST routes asynchronously

=head1 SYNOPSIS

    $discord->rest->post(
        '/channels/{channel.id}/messages',
        'channel.id' => $channel_id,
        json => { content => 'Hello!' },
        on_response => sub ($message) { say $message->{id} },
        on_error => sub ($error) { warn "$error\n" },
    );

=head1 DESCRIPTION

Use Discord's documented route with exact named placeholders. Supports
C<get>, C<post>, C<put>, C<patch> and C<delete>. Optional C<query> and
C<json> hashes supply query string and JSON body parameters.

Success callback receives decoded JSON, or undef for an empty response.
Failures call C<on_error> with an L<LE::Discord::Error>. No callback
receives an L<Uniform::HTTP> object. Requests return a handle with
C<cancel>, C<state> and C<is_terminal>.

The initial scheduler permits one active HTTP request per client and
queues the rest. It observes Discord bucket and reset headers, limits
global submission bursts, and retries explicit 429s at most twice using
the reported delay. Transport failures are never automatically retried.
A 401 disables new requests from this client.

=head1 LIMITATIONS

This MVP supports JSON requests only. It does not yet implement file
uploads, streaming responses, OAuth2 tokens, webhook-specific auth or
bucket-parallel dispatch. It is not a complete Discord SDK. The
rate-limit scheduler deliberately serializes all requests until the
concurrent scheduler has been separately verified.

=cut
