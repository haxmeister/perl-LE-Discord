package LE::Discord::Error;
use v5.36;
use overload '""' => sub ($self, @) {
    my $kind = $self->{kind} // 'unknown';
    my $status = defined $self->{status} ? " (HTTP $self->{status})" : '';
    return "Discord $kind error$status: " . ($self->{message} // 'request failed');
}, fallback => 1;

our $VERSION = '0.001';

sub new ($class, %args) { bless \%args, $class }
sub kind ($self) { $self->{kind} }
sub status ($self) { $self->{status} }
sub message ($self) { $self->{message} }

1;
