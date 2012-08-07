-module(stockdb_raw_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TESTDIR, code:lib_dir(stockdb, test)).

-define(FIXTUREDIR, filename:join(?TESTDIR, "fixtures")).
-define(FIXTUREFILE(F), filename:join(?FIXTUREDIR, F)).

-define(TEMPDIR, filename:join(?TESTDIR, "temp")).
-define(TEMPFILE(F), filename:join(?TEMPDIR, F)).

file_create_test() ->
  file_create_test([]).
raw_file_create_test() ->
  file_create_test([raw]).

file_create_test(Modes) ->
  check_creation_params(Modes ++ [{stock, 'TEST'}, {date, {2012,7,26}}, {depth, 10}, {scale, 100}, {chunk_size, 300}],
    "TEST-20120726.300.10.100.stock"),
  check_creation_params(Modes ++ [{stock, 'TEST'}, {date, {2012,7,25}}, {depth, 15}, {scale, 200}, {chunk_size, 600}],
    "TEST-20120725.600.15.200.stock").

check_creation_params(DBOptions, FixtureFile) ->
  ?assert(filelib:is_dir(?TESTDIR)),

  File = ?TEMPFILE("creation-test.temp"),
  ok = filelib:ensure_dir(File),
  ok = file:write_file(File, "GARBAGE"),

  {ok, S} = stockdb_raw:open(File, [write|DBOptions]),
  ok = stockdb_raw:close(S),
  db_no_regress(?FIXTUREFILE(FixtureFile), File),
  ok = file:delete(File).

db_no_regress(OldFile, NewFile) ->
  % TODO: Make something intelligent
  ?assertEqual(file:read_file(OldFile), file:read_file(NewFile)).

write_append_test() ->
  write_append_test([]).
raw_write_append_test() ->
  write_append_test([raw]).

write_append_test(Options) ->
  File = ?TEMPFILE("write-append-test.temp"),
  ok = filelib:ensure_dir(File),

  {ok, S0} = stockdb_raw:open(File, Options ++ [write, {stock, 'TEST'}, {date, {2012,7,25}}, {depth, 3}, {scale, 200}, {chunk_size, 300}]),
  S1 = lists:foldl(fun(Event, State) ->
        {ok, NextState} = stockdb_raw:append(Event, State),
        NextState
    end, S0, chunk_109_content() ++ chunk_110_content_1()),
  ok = stockdb_raw:close(S1),

  {ok, S2} = stockdb_raw:open(File, Options ++ [append]),
  ensure_states_equal(S1, S2),
  S3 = lists:foldl(fun(Event, State) ->
        {ok, NextState} = stockdb_raw:append(Event, State),
        NextState
    end, S2, chunk_110_content_2() ++ chunk_112_content()),
  ok = stockdb_raw:close(S3),

  {ok, S4} = stockdb_raw:open(File, Options ++ [read]),
  ensure_states_equal(S3, S4),
  ok = stockdb_raw:close(S4),

  {ok, FileEvents} = stockdb_raw:read_file(File),
  lists:zipwith(fun(Expected, Read) ->
        ensure_packets_equal(Expected, Read)
    end,
    chunk_109_content() ++ chunk_110_content_1() ++ chunk_110_content_2() ++ chunk_112_content(),
    FileEvents),
  ok = file:delete(File).

db_repair_test() ->
  File = ?TEMPFILE("db-repair-test.temp"),
  ok = filelib:ensure_dir(File),

  {ok, S0} = stockdb_raw:open(File, [write, {stock, 'TEST'}, {date, {2012,7,25}}, {depth, 3}, {scale, 200}, {chunk_size, 300}]),
  S1 = lists:foldl(fun(Event, State) ->
        {ok, NextState} = stockdb_raw:append(Event, State),
        NextState
    end, S0, chunk_109_content() ++ chunk_110_content_1()),
  ok = stockdb_raw:close(S1),

  {ok, F} = file:open(File, [read, write]),
  {ok, _} = file:position(F, {eof, -1}),
  ok = file:truncate(F),
  ok = file:close(F),

  ?assertThrow({truncate_failed, _}, stockdb_raw:open(File, [read])),

  {ok, S2} = stockdb_raw:open(File, [append]),
  S3 = lists:foldl(fun(Event, State) ->
        {ok, NextState} = stockdb_raw:append(Event, State),
        NextState
    end, S2, chunk_110_content_2() ++ chunk_112_content()),
  ok = stockdb_raw:close(S3),

  {ok, FileEvents} = stockdb_raw:read_file(File),
  lists:zipwith(fun(Expected, Read) ->
        ensure_packets_equal(Expected, Read)
    end,
    chunk_109_content() ++ chunk_110_content_1_trunc() ++ chunk_110_content_2() ++ chunk_112_content(),
    FileEvents),

  ok = file:delete(File).


