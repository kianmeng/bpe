-module(bpe).
-author('Maxim Sokhatsky').
-include("bpe.hrl").
-include_lib("kvs/include/cursors.hrl").
-include("api.hrl").
-export([head/1,trace/4]).
-compile(export_all).
-define(TIMEOUT, application:get_env(bpe,timeout,60000)).

load(Id) -> load(Id, []).
load(Id, Def) ->
    case kvs:get("/bpe/proc",Id) of
         {error,_} -> Def;
         {ok,Proc} -> {_,{_,T}} = current_task(Id),
                      Proc#process{task=T} end.

cleanup(P) ->
  [ kvs:delete("/bpe/hist",Id) || #hist{id=Id} <- bpe:hist(P) ],
    kvs:delete(writer,"/bpe/hist/" ++ P),
    kvs:delete("/bpe/proc",P).

current_task(Id) ->
    case bpe:head(Id) of
         [] -> {empty,{task, 'Created'}};
         #hist{id={H,_},task=T} -> {H,T} end.

trace(Proc,Name,Time,Task) ->
    Key = "/bpe/hist/" ++ Proc#process.id,
    Writer = kvs:writer(Key),
    kvs:append(Proc,"/bpe/proc"),
    kvs:append(#hist{ id = {step,Writer#writer.count,Proc#process.id},
                    name = Name,
                    time = #ts{ time = Time},
                    docs = Proc#process.docs,
                    task = Task}, Key).

