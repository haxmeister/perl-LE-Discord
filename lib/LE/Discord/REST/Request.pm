package LE::Discord::REST::Request;
use v5.36;

our $VERSION = '0.001';

sub cancel ($self) {
    return if $self->{state} eq 'finished' || $self->{cancelled};
    $self->{cancelled} = 1;
    if ($self->{state} eq 'active') {
        $self->{transport}->cancel if $self->{transport};
    } else {
        $self->{rest}->_cancel_queued($self);
    }
    return;
}
sub state ($self) { $self->{state} }
sub is_terminal ($self) { $self->{state} eq 'finished' ? 1 : 0 }

1;
