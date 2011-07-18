#Erlfaye

Erlfaye is an implementation in Erlang of the [Faye server](http://faye.jcoglan.com/), a publish/subscribe server implemented using comet.
The implementation is just a modified version of [Erlycomet](http://code.google.com/p/erlycomet/) with some extensions.
[Mochiweb](https://github.com/mochi/mochiweb) is the underlying HTTP server.

Currently Erlfaye supports the following transport mechanisms:

  - Long polling
  - Callback long polling
  - Websockets

## Installation

The *erlfaye* directory contains the code of the library. Compile it using the provided Makefile and install it in your Erlang home directory
The *erlfaye_demo* folder contains a demo application. It can be built using [Sinan](http://erlware.github.com/sinan/). Once the application is
built it can be started using the *start.sh* script.

## Dependencies

 - Mochiweb
 - Mnesia


## Usage

In order to use Erlfaye, the erlfaye_cluster process must be initiated. This is a description for a supervisor:

    ErlfayeComet = {erlfaye_cluster,
                    {erlfaye_cluster, start, []},
                    permanent,
                    1000,
                    worker,
                    [erlfaye_cluster]},

Once it is initiated, requests to Erlfaye must be bound to a URL in the Mochiweb service loop:

    loop(Req, _, "/cometd", _) ->
        erlfaye_request:handle(Req);

Erlang processes can deliver messages to channels using the *deliver_to_channel* function:

    tick() ->
        receive
            stop ->
                ok
        after 10000 ->
                {_,Secs,_} = now(),
                Channel = <<"/test/time">>,
                Data = Secs rem 1000,
                erlfaye_api:deliver_to_channel(Channel, Data),
                tick()
        end.

Erlang processes can also subscribe/unsubscribe to channels using the *subscribe_process*, *unsubscribe_process* functions:

    start_local_handler() ->
        spawn(fun() ->
                      erlfaye_api:subscribe_process(self(),<<"/rpc/test">>),
                      erlfaye_api:subscribe_process(self(),<<"/test/time">>),                                    
                      local_handler_loop()
              end).
     
    local_handler_loop() ->
        receive
            Data ->
                error_logger:warning_msg("Got an event: ~p ~n",[Data]),        
                local_handler_loop()
        end.

Browser JS applications can use the [Faye browser client](http://faye.jcoglan.com/browser.html) to send and receive notifications:

    var client = new Faye.Client('http://myserver/cometd');
    
    client.subscribe("/location", function(msg) {
       alert("Got an event");
    });

    client.publish("/location", {'latitude':40, 'longitude':-23});
