# Mojo::SignalR
SignalR protocol implementation for Perl based on Mojo::Transaction::Websocket

## Features
* Auto-reconnect on disconnect
* Initial websocket connection timeout handled as fatal event (but if websocket disconnected after successful connection - reconnection attempts  will be taken)
* Properly handling of packed (compressed, base64-coded) payload in messages
* Very meticulous logging - this package can tell you about nearly every possible problem of other thing you may need to know

## Non-CPAN dependencies
Log::Log4perl::KISS, you can find it here: https://github.com/DRVTiny/Log--Log4perl--KISS

## Synopsis
```
my $sockSignalR;
$sockSignalR = Mojo::SignalR->new(
  'provider_url'  => TRADING_PLATFORM_HTTP,
  'hubs'          => DFLT_HUB_NAME,
  'callbacks'     => {
    # on_connect callback ->
    'connect' => sub {
      my ($signalr) = @_;
      $signalr->command->subscribeToExchangeDeltas('BTC-ETH' => sub {
        my ($signalr, $status) = @_;
      # $_[0] is Mojo::SignalR instance itself
      # $_[1] is JSON::PP::Boolean: true if subscription request was accepted 
      # and false if it was not accepted for some (strange) reason
      });
      $signalr->command->queryExchangeState('BTC-ETH' => sub {
        # ...
      });
    }, # <- on_connect callback
    # on_disconnect callback ->
    'disconnect' => sub {
      my ($signalr, $failure_descr) = @_;
      # ...
    }, # <- on_disconnect callback
    'message/uL' => sub {
      my ($signalr, $msg) = @_;
      # ...
    },
    # message.updateExchangeRates callback ->
    'message/uE' => sub {
      my ($signalr, $msg) = @_;
      # ...

    }, # <- message.updateExchangeRates callback
    'message/default' => sub {
      my ($signalr, $msg) = shift;
      warn 'Payload for unresolved callback: ' . Dumper([$msg])
    },
  }, # <- callbacks
);

Mojo::IOLoop->is_running or Mojo::IOLoop->start;
```
