%%%-------------------------------------------------------------------
%%% File:      xhash_storage.erl
%%% @author    Cliff Moon <cliff@powerset.com> []
%%% @copyright 2008 Cliff Moon
%%% @doc  based on: http://www.cs.tau.ac.il/~shanir/nir-pubs-web/Papers/Split-Ordered_Lists.pdf
%%%
%%% @end  
%%%
%%% @since 2008-11-15 by Cliff Moon
%%%-------------------------------------------------------------------
-module(xhash_storage).
-author('cliff@powerset.com').

%% API

-export([open/2, close/1, get/2, put/4, has_key/2, delete/2, fold/3]).

-define(VERSION, 0).
-define(LOAD_LIMIT, 2.0).
-define(INDEX_HEADER_SIZE, 40).
-define(DATA_HEADER_SIZE, 48).
-define(PARENT(Bucket), if Bucket > 0 -> Bucket bxor (1 bsl trunc(math:log(Bucket)/math:log(2))); true -> 0 end).
% -define(debugmsg(Message), error_logger:info_msg(Message)).
% -define(debug(Message, Stuff), error_logger:info_msg(Message, Stuff)).
-define(debugmsg(Message), noop).
-define(debug(Message, Stuff), noop).
-record(xhash, {data,index,head,capacity,size}).
-record(node, {key=nil, data=nil, node_header}).
-record(node_header, {keyhash=0,keysize=0,datasize=0,nextptr=0,lastptr=0}).


