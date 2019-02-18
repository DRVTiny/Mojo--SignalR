package Mojo::SignalR;
BEGIN { 
# Mojo::UserAgent operates on MOJO_CLIENT_DEBUG incorrectly, so we have to use proxy-env-variable here 
  $ENV{'MOJO_CLIENT_DEBUG'} = 1 if $ENV{'SIGNALR_DEBUG'}
}

use constant MAND_ARGS => qw(provider_url hubs);
use constant DFLT_RETRY_CONNECT_AFTER => 0.1; # secs.

use 5.16.1;
use strict;
use warnings;
use boolean;

use Ref::Util qw(is_plain_coderef is_plain_arrayref is_plain_hashref is_hashref);
use Cpanel::JSON::XS;
use Data::Dumper qw(Dumper);
use URI::Query;
use List::Util qw(first);
use Scalar::Util qw(refaddr weaken looks_like_number);
use Mojo::UserAgent;
use MIME::Base64;
use Compress::Zlib;

use Log::Log4perl::KISS;
use Mojo::SignalR::Command;

my $json = Cpanel::JSON::XS->new;
my (%instancesByTX, %instancesByUA);

sub new {
    my ($class, %args) = @_;
    if (my $mandArgMissed = first {!defined $args{$_}} MAND_ARGS) {
        die 'Mandatory argument for ' . __PACKAGE__ . ' constructor missing: ' . $mandArgMissed;
    }
    my $ua = Mojo::UserAgent->new;
    my $providerUrl = 
      ($args{'provider_url'} =~ m%^https://%i ? '' : 'https://') . $args{'provider_url'};
    $providerUrl =~ m%^(?i:https?://[^/]+)(?:/(.*))?% or die 'provider_url is invalid';
    $1 or $providerUrl =~ s%/?$%/signalr%;
    debug_ "providerUrl = $providerUrl";
    my $connectionData = $ua->get(
        $providerUrl . '/negotiate',
        {'Content-Type' => 'application/json', 'User-Agent' => ''}
    )->result->json;
    debug_ 'Block of SignalR properties:', $connectionData;
    $connectionData->{'TryWebSockets'} or die q(the server doesn't support websocket connections);
    my $wssBase = ($providerUrl =~ s%^(?i:https://)%wss://%r);
    my $hubs = $args{'hubs'};
    is_plain_arrayref($hubs) or (!ref($hubs) and $hubs and $hubs = [$hubs])
      or logdie_ '"hubs" key must be initialized with arrayref or non-empty scalar';
    my $token = $connectionData->{'ConnectionToken'};
    my $me = 
      bless +{
        token => $token,
        url   => {http => $providerUrl, wss_base => $wssBase},
        ua    => $ua,	# Mojo::UserAgent instance
        tx    => undef, # Mojo::Transaction::WebSocket instance will be here after succesfull connection
        cb    => +{},	# user-defined callbacks (CODE references) will be stored here,
        hubs  => $hubs,
      }, (ref $class || $class);
    weaken( $instancesByUA{refaddr $ua} = $me );
    my $callbacks = $args{'callbacks'} // {};
    while (my ($cb_route, $cb_code) = each %{$callbacks}) {
      $me->on($cb_route => $cb_code)
    }
    
    if ( looks_like_number(my $c_timeout = $connectionData->{'TransportConnectTimeout'}) ) {
      debug_ 'Set timeout alarm for signalr[%d] will be triggered after %d sec.', refaddr($me), $c_timeout;
      Mojo::IOLoop->timer(
        $c_timeout => sub {
            $me->connected
              or logdie_ 'timeout when trying to establish websocket connection on signalr[%d]', refaddr($me);
        }
      )
    }
    
    $ua->websocket(
      $me->{'url'}{'wss_connect'} = 
        $wssBase . '/connect?' . 
        URI::Query->new({
           transport        => 'webSockets',
           clientProtocol   => $connectionData->{'ProtocolVersion'},
           connectionToken  => $token,
           connectionData   => $json->encode([map +{name => $_}, @{$hubs}]),
           tid              => 4 #!TODO! it's better to make it clear, wtf is this? :)
        }),
      \&__on_connect
    );
    return $me
}

sub connected { 
  do { error_ 'tx not defined yet!'; return } unless defined(my $tx = $_[0]{'tx'});
 # debug  { 'connected() check on %s', Dumper($tx) };
  do { error_ 'tx is not websocket!'; return } 			unless 	$tx->is_websocket;
  do { error_ 'tx seems to be already closed!'; return } 	unless 	$tx->established;
  true
}

sub command {
    $_[0]{'cmd'} // logdie_ 'Mojo::SignalR::Command handler not initialized yet'
}

sub on {
  my $self = $_[0];
  is_plain_coderef(my $cb = $_[$#_]) or die 'last parameter must be a coderef';
  ${__ref_nested_val( $self->{'cb'}, map { split '/' } @_[1..($#_-1)] )} = $cb
}

sub __on_connect {
  my ($ua, $tx) = @_;
  my $me = $instancesByUA{refaddr $ua} 
    or logdie_ 'Cant proceed with __on_connect: no such %s instance for this Mojo::UserAgent', __PACKAGE__;
    
  # Check if WebSocket handshake was successful ->
  unless ( $tx->is_websocket ) {
    error_ 'WebSocket handshake failed. Will try to reconnect after %s sec. delay', DFLT_RETRY_CONNECT_AFTER;
    Mojo::IOLoop->timer(DFLT_RETRY_CONNECT_AFTER() => sub {
      $me->{'ua'}->websocket($me->{'url'}{'wss_connect'} => \&__on_connect)
    });
    return
  }
      
  #error_('Subprotocol negotiation failed!')		and return unless $tx->protocol;
  # <- Check if WebSocket handshake was successful
  
  # OK here, seems to be connected
  weaken( $instancesByTX{refaddr $tx} = $me );
  my $outSignalR = $me->{'cmd'} = Mojo::SignalR::Command->new($tx, $me->{'hubs'}[0]);
  $me->{'tx'} = $tx;
  my $callbacks = $me->{'cb'};
  
  # On websocket disconnect - try to reconnect immediately
  $tx->on('finish' => \&__on_failure);
 
  $tx->on('message' => sub {
  # After Perl 5.20 all string arguments not copied on assigning to some variable, 
  # but will be actually copied only after first modification of the target variable; 
  # So we can freely assign $_[1] to $data if we dont pretend to modify $data later. 
    my ($tx, $data) = @_;
    debug_ 'WebSocket message:', $data;
    # skip keep-alive messages
    return true if !defined($data) or $data eq '{}';
    my $msgs_bucket = $json->decode($data);
    if ($msgs_bucket->{'M'} and my $on_message = $callbacks->{'message'}) {
      for my $msg ( @{$msgs_bucket->{'M'}} ) {
        my ($hub, $method) = @{$msg}{qw/H M/};
        if ( my $cb = first { defined($_) } @{$on_message}{"${hub}.${method}", $method, 'default'} ) {
          $cb->( $me, __decode_payload($_) ) for @{$msg->{'A'}}
        }
      }
    # we can't check for $msgs_bucket->{'R'} in simple boolean context here (i.e. present/not present in answer),
    # because we can potentially receive {"R": false}: in this case the result is here, but it is "falsish"
    } elsif ( defined(my $resp2cmd = $msgs_bucket->{'R'}) ) {
      my $cmd_id = $msgs_bucket->{'I'};
      if ( my $cb = $outSignalR->callback_for($cmd_id) ) {
        $cb->( $me, __decode_payload($resp2cmd) )
      } else {
        warn_ 'Unwanted response for command with id=%s: %s',
                $cmd_id,
                ( eval { __decode_payload($resp2cmd) } // [$resp2cmd] )
      }
    }
  });
  
  #!TODO!: dummy stub here for now, need to be rewritten ->
  $tx->on('error' => sub {
    my ($tx, $err) = @_;
    error_ q<WebSocket's on_error handler triggered. We got message:>, $err;
    if ( my $cb = $callbacks->{'error'} ) {
      $cb->( $me, $err )
    } 
    $tx->finish
  });
  # <- dummy stub here
  
  is_plain_coderef($callbacks->{'connect'})
    and $callbacks->{'connect'}->( $me );
}

# This was not made as closure to avoid possible memory leaks inside the stack of deeply nested closures
sub __on_failure {
  my $tx = $_[0];
  my $failure_descr = join(': ' => @_[1..$#_]) || 'Unknown error';
  my $me = $instancesByTX{refaddr $tx} 
    or logdie_ 'Cant proceed with __on_failure: no such %s instance associated with %s[%d]', __PACKAGE__, ref($tx), refaddr($tx);  
  error_ 'WebSocket failure detected: <<%s>>. Will try to reconnect', $failure_descr;
  if ( my $cb = $me->{'cb'}{'disconnect'} ) {
    $cb->($me, $failure_descr)
  }
  
  $me->{'ua'}->websocket($me->{'url'}{'wss_connect'} => \&__on_connect)
}

sub __decode_payload {
  defined($_[0]) or logdie_ 'Empty payload was passed to decoder';
  return $_[0]   if is_plain_hashref($_[0]) or is_plain_arrayref($_[0]);
  my $r = ref($_[0]);
  if ($r eq 'JSON::PP::Boolean') {
  # convert from JSON::PP::Boolean to simply 1 or 0. This also can be done directly as ${$_[0]}
    return $_[0] + 0
  }
  return $_[0] if substr($r, 0, 10) eq 'JSON::PP::';
  $r and logdie_ 'Cant inflate something that looks like reference of unsupported type', $r;
  do {
    warn_ 'Cant decode passed message as packed-json, will return it as a simple scalar (this could break thinks)';
    return $_[0]
  } unless defined(my $deflated_str = eval { decode_base64($_[0]) });
  my $infl = inflateInit( -WindowBits => -MAX_WBITS );
  my ($json_msg, $status) = ('', undef);
  #TODO: JSON incremental decoding of uncompressed data on the fly
  while (length $deflated_str) {
    (my $buffer, $status) = $infl->inflate($deflated_str);
    if (defined $buffer) {
      $json_msg .= $buffer;
      last unless $status == Z_OK
    } else {
      logdie_ 'We got zlib error when trying to uncompress payload: status_code=%s, msg=<<%s>>', $status, $infl->msg
    }
  }
  
  $status == Z_STREAM_END or
    logdie_ 'Received unexpected inflate() status_code='
                . $status
                . do { my $m = $infl->msg; $m ? ", msg=<<$m>>" : '' };
                
  if (length $deflated_str) {
    warn_ 'Possible inflating problem: end of compressed data was reached before end of message marker'
  }
  
  eval { $json->decode($json_msg) }
    or logdie_ 'Cant decode uncompressed message <<%s>> as JSON-formatted structure. Reason: <<%s>>', $json_msg, $@
}

sub __ref_nested_val {
    my $hr = shift;
    @_ or die 'empty keys sequence';
    while ( 1 ) {
        is_hashref($hr) or die 'not hash ref in the path';
        $#_ or return \$hr->{$_[0]};
        $hr = $hr->{+shift} //= {}
    } 
}

sub DESTROY {
  my ($ua, $tx) = @{$_[0]}{qw/ua tx/};
  if (defined $ua and my $r = eval { refaddr $ua }) {
    delete $instancesByUA{$r}
  }
  if (defined $tx and my $r = eval { refaddr $tx }) {
    delete $instancesByTX{$r}
  }  
}

1;
