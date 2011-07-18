%%%----------------------------------------------------------------
%%% @author Antonio Garrote <antoniogarrote@gmail.com>
%%% @doc
%%%
%%% @end
%%% @copyright 2011 Antonio Garrote
%%%----------------------------------------------------------------,
-module(erlfaye_demo_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, demo/0]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%% @private
-spec start(normal | {takeover, node()} | {failover, node()},
            any()) -> {ok, pid()} | {ok, pid(), State::any()} |
                      {error, Reason::any()}.
start(_StartType, _StartArgs) ->
    case erlfaye_demo_sup:start_link() of
        {ok, Pid} ->
            {ok, Pid};
        Error ->
            Error
    end.

%% @private
-spec stop(State::any()) -> ok.
stop(_State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================


demo() ->
    application:start(erlfaye_demo).