-ifdef(TEST).
-include("etest/xhash_storage_test.erl").
-endif.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec 
%% @doc
%% @end 
%%--------------------------------------------------------------------
open(Directory, Name) ->
  ok = filelib:ensure_dir(Directory ++ "/"),
  DataFileName = lists:concat([Directory, "/", Name, ".xd"]),
  IndexFileName = lists:concat([Directory, "/", Name, ".xi"]),
  case file:open(DataFileName, [read, write, binary, raw]) of
    {ok, DataFile} ->
      case file:open(IndexFileName, [read, write, binary, raw]) of
        {ok, IndexFile} -> 
          initialize_or_verify(#xhash{data=DataFile,index=IndexFile});
        Failure -> 
          file:close(DataFile),
          Failure
      end;
    Failure -> Failure
  end.

close(#xhash{data=Data,index=Index}) ->
  file:close(Data),
  file:close(Index),
  ok.
  
get(Key, XHash = #xhash{capacity=Capacity,data=Data,index=Index,size=Size,head=Head}) ->
  if
    Size == 0 -> {ok, not_found};
    true ->
      UnrevHash = lib_misc:hash(Key),
      KeyHash = lib_misc:reverse_bits(UnrevHash),
      BucketIndex = UnrevHash rem Capacity,
      ?debug("get from bucket ~p", [BucketIndex]),
      Pointer = read_bucket(BucketIndex, Index),
      if
        Pointer == 0 -> {ok, not_found};
        true ->
          case find_node(Pointer, Key, KeyHash, Data) of
            not_found -> {ok, not_found};
            {NewPointer, Header} -> 
              {Key, Context, Values} = read_node_data(NewPointer, Header, Data),
              {ok, {Context, Values}}
          end
      end
  end.
  
put(Key, Context, Values, XHash = #xhash{capacity=Capacity,size=Size,data=Data,index=Index,head=Head}) ->
  ?debug("put(~w, Context, Values, XHash)", [Key]),
  UnrevHash = lib_misc:hash(Key),
  KeyHash = lib_misc:reverse_bits(UnrevHash),
  Bucket = UnrevHash rem Capacity,
  KeyBin = list_to_binary(Key),
  DataBin = term_to_binary({Context, Values}),
  Header = #node_header{keyhash=KeyHash,keysize=byte_size(KeyBin),datasize=byte_size(DataBin)},
  {_, NewHash} = write_node(Bucket, Header, KeyBin, DataBin, XHash),
  {ok, NewHash}.
  
has_key(Key, #xhash{}) ->
  ok.
  
delete(Key, #xhash{}) ->
  ok.
  
fold(Fun, XHash = #xhash{head=Head}, AccIn) when is_function(Fun) ->
  int_fold(Fun, Head, XHash, AccIn).
  
%%====================================================================
%% Internal functions
%%====================================================================
int_fold(Fun, 0, XHash, AccIn) -> AccIn;

int_fold(Fun, Pointer, XHash = #xhash{data=Data}, AccIn) ->
  NodeHeader = read_node_header(Pointer, Data),
  if 
    NodeHeader#node_header.keysize == 0 -> 
      int_fold(Fun, NodeHeader#node_header.nextptr, XHash, AccIn);
    true ->
      {Key, Context, Values} = read_node_data(Pointer, NodeHeader, Data),
      AccOut = Fun({Key, Context, Values}, AccIn),
      int_fold(Fun, NodeHeader#node_header.nextptr, XHash, AccOut)
  end.

write_node(Bucket, Header, KeyBin, DataBin, XHash = #xhash{index=Index,data=Data}) ->
  ?debug("write_node(~p, ~p, KeyBin, DataBin, XHash)", [Bucket, Header]),
  Pointer = read_bucket(Bucket, Index),
  {NewPointer, XHash1} = insert_node(Pointer, Header, KeyBin, DataBin, XHash),
  write_bucket(Bucket, NewPointer, Index),
  {NewPointer, XHash1}.

initialize_bucket(0, XHash = #xhash{index=Index,data=Data}) ->
  {ok, Pointer} = write_node_header(#node_header{}, eof, Data),
  write_bucket(0, Pointer, Index),
  XHash1 = XHash#xhash{head=Pointer},
  write_head_pointer(Pointer, Data),
  {Pointer, XHash1};

initialize_bucket(Bucket, XHash = #xhash{index=Index,data=Data}) ->
  Parent = ?PARENT(Bucket),
  ?debug("initialize_bucket(~p, XHash) ~p", [Bucket, Parent]),
  {ParentPointer, XHash1} = case read_pointer(?PARENT(Bucket), Index) of
    0 -> initialize_bucket(?PARENT(Bucket), XHash);
    Ptr -> {Ptr, XHash}
  end,
  ?debug("inserting dummy node keyhash = ~p", [lib_misc:reverse_bits(Bucket)]),
  {NodePointer, XHash2} = insert_node(ParentPointer, #node_header{keyhash=lib_misc:reverse_bits(Bucket)}, <<"">>, <<"">>, XHash1),
  ?debug("nodepointer ~p", [NodePointer]),
  write_bucket(Bucket, NodePointer, Index),
  {NodePointer, XHash2}.

% the list is empty
insert_node(Pointer, Header, KeyBin, DataBin, XHash = #xhash{data=Data,head=0}) ->
  ?debug("insert_node(~w, ~w, KeyBin, DataBin, ~w) -> empty list", [Pointer, Header, XHash]),
  {ok, NewPointer} = write_node_header(Header#node_header{}, eof, Data),
  ok = write_node_data(KeyBin, DataBin, eof, Data),
  XHash1 = increment_size(Header, XHash),
  write_head_pointer(NewPointer,Data),
  {NewPointer, XHash1#xhash{head=NewPointer}};

insert_node(0, Header, KeyBin, DataBin, XHash) ->
  insert_node(0, nil, Header, KeyBin, DataBin, XHash);

insert_node(Pointer, Header, KeyBin, DataBin, XHash = #xhash{index=Index,data=Data}) ->
  ReadHeader = read_node_header(Pointer, Data),
  insert_node(Pointer, ReadHeader, Header, KeyBin, DataBin, XHash).
  
insert_node(Pointer, LastHeader = #node_header{nextptr=0}, Header = #node_header{}, KeyBin, DataBin, XHash = #xhash{index=Index,data=Data,size=Size}) ->
  ?debug("insert_node(~w, ~w, ~w, KeyBin, DataBin, XHash) -> end of the list", [Pointer, LastHeader, Header]),
  {ok, NewPointer} = write_node_header(Header#node_header{}, eof, Data),
  ok = write_node_data(KeyBin, DataBin, eof, Data),
  {ok, _} = write_node_header(LastHeader#node_header{nextptr=NewPointer}, Pointer, Data),
  XHash1 = increment_size(Header, XHash),
  {NewPointer, XHash1};
  
insert_node(0, nil, Header = #node_header{keyhash=KeyHash}, KeyBin, DataBin, XHash = #xhash{index=Index,data=Data,size=Size,head=Pointer}) ->
  ?debug("insert_node(~w, ~w, ~w, KeyBin, DataBin, XHash) -> start of the list", [0, nil, Header]),
  {ok, NewPointer} = write_node_header(Header#node_header{nextptr=Pointer}, eof, Data),
  ok = write_node_data(KeyBin, DataBin, eof, Data),
  % {ok, Pointer} = write_node_header(LastHeader#node_header{lastptr=NewPointer}, Pointer, Data),
  write_head_pointer(NewPointer, Data),
  {NewPointer, increment_size(Header, XHash#xhash{head=NewPointer})};
  
insert_node(Pointer, LastHeader, Header = #node_header{keyhash=KeyHash}, KeyBin, DataBin, XHash = #xhash{index=Index,data=Data,size=Size}) ->
  ?debug("insert_node(~w, ~w, ~w, KeyBin, DataBin, ~w)", [Pointer, LastHeader, Header, XHash]),
  NextHeader = read_node_header(LastHeader#node_header.nextptr, Data),
  if
    KeyHash =< NextHeader#node_header.keyhash ->
      {ok, NewPointer} = write_node_header(Header#node_header{nextptr=LastHeader#node_header.nextptr,lastptr=Pointer}, eof, Data),
      ok = write_node_data(KeyBin, DataBin, eof, Data),
      {ok, _} = write_node_header(LastHeader#node_header{nextptr=NewPointer}, Pointer, Data),
      % {ok, _} = write_node_header(NextHeader#node_header{lastptr=NewPointer}, Pointer, Data),
      XHash1 = increment_size(Header, XHash),
      {NewPointer, XHash1};
    true -> insert_node(LastHeader#node_header.nextptr, NextHeader, Header, KeyBin, DataBin, XHash)
  end.

read_node_data(Pointer, #node_header{keysize=KeySize,datasize=DataSize}, Data) ->
  {ok, <<KeyBin:KeySize/binary, DataBin:DataSize/binary>>} = file:pread(Data, Pointer+18, KeySize+DataSize),
  Key = binary_to_list(KeyBin),
  {Context, Values} = binary_to_term(DataBin),
  {Key, Context, Values}.

find_node(0, Key, KeyHash, Data) ->
  not_found;

find_node(Pointer, Key, KeyHash, Data) ->
  Header = read_node_header(Pointer, Data),
  ?debug("find_node(~p, ~p, ~p, Data, _) -> ~p", [Pointer, Key, KeyHash, Header#node_header.keyhash]),
  if
    KeyHash == Header#node_header.keyhash -> {Pointer, Header};
    KeyHash > Header#node_header.keyhash -> find_node(Header#node_header.nextptr, Key, KeyHash, Data);
    true -> not_found
  end.

write_node_header(Header, eof, Data) ->
  {ok, Pointer} = file:position(Data, eof),
  write_node_header(Header, Pointer, Data);

write_node_header(Header = #node_header{keyhash=KeyHash,nextptr=NextPointer,lastptr=LastPointer,keysize=KeySize,datasize=DataSize}, Pointer, Data) ->
  ?debug("write_node_header(~p,~p,Data)", [Header, Pointer]),
  ok = file:pwrite(Data, Pointer, <<KeyHash:32, NextPointer:64, KeySize:16, DataSize:32>>),
  {ok, Pointer}.
  
write_node_data(KeyBin, DataBin, Pointer, Data) ->
  file:position(Data, Pointer),
  ok = file:write(Data, [KeyBin, DataBin]).

read_node_header(Pointer, Data) ->
  timer:sleep(50),
  {ok, <<KeyHash:32/integer, NextPointer:64/integer, KeySize:16/integer, DataSize:32/integer>>} = file:pread(Data, Pointer, 18),
  Header = #node_header{keyhash=KeyHash,nextptr=NextPointer,keysize=KeySize,datasize=DataSize},
  ?debug("read_node_header(~p, Data) -> ~p", [Pointer, Header]),
  Header.

read_bucket(0, Index) ->
  ?debugmsg("read_bucket 0"),
  read_pointer(0, Index);

read_bucket(Bucket, Index) ->
  Parent = ?PARENT(Bucket),
  ?debug("read_bucket(~p, Index) -> ~p", [Bucket, Parent]),
  Pointer = read_pointer(Bucket, Index),
  if
    Pointer == 0 -> read_bucket(Parent, Index);
    true -> Pointer
  end.
  
write_bucket(Bucket, Pointer, Index) ->
  ?debug("write_bucket(~p, ~p, Index) -> ~p", [Bucket, Pointer, 8*Bucket + ?INDEX_HEADER_SIZE]),
  file:pwrite(Index, 8*Bucket + ?INDEX_HEADER_SIZE, <<Pointer:64>>).
  
read_pointer(Bucket, Index) ->
  Loc = 8 * Bucket + ?INDEX_HEADER_SIZE,
  {ok, <<Pointer:64/integer>>} = file:pread(Index, Loc, 8),
  ?debug("read_pointer(~p, ~p) -> ~p", [Bucket, Index, Pointer]),
  Pointer.

initialize_or_verify(Hash = #xhash{data=Data,index=Index}) ->
  case {read_data_header(Data), read_index_header(Index)} of
    {{ok, <<"XD">>, ?VERSION, Size, Head}, {ok, <<"XI">>, ?VERSION, Capacity}} -> {ok, Hash#xhash{size=Size,head=Head,capacity=Capacity}};
    {eof, eof} -> initialize(Hash);
    {FailureA, FailureB} -> {error, io_lib:format("could not initialize: ~w", [{FailureA, FailureB}])}
  end.
  
read_data_header(File) ->
  case file:pread(File, 0, 16) of
    {ok, <<Id:2/binary, Version:16/integer, Size:32/integer, Head:64/integer>>} -> {ok, Id, Version, Size, Head};
    {error, Reason} -> {error, Reason};
    eof -> eof
  end.
  
read_index_header(File) ->
  case file:pread(File, 0, 8) of
    {ok, <<Id:2/binary, Version:16/integer, Capacity:32>>} -> {ok, Id, Version, Capacity};
    {error, Reason} -> {error, Reason};
    eof -> eof 
  end.
  
increment_size(#node_header{keysize=0}, XHash) ->
  XHash;
  
increment_size(_, XHash = #xhash{size=Size, data=Data}) ->
  write_size(Size+1, Data),
  XHash#xhash{size=Size+1}.
  
write_size(Size, Data) ->
  file:pwrite(Data, 4, <<Size:32>>).
  
write_head_pointer(Pointer, Data) ->
  file:pwrite(Data, 8, <<Pointer:64>>).
  
initialize(Hash = #xhash{data=Data,index=Index}) ->
  Size = 0,
  Head = 0,
  Capacity = 1024,
  TableSize = Capacity * 64,
  case file:pwrite(Data, 0, <<"XD", ?VERSION:16, Size:32, Head:64, 0:256>>) of
    ok ->
      case file:pwrite(Index, 0, <<"XI", ?VERSION:16, Capacity:32, 0:256, 0:TableSize>>) of
        ok -> {ok, Hash#xhash{head=Head,capacity=Capacity,size=Size}};
        Failure -> Failure
      end;
    Failure -> Failure
  end.