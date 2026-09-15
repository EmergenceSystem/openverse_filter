%%%-------------------------------------------------------------------
%%% @doc Openverse open-licensed media agent.
%%%
%%% Searches api.openverse.org for CC-licensed images and audio and
%%% returns media embryos (media_type=image|audio) with thumbnail,
%%% media_url, license, author. Keyless.
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(openverse_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(IMG_URL,   "https://api.openverse.org/v1/images/?mature=false&page_size=8&q=").
-define(AUDIO_URL, "https://api.openverse.org/v1/audio/?mature=false&page_size=6&q=").
-define(UA, "openverse_filter/1.0 (EmergenceSystem; +https://github.com/EmergenceSystem)").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"image">>, <<"images">>, <<"photo">>,
                                      <<"picture">>, <<"illustration">>,
                                      <<"sound">>, <<"audio">>, <<"music">>,
                                      <<"openverse">>, <<"media">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case openverse_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(openverse_filter_query_listener),
    catch em_pop_sup:stop_node(openverse_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(openverse_filter, pop_port,   9520),
    QueryPort = application:get_env(openverse_filter, query_port, 9521),
    Seeds     = application:get_env(openverse_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(openverse_filter),
    catch cowboy:stop_listener(openverse_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(openverse_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        advertise_host  => list_to_binary(os:getenv("EM_POP_ADVERTISE_HOST", "localhost")),
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => openverse_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(openverse_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[openverse_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

generate_embryo_list(Body) ->
    case extract_query(Body) of
        "" -> [];
        Query ->
            Q = uri_string:quote(Query),
            fetch(?IMG_URL ++ Q, fun img_embryo/1)
                ++ fetch(?AUDIO_URL ++ Q, fun aud_embryo/1)
    end.

extract_query(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map,
                           maps:get(<<"query">>, Map, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

fetch(Url, Builder) ->
    Headers = [{"User-Agent", ?UA}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, 8000}, {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case catch json:decode(Body) of
                #{<<"results">> := List} when is_list(List) ->
                    lists:filtermap(Builder, List);
                _ -> []
            end;
        _ -> []
    end.

img_embryo(#{<<"url">> := Url} = R) when is_binary(Url) ->
    {true, #{<<"properties">> => media_props(<<"image">>, R, Url, undefined)}};
img_embryo(_) -> false.

aud_embryo(#{<<"url">> := Url} = R) when is_binary(Url) ->
    Dur = case maps:get(<<"duration">>, R, null) of
              N when is_integer(N) -> N div 1000;
              _ -> undefined
          end,
    {true, #{<<"properties">> => media_props(<<"audio">>, R, Url, Dur)}};
aud_embryo(_) -> false.

media_props(Type, R, MediaUrl, Dur) ->
    Base = #{
        <<"media_type">> => Type,
        <<"media_url">>  => MediaUrl,
        <<"title">>      => maps:get(<<"title">>, R, <<"Untitled">>),
        <<"url">>        => maps:get(<<"foreign_landing_url">>, R, MediaUrl),
        <<"source">>     => <<"openverse">>
    },
    B1 = put_opt(Base, <<"thumbnail">>, maps:get(<<"thumbnail">>, R, null)),
    B2 = put_opt(B1,   <<"author">>,    maps:get(<<"creator">>,   R, null)),
    B3 = put_opt(B2,   <<"license">>,   license(R)),
    case Dur of
        undefined -> B3;
        _         -> B3#{<<"duration">> => Dur}
    end.

license(R) ->
    case maps:get(<<"license">>, R, null) of
        L when is_binary(L), byte_size(L) > 0 ->
            Up = unicode:characters_to_binary(string:uppercase(L)),
            case maps:get(<<"license_version">>, R, <<>>) of
                V when is_binary(V), byte_size(V) > 0 ->
                    <<"CC ", Up/binary, " ", V/binary>>;
                _ ->
                    <<"CC ", Up/binary>>
            end;
        _ -> null
    end.

put_opt(M, _K, null)      -> M;
put_opt(M, _K, <<>>)      -> M;
put_opt(M, K, V) when is_binary(V) -> M#{K => V};
put_opt(M, _K, _)         -> M.