start(Proc0, Options) ->
    Id   = case Proc0#process.id of [] -> kvs:seq([],[]); X -> X end,
    {Hist,Task} = current_task(Id),
    Node = element(2,Task),
    Pid  = proplists:get_value(notification,Options,undefined),
    Proc = Proc0#process{id=Id,
           task= Node,
           options = Options,
           notifications = Pid,
           started= #ts{ time = calendar:local_time() } },

    case Hist of empty -> trace(Proc,[],calendar:local_time(),Task); _ -> skip end,

    Restart = transient,
    Shutdown = ?TIMEOUT,
    ChildSpec = { Id,
                  {bpe_proc, start_link, [Proc]},
                  Restart, Shutdown, worker, [bpe_proc] },

    case supervisor:start_child(bpe_otp,ChildSpec) of
         {ok,_}    -> {ok,Proc#process.id};
         {ok,_,_}  -> {ok,Proc#process.id};
         {error,_} -> {error,Proc#process.id} end.

pid(Id) -> bpe:cache({process,Id}).

proc(ProcId)              -> gen_server:call(pid(ProcId),{get},            ?TIMEOUT).
complete(ProcId)          -> gen_server:call(pid(ProcId),{complete},       ?TIMEOUT).
complete(ProcId,Stage)    -> gen_server:call(pid(ProcId),{complete,Stage}, ?TIMEOUT).
amend(ProcId,Form)        -> gen_server:call(pid(ProcId),{amend,Form},     ?TIMEOUT).
discard(ProcId,Form)      -> gen_server:call(pid(ProcId),{discard,Form},   ?TIMEOUT).
modify(ProcId,Form,Arg)   -> gen_server:call(pid(ProcId),{modify,Form,Arg},?TIMEOUT).
event(ProcId,Event)       -> gen_server:call(pid(ProcId),{event,Event},    ?TIMEOUT).

head(ProcId) ->
  case kvs:get(writer,"/bpe/hist/" ++ ProcId) of
       {ok, #writer{count = C}} -> case kvs:get("/bpe/hist/" ++ ProcId,{C - 1,ProcId}) of
       {ok, X} -> X; _ -> [] end; _ -> [] end.

hist(ProcId)   -> kvs:feed("/bpe/hist/" ++ ProcId).
hist(ProcId,N) -> case application:get_env(kvs,dba,kvs_mnesia) of
                       kvs_mnesia -> case kvs:get(hist,{N,ProcId}) of
                                          {ok,Res} -> Res;
                                          {error,_Reason} -> [] end;
                       kvs_rocks  -> case kvs:get("/bpe/hist/" ++ ProcId,{N,ProcId}) of
                                          {ok,Res} -> Res;
                                          {error,_Reason} -> [] end end .

step(Proc,Name) ->
    case [ Task || Task <- tasks(Proc), element(#task.name,Task) == Name] of
         [T] -> T;
         [] -> #task{};
         E -> E end.

docs  (Proc) -> Proc#process.docs.
tasks (Proc) -> Proc#process.tasks.
events(Proc) -> Proc#process.events.
doc (R,Proc) -> {X,_} = bpe_env:find(env,Proc,R), case X of [A] -> A; _ -> X end.

% Emulate Event-Condition-Action Systems

'ECA'(Proc,Document,Cond) -> 'ECA'(Proc,Document,Cond,fun(_,_)-> ok end).
'ECA'(Proc,Document,Cond,Action) ->
    case Cond(Document,Proc) of
         true -> Action(Document,Proc), {reply,Proc};
         {false,Message} -> {{reply,Message},Proc#process.task,Proc};
         ErrorList -> io:format("ECA/4 failed: ~tp~n",[ErrorList]),
                      {{reply,ErrorList},Proc#process.task,Proc} end.

cache(Key, undefined) -> ets:delete(processes,Key);
cache(Key, Value) -> ets:insert(processes,{Key,till(calendar:local_time(), ttl()),Value}), Value.
cache(Key, Value, Till) -> ets:insert(processes,{Key,Till,Value}), Value.
cache(Key) ->
    Res = ets:lookup(processes,Key),
    Val = case Res of [] -> undefined; [Value] -> Value; Values -> Values end,
    case Val of undefined -> undefined;
                {_,infinity,X} -> X;
                {_,Expire,X} -> case Expire < calendar:local_time() of
                                  true ->  ets:delete(processes,Key), undefined;
                                  false -> X end end.

ttl() -> application:get_env(bpe,ttl,60*15).

till(Now,TTL) ->
    case is_atom(TTL) of
        true -> TTL;
        false -> calendar:gregorian_seconds_to_datetime(
                    calendar:datetime_to_gregorian_seconds(Now) + TTL)
    end.

reload(Module) ->
    {Module, Binary, Filename} = code:get_object_code(Module),
    case code:load_binary(Module, Filename, Binary) of
        {module, Module} ->
            {reloaded, Module};
        {error, Reason} ->
            {load_error, Module, Reason}
    end.

send(Pool, Message) -> syn:publish(term_to_binary(Pool),Message).
reg(Pool) -> reg(Pool,undefined).
reg(Pool, Value) ->
  case get({pool,Pool}) of
    undefined -> syn:register(term_to_binary(Pool),self(),Value),
                 syn:join(term_to_binary(Pool),self()),
                 erlang:put({pool,Pool},Pool);
     _Defined -> skip end.

unreg(Pool) ->
  case get({pool,Pool}) of
    undefined -> skip;
     _Defined -> syn:leave(Pool, self()),
                 erlang:erase({pool,Pool}) end.

%%%%

selectFlow(Proc,Name) ->
    case kvs:get("/bpe/flow/"++Proc#process.id,Name) of
         {ok,#sequenceFlow{name=Name}=Flow} -> Flow;
         {error,_} -> #sequenceFlow{name=Name} end.

completeFlow(Proc) ->
    Next = Proc#process.task,
    #sequenceFlow{name=Next,source=Src,target=Dst} = Flow = selectFlow(Proc,Next),
    Source = step(Proc,Src),
    Target = step(Proc,Dst),
    Resp = {Status,Reason,Reply,State} = bpe_task:task_action(Source,Src,Dst,Proc),
    bpe_proc:prepareNext(Target,State),
    bpe:trace(State,[],calendar:local_time(),Flow),
    kvs:append(Flow,"/bpe/flow/"++Proc#process.id),
    bpe_proc:debug(State,Next,Src,Dst,Status,Reason),
    Resp.
