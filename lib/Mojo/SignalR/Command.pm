package Mojo::SignalR::Command;
use 5.16.1;
use strict;
use warnings;

use Ref::Util qw(is_coderef);
use Scalar::Util qw(refaddr);
use Cpanel::JSON::XS;
use Log::Log4perl::KISS;

our ($callbacks, $next_cmd_id, $AUTOLOAD);
sub new {
  my ($class, $ws, $hub) = @_;
  my $id = refaddr $ws;
  bless +{
    'ws'  	    => $ws,
    'dflt_hub' 	=> $hub,
    'p_nxt_cmd_id' => \$next_cmd_id->{$id},
    'reg_cb'    => ($callbacks->{$id} //= +{}),
  }, (ref $class || $class)
}

sub callback_for {
  my ($self, $cmd_id, $fl_dont_remove) = @_;
  my $cb =
    $fl_dont_remove
    ? $self->{'reg_cb'}{$cmd_id}
    : delete $self->{'reg_cb'}{$cmd_id}
}

sub json {
  $_[1] ? $_[0]->{'json'} = $_[1] : $_[0]->{'json'} //= Cpanel::JSON::XS->new
}

sub websocket {
  $_[0]{'ws'}->is_websocket 
    ? $_[0]{'ws'}
    : logdie_ '%s[%d] Cant send anything because our websocket connector actually is %s!', 
        __PACKAGE__, refaddr($_[0]), ref($_[0]{'ws'}) || 'NOT REFERENCE'
}

sub common_method {
  my $self = shift;
  
  return unless defined $_[1] and !ref($_[1]) and $_[1];
  my ($hub, $method) = do {
    local $_ = shift;
    if ((my $p = index($_, '__')) > 0) {
      (substr($_, 0, $p), substr($_, $p + 2))
    } else {
      ($self->{'dflt_hub'}, $_)
    }
  };
  
  my $cmd_id = ${$self->{'p_nxt_cmd_id'}}++;
  if ( is_coderef $_[$#_] ) {
    $self->{'reg_cb'}{$cmd_id} = pop(@_)
  }
  
  $self->websocket->send(
    $self->json->encode({
      H => $hub,
      M => $method,
      A => \@_,     # command arguments
      I => $cmd_id  # unique command number used to route command answer to a correct callback
    })
  );
}

sub AUTOLOAD {
  my $self = $_[0];
  my ($method) = $AUTOLOAD =~ /([^:]+)$/;
  return if $method eq 'DESTROY';
  {
    no strict 'refs';
    *{$method} = sub {
      shift->common_method(ucfirst($method), @_)
    }
  }
  goto &$method
}

1;
