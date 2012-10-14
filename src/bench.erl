-module(bench).

-export([start/0, start/1, stats/0]).
-compile(export_all).

-define(OPTIONS, [
    {clients, 1000},
    {channels, 10},
    {channels_per_client, {1, 2}},
    {pub_interval, 1000},
    {hosts, ["localhost"]}
]).

-define(PORT, 9201).
-define(AVG_SIZE, 36).


-record(state, {
    channels,
    client,
    host,
    ts = 0,
    publish_interval,
    sock
}).

start() ->
    try start([])
    catch
        Class:Error -> io:format("bench:start failure: ~p:~p~n~p~n", [Class, Error, erlang:get_stacktrace()])
    end.

stats() ->
    ets:match(stats, '$1').

start(Opts) ->
    Options = Opts ++ ?OPTIONS,
    inets:start(),
    inets:start(httpc, [{profile, push_httpc}]),
    httpc:set_options([{max_sessions,10240},{max_keep_alive_length,1000}], push_httpc),

    Clients = proplists:get_value(clients, Options),
    {MinChannels,MaxChannels} = proplists:get_value(channels_per_client, Options),
    Channels = [make_channel(I)
        || I <- lists:seq(1, proplists:get_value(channels, Options))],
    Hosts = proplists:get_value(hosts, Options),
    PubInterval = proplists:get_value(pub_interval, Options),

    ets:new(stats, [public, named_table, set]),
    ets:insert(stats, {publishes, 0}),
    ets:insert(stats, {messages, 0}),
    ets:insert(stats, {start_at, erlang:now()}),

    proc_lib:spawn_link(fun stats_collector/0),

    _Publishers = [proc_lib:spawn_link(fun() ->
        timer:sleep(PubInterval*I div Clients),
        PublishChannels = select_random(Channels, MinChannels, MaxChannels),
        Host = lists:nth(I rem length(Hosts) + 1, Hosts),
        try start_push(#state{channels = PublishChannels, host = Host, publish_interval = PubInterval})
        catch
            Class:Error ->
                io:format("Problems in pusher(~B): ~p:~p~n~p~n", [I,Class,Error, erlang:get_stacktrace()])
        end
    end) || I <- lists:seq(1, Clients)],

    % _Pollers = [proc_lib:spawn_link(fun() ->
    %     timer:sleep(PubInterval*I div Clients),
    %     PublishChannels = select_random(Channels, MinChannels, MaxChannels),
    %     Host = lists:nth(I rem length(Hosts) + 1, Hosts),
    %     start_poll(#state{channels = PublishChannels, host = Host, publish_interval = PubInterval})
    % end) || I <- lists:seq(1, Clients div 40)],
    ok.

select_random(Channels,Min,Max) ->
    ChannelCount = crypto:rand_uniform(Min, Max+1),
    select_random(Channels, ChannelCount).

select_random(_Channels, 0) -> 
    [];
select_random(Channels, Count) ->
    N = crypto:rand_uniform(1,length(Channels)+1),
    Channels1 = lists:sublist(Channels,N-1) ++ lists:sublist(Channels,N+1,length(Channels)),
    [lists:nth(N,Channels)|select_random(Channels1,Count-1)].

make_channel(I) ->
    lists:concat(["channel_", 10000 + I]).


stats_collector() ->
    timer:sleep(1000),
    [{publishes, PublishCount}] = ets:lookup(stats, publishes),
    [{messages, MessageCount}] = ets:lookup(stats, messages),
    [{start_at, StartAt}] = ets:lookup(stats, start_at),
    _Delta = timer:now_diff(erlang:now(), StartAt) div 1000,
    io:format("~B publish, ~B receive~n", [PublishCount, MessageCount]),
    ets:insert(stats, {publishes, 0}),
    ets:insert(stats, {messages, 0}),
    ets:insert(stats, {start_at, erlang:now()}),
    stats_collector().





start_push(#state{channels = Channels, host = Host, publish_interval = Interval}) ->
    URL = io_lib:format("http://~s:~B/push", [Host, ?PORT]),
    push(URL, [Chan || Chan <- Channels], Interval).

push(URL, [Chan|Channels], Interval) ->
    httpc:request(post, {URL, [], "text/plain", Chan ++ "|y u no love node.js?"}, [{timeout, 3000}], [], push_httpc),
    ets:update_counter(stats, publishes, 1),
    timer:sleep(Interval),
    push(URL, Channels ++ [Chan], Interval).


start_poll(#state{channels = Channels, host = Host}) ->
    {ok, C} = cowboy_client:init([]),
    URL = iolist_to_binary(io_lib:format("http://~s:~B/poll?channels=~s&ts=", [Host, ?PORT, string:join(Channels, ",")])),
    poll(C, URL, 0).

poll(C1, URL, LastTS) ->
    T = list_to_binary(integer_to_list(LastTS)),
    {ok, C2} = cowboy_client:request(<<"GET">>, <<URL/binary, T/binary>>, C1),
    {ok, Code, _Headers, C3} = cowboy_client:response(C2),
    Code == 200 orelse throw({invalid_comet_reply,Code,_Headers,C3}),
    {ok, Body, C4} = cowboy_client:response_body(C3),
    TS = case binary:split(Body, <<",">>) of
        [T1, Body1] ->
            ets:update_counter(stats, messages, size(Body1) div ?AVG_SIZE),
            cowboy_http:digits(T1);
        [T1] ->
            cowboy_http:digits(T1)
    end,
    timer:sleep(3000 + random:uniform(3000)),
    poll(C4, URL, TS).