c_encode_full_md_test() ->
  Timestamp = 1343207118230, 
  Bid = [{1234, 715}, {1219, 201}, {1197, 1200}],
  Ask = [{1243, 601}, {1247, 1000}, {1260, 800}],
  Depth = length(Bid),
  Bin = stockdb_format:encode_full_md(Timestamp, Bid ++ Ask),
  ?assertEqual({ok, {md, Timestamp, Bid, Ask}, <<1,2,3,4>>}, stockdb_format:read_one_row(<<Bin/binary, 1,2,3,4>>, Depth)),
  ?assertEqual({Timestamp, [Bid, Ask], <<1,2,3,4>>}, stockdb_format:decode_full_md(<<Bin/binary, 1,2,3,4>>, Depth)),
  
  % N = 100000,
  % L = lists:seq(1,N),
  % B1 = <<Bin/binary, 1,2,3,4>>,
  % T1 = erlang:now(),
  % [stockdb_format:read_one_row(B1, Depth) || _ <- L],
  % T2 = erlang:now(),
  % [stockdb_format:decode_full_md(B1, Depth) || _ <- L],
  % T3 = erlang:now(),
  % ?debugFmt("Full  ~p: ~B, ~B~n", [N, timer:now_diff(T2,T1), timer:now_diff(T3,T2)]),
  ok.

c_encode_delta_md_test() ->
  Timestamp = 15, 
  Bid = [{0, 5}, {-1, 20}, {4334, 1200}],
  Ask = [{12, 0}, {0, 0}, {1000, 800}],
  Depth = length(Bid),
  Bin = stockdb_format:encode_delta_md(Timestamp, Bid ++ Ask),
  ?assertEqual({ok, {delta, Timestamp, Bid, Ask}, <<1,2,3,4>>}, stockdb_format:read_one_row(<<Bin/binary, 1,2,3,4>>, Depth)),
  ?assertEqual({Timestamp, [Bid, Ask], <<1,2,3,4>>}, stockdb_format:decode_delta_md(<<Bin/binary, 1,2,3,4>>, Depth)),

  % N = 100000,
  % L = lists:seq(1,N),
  % B1 = <<Bin/binary, 1,2,3,4>>,
  % T1 = erlang:now(),
  % [stockdb_format:read_one_row(B1, Depth) || _ <- L],
  % T2 = erlang:now(),
  % [stockdb_format:decode_delta_md(B1, Depth) || _ <- L],
  % T3 = erlang:now(),
  % ?debugFmt("Delta ~p: ~B, ~B~n", [N, timer:now_diff(T2,T1), timer:now_diff(T3,T2)]),
  ok.

foldl_test() ->
  File = ?TEMPFILE("foldl-test.temp"),
  ok = filelib:ensure_dir(File),

  {ok, S0} = stockdb_raw:open(File, [write, {stock, 'TEST'}, {date, {2012,7,25}}, {depth, 3}, {scale, 200}, {chunk_size, 300}]),
  S1 = lists:foldl(fun(Event, State) ->
        {ok, NextState} = stockdb_raw:append(Event, State),
        NextState
    end, S0, full_content()),
  ok = stockdb_raw:close(S1),

  % Meaningless functions. We know that events are stored correctly,
  % so just test folding
  CountFun = fun(_, Count) -> Count+1 end,

  FoldFun2 = fun
    ({md, _UTC, Bid, Ask}, AccIn) ->
      AccIn + length(Bid) + length(Ask);
    ({trade, _UTC, Price, _Volume}, AccIn) ->
      AccIn - erlang:round(Price)
  end,

  ?assertEqual(lists:foldl(CountFun, 0, full_content()),
    stockdb_raw:foldl(CountFun, 0, File)),

  ?assertEqual(lists:foldl(FoldFun2, 720, full_content()),
    stockdb_raw:foldl(FoldFun2, 720, File)),

  ok = file:delete(File).

