%%%---------------------------------------------------------------------------------------
%%% @author     Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @copyright  2007 Roberto Saccon
%%% @doc        ErlyComet Demo Chat Application
%%% @reference  See <a href="http://erlycomet.googlecode.com" target="_top">http://erlycomet.googlecode.com</a> for more information
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(erlfaye_demo_server).
-author('rsaccon@gmail.com').


%% Api
-export([start/0,
         stop/0,
         stop/1]).


%% Internal exports
-export([loop/1, loop/4, tick/0]).


%%====================================================================
%% API functions
%%====================================================================
start() ->
    {ok, App} = application:get_application(),
    Loop = fun ?MODULE:loop/1,
    Args = case application:get_env(App, http_port) of
               {ok, Port} ->
                   io:format("Listening on Port: ~p~n",[Port]),
                   [{port, Port} | [{loop, Loop}]];
               _ ->
                   [{loop, Loop}]
           end,
    %register(clock, spawn(fun() -> ?MODULE:tick() end)),
    start_local_handler(),
    error_logger:warning_msg("STARTING APP!",[]),
    mochiweb_http:start(Args).


stop() ->
    clock ! stop,
    mochiweb_http:stop(?MODULE).


stop(Name) ->
    clock ! stop,
    mochiweb_http:stop(Name).




%%====================================================================
%% Internal exports
%%====================================================================
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


%%====================================================================
%% Internal functions
%%====================================================================
loop(Req) ->
    DocRoot = filename:join([filename:dirname(code:which(?MODULE)),"..", "demo-docroot"]),
    loop(Req, Req:get(method), Req:get(path), DocRoot).

loop(Req, _, "/cometd", _) ->
    erlfaye_request:handle(Req);

loop(Req, 'GET', [$/ | Path], DocRoot) ->
    Req:serve_file(Path, DocRoot);

loop(Req, _Method, _Path, _) ->
    Req:not_found().

%%
%%  client
%%

start_local_handler() ->
    spawn(fun() ->
                  erlfaye_api:subscribe_process(self(),<<"/rpc/test">>),
                  erlfaye_api:subscribe_process(self(),<<"/test/time">>),                                    
                  local_handler_loop()
          end).

local_handler_loop() ->
    receive
        Data ->
            error_logger:warning_msg("\n\n\n\n\n!!! GOT A LOCAL EVENT: ~p ~n",[Data]),        
            local_handler_loop()
    end.