chunk_109_content() ->
  [
    {md, 1343207118230, [{12.34, 715}, {12.195, 201}, {11.97, 1200}], [{12.435, 601}, {12.47, 1000}, {12.60, 800}]},
    {md, 1343207154170, [{12.34, 500}, {12.185, 201}, {11.97, 1200}], [{12.440, 601}, {12.47, 1000}, {12.60, 850}]},
    {md, 1343207197200, [{12.34, 715}, {12.195, 201}, {11.97, 1500}], [{12.435, 601}, {12.49, 1000}, {12.65, 850}]},
    {md, 1343207251182, [{12.34, 715}, {12.195, 201}, {11.97, 1200}], [{12.435, 700}, {12.47, 1000}, {12.60, 600}]},
 {trade, 1343207273291, 12.33, 490},
    {md, 1343207291284, [{12.34, 300}, {12.195, 120}, {11.97, 1200}], [{12.435, 800}, {12.47, 1000}, {12.65, 600}]},
    {md, 1343207307670, [{12.32, 800}, {12.170, 400}, {11.97, 1100}], [{12.440, 800}, {12.47, 1100}, {12.69, 600}]},
    {md, 1343207326562, [{12.34, 300}, {12.195, 120}, {11.97, 1200}], [{12.435, 800}, {12.47, 1000}, {12.65, 600}]},
 {trade, 1343207362719, 12.44, 200},
    {md, 1343207382471, [{12.34, 300}, {12.195, 120}, {11.97, 1200}], [{12.435, 650}, {12.47,  950}, {12.65, 600}]}
  ].

chunk_110_content_1_trunc() ->
  [
 {trade, 1343207402486, 12.445, 300},
    {md, 1343207410324, [{12.35, 800}, {12.270, 450}, {11.97, 1200}], [{12.435, 450}, {12.47,  850}, {12.65, 600}]}
  ].

chunk_110_content_1() ->
  chunk_110_content_1_trunc() ++ [
    {md, 1343207417957, [{12.35, 800}, {12.270, 450}, {11.97, 1200}], [{12.450, 800}, {12.49, 1000}, {12.65, 600}]}
  ].

chunk_110_content_2() ->
  [
    {md, 1343207600274, [{12.35, 700}, {12.265, 400}, {11.97, 1100}], [{12.440, 450}, {12.48, 1200}, {12.65, 800}]},
    {md, 1343207633713, [{12.34, 800}, {12.270, 300}, {11.97, 1200}], [{12.450, 800}, {12.49, 1000}, {12.65, 600}]},
 {trade, 1343207652486, 12.45, 200}
  ].

chunk_112_content() ->
  [
    {md, 1343208100274, [{12.35, 700}, {12.265, 400}, {11.97, 1100}], [{12.440, 450}, {12.48, 1200}, {12.65, 800}]}
  ].

full_content() ->
  chunk_109_content() ++ chunk_110_content_1() ++ chunk_110_content_2() ++ chunk_112_content().


ensure_states_equal(State1, State2) ->
  Elements = lists:seq(1, size(State1)) -- [3, 4],
  lists:foreach(fun(N) ->
        % io:format("Comparing element ~w~n", [N]),
        ?assertEqual(element(N, State1), element(N, State2))
    end, Elements).

ensure_packets_equal({trade, _, _, _} = P1, {trade, _, _, _} = P2) ->
  ?assertEqual(P1, P2);
ensure_packets_equal({md, TS1, Bid1, Ask1}, {md, TS2, Bid2, Ask2}) ->
  ?assertEqual(TS1, TS2),
  ensure_bidask_equal(Bid1, Bid2),
  ensure_bidask_equal(Ask1, Ask2).

ensure_bidask_equal([{P1, V1}|BA1], [{P2, V2}|BA2]) ->
  ?assertEqual(V1, V2),
  ?assert(abs(P1 - P2) < 0.00001),
  ensure_bidask_equal(BA1, BA2);
ensure_bidask_equal([], [Extra|BA2]) ->
  ?assertEqual({0.0, 0}, Extra),
  ensure_bidask_equal([], BA2);
ensure_bidask_equal([], []) ->
  true.