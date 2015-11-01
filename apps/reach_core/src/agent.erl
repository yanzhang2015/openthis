%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A gen_fsm representing the agent's state.  When idle, channels are
%% available to ring.  When released, channels are not.
-module(agent).
-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-type(agent_opt() :: {'nodes', [atom()]} | 'logging').
-type(agent_opts() :: [agent_opt()]).

%% slow text is textual medias that do not requrie a particually fast
%% response, such as email.  Fast_text is textual medias that require rapid
%% replies, such as chat.
%-type(channel_category() :: 'dummy' | 'voice' | 'visual' | 'slow_text' | 'fast_text').
-record(state, {
	start_time,
	time_avail,
	agent_rec :: #agent{},
	original_endpoints = dict:new(),
	event_manager :: pid(),
	chan_count = 1 :: non_neg_integer(),
	channel_map = [] :: list(),
	agent_state :: #cpx_agent_state{},
	call_queues = [] :: list(),
	pending_handshakes = [] :: list(),
	pending_call_requests = 0 :: non_neg_integer(),
	pending_call_received = 0 :: non_neg_integer(),
	call_req_timer = undefined,
	top_pending_call = undefined
}).

-type(state() :: #state{}).
-define(GEN_FSM, true).
-define(CALLREQTIMEOUT, 500).
-include("gen_spec.hrl").

-define(default_category_blocks, [
	{dummy, none},
	{voice, all},
	{visual, all},
	{slow_text, self},
	{fast_text, others}
]).

%% gen_fsm exports
-export([
	init/1,
	handle_event/3,
	handle_sync_event/4,
	handle_info/3,
	terminate/3,
	code_change/4%,
	%format_status/2
]).
%% defined state exports
-export([
	idle/3,
	released/3
]).
%% defining async state exports
-export([
	idle/2,
	released/2
]).

%% other exports
-export([
	start/1,
	start/2,
	start_link/2,
	stop/1,
	stop/2,
	stop/3,
	set_release/2,
	set_release/3,
	go_available/1,
	go_released/1,
	go_released/2,
	add_skills/2,
	remove_skills/2,
	get_skills/1,
	change_profile/2,
	get_profile/1,
	query_state/1,
	dump_state/1,
	set_avail/2,
	get_release_state/1,
	register_rejected/1,
	set_connection/2,
	set_endpoint/3,
	set_endpoints/2,
	get_endpoint/2,
	blab/2,
	verify_queue/3,
	remove_queue/2,
	reply_handshake/3,
	assess_call/3,
	assess_call/5,
	notify_call/1,
	subscribe_events/2,
	subscribe_events/3,
	call_event_handler/3
]).

%% Channel Starters
-export([
	precall/2,
	prering/2,
	ringing/2
]).

%% For agent_channel use only
-export([
	set_channel/3
]).

% ======================================================================
% API
% ======================================================================

%% @doc Start an agent fsm for the passed in agent record `Agent' that is linked
%% to the calling process with the given options.
-spec(start_link/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start_link(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start_link(?MODULE, [Agent, Options], []).

%% @doc Start an agent fsm for the passed in agent record `Agent' with the given
%% options.
-spec(start/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start(?MODULE, [Agent, Options], []).

%% @doc Start an agent with default options.
-spec(start/1 :: (Agent :: #agent{}) -> {'ok', pid()}).
start(Agent) -> start(Agent, []).

%% @doc Stop the passed agent fsm `Pid'.
-spec(stop/1 :: (Pid :: pid()) -> 'ok').
stop(Pid) ->
	stop(Pid, normal, undefined).

%% @doc Stop the passed agent fsm `Pid' with `Reason'.
-spec(stop/2 :: (Pid :: pid(), Reason :: term()) -> 'ok').
stop(Pid, Reason) ->
	stop(Pid, Reason, undefined).

%% @doc Stop the passed agent fsm `Pid' with `Reason' and `Msg'.
-spec(stop/3 :: (Pid :: pid(), Reason :: term(), Msg :: term()) -> 'ok').
stop(Pid, Reason, Msg) ->
	gen_fsm:send_all_state_event(Pid, {stop, Reason, Msg}).

%% @doc go available
-spec go_available(pid()) -> ok.
go_available(Pid) ->
	set_release(Pid, none).

%% @doc Go released with default release code
-spec go_released(pid()) -> ok.
go_released(Pid) ->
	set_release(Pid, default).

%% @doc Go released with given release code
-spec go_released(pid(), release_code()) -> ok.
go_released(Pid, R) ->
	set_release(Pid, R).

%% @doc Set the agent released or idle.
-spec(set_release/2 :: (Pid :: pid(), Released :: 'none' | 'default' | release_code()) -> 'ok').
set_release(Pid, default) ->
	set_release(Pid, ?DEFAULT_RELEASE);
set_release(Pid, Released) ->
	gen_fsm:sync_send_event(Pid, {set_release, Released}).

set_release(Pid, Release, ConnMsg) ->
	gen_fsm:sync_send_event(Pid, {set_release, Release, ConnMsg}).

%% @doc link the given agent  `Pid' to the given connection `Socket'.
-spec(set_connection/2 :: (Pid :: pid(), Socket :: pid()) -> 'ok' | 'error').
set_connection(Pid, Socket) ->
	gen_fsm:sync_send_all_state_event(Pid, {set_connection, Socket}).

%% @doc When the agent manager can't register an agent, it 'casts' to this.
-spec(register_rejected/1 :: (Pid :: pid()) -> 'ok').
register_rejected(Pid) ->
	gen_fsm:send_event(Pid, register_rejected).

% actual functions we'll call
%% @private
-spec(expand_magic_skills/2 :: (State :: #agent{}, Skills :: [atom()]) -> [atom()]).
expand_magic_skills(State, Skills) ->
	lists:map(
		fun('_agent') -> {'_agent', State#agent.login};
		('_node') -> {'_node', node()};
		('_profile') -> {'_profile', State#agent.profile};
		(Skill) -> Skill
	end, Skills).

%% @doc Returns the entire agent record for the agent at `Pid'.
-spec(dump_state/1 :: (Pid :: pid()) -> #agent{}).
dump_state(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, dump_state).

set_avail(Pid, AvailChan) ->
	gen_fsm:sync_send_all_state_event(Pid, {set_avail, AvailChan}).

get_release_state(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, get_release_state).

%% @doc Returns the #call{} of the current state if there is on, otherwise
%% returns `invalid'.
%-spec(get_media/1 :: (Apid :: pid()) -> {ok, #call{}} | 'invalid').
%get_media(Apid) ->
%	gen_fsm:sync_send_event(Apid, get_media).

-spec(add_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
add_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {add_skills, Skills}).

-spec(remove_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
remove_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {remove_skills, Skills}).

-spec(get_skills/1 :: (Apid :: pid()) -> [atom() | {atom(), any()}]).
get_skills(Apid) when is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, get_skills).

-spec(change_profile/2 :: (Apid :: pid(), Profile :: string()) -> 'ok' | {'error', 'unknown_profile'}).
change_profile(Apid, Profile) ->
	gen_fsm:sync_send_all_state_event(Apid, {change_profile, Profile}).

-spec(get_profile/1 :: (Apid :: pid()) -> Profile :: string()).
get_profile(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, get_profile).

%% @doc Returns `{ok, Statename :: atom()}', where `Statename' is the current state of the agent at `Pid'.
-spec(query_state/1 :: (Pid :: pid()) -> {'ok', atom()}).
query_state(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, query_state).

%% @doc Send a message to the human agent.  If there's no connection, it black-holes.
-spec(blab/2 :: (Pid :: pid(), Text :: string()) -> 'ok').
blab(Pid, Text) ->
	gen_fsm:send_all_state_event(Pid, {blab, Text}).

%% @doc Get the endpoint for a given module from the agent record.
-spec(get_endpoint/2 :: (Module :: atom(), Agent :: #agent{}) -> {'ok', any()} | 'inband' | {'error', any()}).
get_endpoint(Module, Agent) when is_record(Agent, agent) ->
	find_endpoint(Module, Agent#agent.endpoints).

%% @doc Set the endpoint data for a specific module.  The calling process is
%% forced to do much of the verification that the module mentioned exists
%% and implements the gen_media behaviour.  Data can be 'inband',
%% {'module', atom()}, or arbitary data.
-spec(set_endpoint/3 :: (Agent :: pid(), Module :: atom(), Data :: any()) ->
'ok' | {'error', any()}).
set_endpoint(Agent, Module, Data) when is_pid(Agent), is_atom(Module) ->
	case code:ensure_loaded(Module) of
		{error, Err} ->
			{error, Err};
		{module, Module} ->
			case proplists:get_value(behaviour, Module:module_info(attributes)) of
				[gen_media] ->
					gen_fsm:sync_send_all_state_event(Agent, {set_endpoint, Module, Data});
				_ ->
					{error, badmodule}
			end
	end.

%% @doc Set multiple endpoints for an agent.
-spec(set_endpoints/2 :: (Agent :: pid(), Endpoints :: [{atom(), any()}]) -> 'ok').
set_endpoints(Agent, Endpoints) when is_pid(Agent) ->
	NewEndpoints = filter_endpoints(Endpoints),
    lager:info("Setting endpoints for Agent ~p: ~p", [Agent, Endpoints]),
	gen_fsm:send_all_state_event(Agent, {set_endpoints, NewEndpoints}).

precall(Apid, Media) ->
	gen_fsm:sync_send_event(Apid, {precall, Media}).

prering(Apid, Data) ->
	gen_fsm:sync_send_event(Apid, {prering, Data}).

ringing(Apid, Call) ->
	gen_fsm:sync_send_event(Apid, {ringing, Call}).

verify_queue(Pid, Qpid, Skills) ->
	gen_fsm:send_all_state_event(Pid, {verify_queue, Qpid, Skills}).

remove_queue(Pid, Qpid) ->
	gen_fsm:send_all_state_event(Pid, {remove_queue, Qpid}).

reply_handshake(Pid, Qpid, Reply) ->
	gen_fsm:send_all_state_event(Pid, {reply_handshake, Qpid, Reply}).

assess_call(Pid, Qpid, none) ->
	gen_fsm:send_all_state_event(Pid, {assess_call, Qpid, none}).

assess_call(Pid, Qpid, Aging, TopKey, TopValue) ->
	gen_fsm:send_all_state_event(Pid, {assess_call, Qpid, Aging, TopKey, TopValue}).

notify_call(Pid) ->
	gen_fsm:send_all_state_event(Pid, notify_call).

%% @doc Initialize and subscribe `Handler' to `Pid' events.
subscribe_events(Pid, Handler) ->
	subscribe_events(Pid, Handler, []).

%% @doc Initialize and subscribe `Handler' with initial `Args' to `Pid' events.
subscribe_events(Pid, Handler, Args) ->
	gen_fsm:send_all_state_event(Pid, {subscribe_events, Handler, Args}).

%% @doc Sends the given `Request' to a `Handler' of `Pid'.
call_event_handler(Pid, Handler, Request) ->
	gen_fsm:sync_send_all_state_event(Pid, {call_event_handler, Handler, Request}).

%% @doc Updates the channel state of the agent
-spec(set_channel/3 :: (Pid :: pid(), Channel :: pid(), State :: atom()) -> ok).
set_channel(Pid, Channel, State) ->
	gen_fsm:send_all_state_event(Pid, {set_channel, {Channel, State}}).

% ======================================================================
% INIT
% ======================================================================

%% @private
%-spec(init/1 :: (Args :: [#agent{}]) -> {'ok', 'released', #agent{}}).
init([Agent, _Options]) when is_record(Agent, agent) ->
	process_flag(trap_exit, true),
	OriginalEnds = Agent#agent.endpoints,
	#agent_profile{name = Profile, skills = Skills} = try agent_auth:get_profile(Agent#agent.profile) of
		{ok, P} ->
			P;
		_ ->
			lager:warning("Agent ~p has an invalid profile of ~p, using Default", [Agent#agent.login, Agent#agent.profile]),
			agent_auth:get_default_profile()
	catch
		error:{case_clause, {aborted, _}} ->
			#agent_profile{name = error}
	end,
	{FirstName, LastName} = get_agent_name(Agent#agent.login),
	ProfSkills = expand_magic_skills(Agent, Skills),
	InherentSkills = expand_magic_skills(Agent, Agent#agent.skills),
	MergedSkills = util:merge_skill_lists(ProfSkills, InherentSkills, ['_queue', '_brand']),
	Agent2 = Agent#agent{skills = MergedSkills, profile = Profile, source = self(),
						firstname = FirstName, lastname = LastName},
	agent_manager:update_skill_list(Agent2#agent.login, Agent2#agent.skills),
	StateName = case Agent#agent.release_data of
		undefined ->
			lager:info("Initialing vqueues handshake for agent ~p", [Agent#agent.login]),
			dispatch_manager:now_avail(self(), Agent2#agent.available_channels),
			idle;
		_Other ->
			dispatch_manager:end_avail(self()),
			released
	end,
	cpx_agent_event:agent_init(Agent2),
	AgentState = agent_state_manager:init(Agent2, StateName),
	{ok, EventMgr} = gen_event:start_link(),
	{ok, EventHandlers} = cpx_hooks:trigger_hooks(agent_feed_subscribe, [Agent2], all),
	lists:foreach(fun({Handler, Args}) ->
		gen_event:add_handler(EventMgr, Handler, Args)
	end, EventHandlers),
	State = #state{
		start_time = os:timestamp(),
		agent_rec = Agent2,
		original_endpoints = OriginalEnds,
		event_manager = EventMgr,
		agent_state = AgentState},
	init_gproc_prop({init, State}),
	gproc:reg({p, g, {cpx_profile, Profile}}, now()),
	{ok, StateName, State, 0}.

% ======================================================================
% IDLE
% ======================================================================

idle({set_release, Release, ConnMsg}, From, #state{agent_rec = Agent} = State) ->
	inform_connection(Agent, ConnMsg),
	idle({set_release, Release}, From, State);

idle({set_release, none}, _From, State) ->
	Queues = State#state.call_queues,
	Agent = State#state.agent_rec,
	CallReqTimer = grab_call(Agent#agent.login, Queues),
	CallRequests = length(Queues),
	{reply, ok, idle, State#state{pending_call_requests = CallRequests, call_req_timer = CallReqTimer}};
idle({set_release, {_Id, _Reason, Bias} = Release}, _From, #state{agent_rec = Agent, time_avail = LastAvail} = State) when Bias =< 1; Bias >= -1 ->
	dispatch_manager:end_avail(self()),
	agent_manager:set_avail(Agent#agent.login, []),
	Now = util:now(),
	NewAgent = Agent#agent{release_data = Release, last_change = Now},
	inform_connection(Agent, {set_release, Release, Now}),
	cpx_agent_event:change_release_state(NewAgent#agent.id, {released, Release}, Now),
	AgentState = agent_state_manager:set_release_state(Agent, released, State#state.agent_state),
	NewState = State#state{agent_rec = NewAgent, time_avail = undefined, agent_state = AgentState},
	set_gproc_prop({Agent#agent.release_data, NewState}),
	remove_agent(Agent#agent.login, State#state.call_queues),
	gen_event:notify(State#state.event_manager, {agent_feed,
		#cpx_agent_state_update{pid = self(), state = Release, old_state = Agent#agent.release_data, last_avail = LastAvail, agent = NewAgent}}),
	{reply, ok, released, NewState};

idle({precall, Call}, _From, #state{agent_rec = Agent, event_manager = EventManager, chan_count = ChCount} = State) ->
	case start_channel(Agent, Call, precall, EventManager, ChCount) of
		{ok, Pid, NewAgent} ->
			%inform_connection(Agent, {set_channel, Pid, precall, Call}),
			ChannelMap = State#state.channel_map ++ [{count_to_id(ChCount), Pid}],
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent, chan_count = ChCount + 1, channel_map = ChannelMap}};
		Else ->
			{reply, Else, idle, State}
	end;

idle({prering, Call}, From, #state{agent_rec = Agent, event_manager = EventManager, chan_count = ChCount} = State) ->
	{ok, AutoRelease} = cpx:get_env(release_on_ring_failure, true),
	case start_channel(Agent, Call, prering, EventManager, ChCount) of
		{ok, Pid, NewAgent} ->
			lager:debug("Started prering at ~p for agent ~s, caller ~p", [Pid, Agent#agent.login, Call#call.callerid]),
			%inform_connection(Agent, {set_channel, Pid, prering, Call}),
			ChannelMap = State#state.channel_map ++ [{count_to_id(ChCount), Pid}],
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent, chan_count = ChCount + 1, channel_map = ChannelMap}};
		{error, nochannel} ->
			lager:debug("Error ~p going to prering for agent ~s, caller ~p", [nochannel, Agent#agent.login, Call#call.callerid]),
			{reply, {error, nochannel}, idle, State};
		Else ->
			lager:info("Unexpected response ~p going to prering for agent ~s, caller ~p. Going to forced release.", [Else, Agent#agent.login, Call#call.callerid]),
			case AutoRelease of
				true ->
					case idle({set_release, ?DEFAULT_RELEASE, {forced_release, ring_init_failed}}, From, State) of
						{reply, ok, released, NewState} ->
							{reply, Else, released, NewState};
						ReleaseErr ->
							lager:debug("Failed to set agent ~p to released, got ~p", [ReleaseErr]),
							{reply, Else, idle, State}
					end;
				_ ->
					{reply, Else, idle, State}
			end
	end;

idle({ringing, Call}, _From, #state{agent_rec = Agent, event_manager = EventManager, chan_count = ChCount} = State) ->
	case start_channel(Agent, Call, ringing, EventManager, ChCount) of
		{ok, Pid, NewAgent} ->
			lager:debug("Started ringing (~s) ~p", [Agent#agent.login, Pid]),
			%inform_connection(Agent, {set_channel, Pid, ringing, Call}),
			ChannelMap = State#state.channel_map ++ [{count_to_id(ChCount), Pid}],
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent, chan_count = ChCount + 1, channel_map = ChannelMap}};
		Else ->
			{reply, Else, idle, State}
	end;

idle(Msg, _From, State) ->
	{reply, {invalid, Msg}, idle, State}.

idle(timeout, #state{agent_rec = Agent} = State) ->
	PendingHandshakes = init_handshake(Agent),
	lager:info("pending handshakes left: ~p", [PendingHandshakes]),
	{next_state, idle, State#state{pending_handshakes = PendingHandshakes}};

idle(Msg, State) ->
	lager:info("unhandled while idle: ~p", [Msg]),
	{next_state, idle, State}.

% ======================================================================
% RELEASED
% ======================================================================

released({set_release, none}, _From, #state{agent_rec = Agent} = State) ->
	dispatch_manager:now_avail(self(), Agent#agent.available_channels),
	agent_manager:set_avail(Agent#agent.login, Agent#agent.available_channels),
	Now = util:now(),
	NewAgent = Agent#agent{release_data = undefined, last_change = Now},
	inform_connection(Agent, {set_release, none, Now}),
	cpx_agent_event:change_release_state(NewAgent#agent.id, available, Now),
	AgentState = agent_state_manager:set_release_state(Agent, available, State#state.agent_state),
	NewState = State#state{agent_rec = NewAgent, time_avail = os:timestamp(), agent_state = AgentState},
	set_gproc_prop({Agent#agent.release_data, NewState}),
	gen_event:notify(State#state.event_manager, {agent_feed,
		#cpx_agent_state_update{pid = self(), state = undefined, old_state = Agent#agent.release_data, agent = NewAgent}}),
	Queues = State#state.call_queues,
	Agent = State#state.agent_rec,
	CallReqTimer = grab_call(Agent#agent.login, Queues),
	CallRequests = length(Queues),
	{reply, ok, idle, NewState#state{pending_call_requests = CallRequests, call_req_timer = CallReqTimer}};

released({set_release, default}, From, State) ->
	released({set_release, ?DEFAULT_RELEASE}, From, State);

released({set_release, {_Id, _Label, _Bias} = Release}, _From, #state{agent_rec = Agent, time_avail = LastAvail} = State) ->
	Now = util:now(),
	NewAgent = Agent#agent{release_data = Release, last_change = Now},
	inform_connection(Agent, {set_release, Release, Now}),
	cpx_agent_event:change_release_state(NewAgent#agent.id, Release, Now),
	AgentState = agent_state_manager:set_release_state(Agent, released, State#state.agent_state),
	NewState = State#state{agent_rec = NewAgent, time_avail = undefined, agent_state = AgentState},
	set_gproc_prop({Agent#agent.release_data, NewState}),
	remove_agent(Agent#agent.login, State#state.call_queues),
	gen_event:notify(State#state.event_manager, {agent_feed,
		#cpx_agent_state_update{pid = self(), state = Release, old_state = Agent#agent.release_data, last_avail = LastAvail, agent = NewAgent}}),
	{reply, ok, released, NewState};

released(Msg, _From, State) ->
	{reply, {error, Msg}, released, State}.

released(timeout, #state{agent_rec = Agent} = State) ->
	PendingHandshakes = init_handshake(Agent),
	lager:info("pending handshakes left: ~p", [PendingHandshakes]),
	{next_state, released, State#state{pending_handshakes = PendingHandshakes}};

released(Msg, State) ->
	lager:info("unhandled while released: ~p", [Msg]),
	{next_state, released, State}.

% ======================================================================
% HANDLE_SYNC_EVENT
% ======================================================================
handle_sync_event(get_skills, _From, StateName, #state{agent_rec = #agent{skills = Skills}} = State) ->
	{reply, Skills, StateName, State};
handle_sync_event({set_connection, Pid}, _From, StateName, #state{agent_rec = #agent{connection = undefined} = Agent} = State) ->
	link(Pid),
	dict:map(fun(ChanPid, V) ->
		agent_channel:set_connection(ChanPid, Pid),
		V
	end, Agent#agent.used_channels),
	NewAgent = Agent#agent{connection = Pid},
	case erlang:function_exported(cpx_supervisor, get_value, 1) of
		true ->
			case cpx_supervisor:get_value(motd) of
				{ok, Motd} ->
					inform_connection(NewAgent, {blab, Motd});
				_ ->
					ok
			end;
		false ->
			ok
	end,
	R = case Agent#agent.release_data of
		undefined -> none;
		O -> O
	end,
	inform_connection(NewAgent, {set_release, R}),
	gen_event:notify(State#state.event_manager, {agent_feed, {set_connection, Pid}}),
	{reply, ok, StateName, State#state{agent_rec = NewAgent}};

handle_sync_event(dump_state, _From, StateName, #state{agent_rec = Agent} = State) ->
	{reply, Agent, StateName, State};

handle_sync_event({set_avail, AvailChan}, _From, StateName, #state{agent_rec = Agent} = State) ->
	AgentLogin = Agent#agent.login,
	agent_manager:set_avail(AgentLogin, AvailChan),
	NewAgent = Agent#agent{available_channels=AvailChan},
	NewState = State#state{agent_rec=NewAgent},
	{reply, ok, StateName, NewState};

handle_sync_event(get_release_state, _From, Statename, #state{agent_rec = Agent} = State) ->
	{reply, Agent#agent.release_data, Statename, State};

handle_sync_event({set_connection, _Pid}, _From, StateName, #state{agent_rec = Agent} = State) ->
	lager:warning("An attempt to set connection to ~w when there is already a connection ~w", [_Pid, Agent#agent.connection]),
	{reply, error, StateName, State};

handle_sync_event({change_profile, Profile}, _From, StateName, #state{agent_rec = Agent} = State) ->
	Now = util:now(),
	OldProfile = Agent#agent.profile,
	%% TODO skills might have changed since first accessed
	OldSkills = case agent_auth:get_profile(OldProfile) of
		{ok, #agent_profile{skills = Skills}} ->
			Skills;
		_ ->
			[]
	end,
	case agent_auth:get_profile(Profile) of
		{ok, #agent_profile{name = Profile, skills = Skills2}} ->
			NewAgentSkills = util:subtract_skill_lists(Agent#agent.skills, expand_magic_skills(Agent, OldSkills)),
			NewAgentSkills2 = util:merge_skill_lists(NewAgentSkills, expand_magic_skills(Agent#agent{profile = Profile}, Skills2), ['_queue', '_brand']),
			Newagent = Agent#agent{skills = NewAgentSkills2, profile = Profile},
			Deatils = [
				{profile, Newagent#agent.profile},
				{login, Newagent#agent.login},
				{skills, Newagent#agent.skills}
			],
			cpx_agent_event:change_profile(Newagent#agent.id, Profile, Now),
			cpx_monitor:set({agent, Agent#agent.id}, Deatils),
			inform_connection(Agent, {change_profile, Profile}),
			inform_connection(Agent, {set_release, Agent#agent.release_data, Agent#agent.last_change}),
%			DroppedSkills = OldSkills -- NewAgentSkills2,
%			GainedSkills = NewAgentSkills2 -- OldSkills,
%			ProfChangeRec = #agent_profile_change{
%				id = Agent#agent.id,
%				agent = Agent#agent.login,
%				old_profile = OldProfile,
%				new_profile = Profile,
%				skills = NewAgentSkills2,
%				dropped_skills = DroppedSkills,
%				gained_skills = GainedSkills
%			},
%			cpx_monitor:info({agent_profile, ProfChangeRec}),
			{reply, ok, StateName, State#state{agent_rec = Newagent}};
		_ ->
			{reply, {error, unknown_profile}, StateName, State}
	end;
handle_sync_event(get_profile, _From, StateName, #state{agent_rec = Agent} = State) ->
	{reply, Agent#agent.profile, StateName, State};
handle_sync_event({set_endpoint, Module, Data}, _From, StateName, #state{agent_rec = Agent, original_endpoints = OEnds} = State) ->
	case priv_set_endpoint(Agent, Module, Data) of
		{ok, NewAgent} ->
			NewOEnds = dict:store(Module, Data, OEnds),
			agent_manager:set_ends(Agent#agent.login, dict:fetch_keys(NewAgent#agent.endpoints)),
			{reply, ok, StateName, State#state{agent_rec = NewAgent, original_endpoints = NewOEnds}};
		{error, _Err} = Error ->
			{reply, Error, StateName, State}
	end;

handle_sync_event({call_event_handler, Handler, Request}, _From, StateName, State) ->
	Reply = gen_event:call(State#state.event_manager, Handler, Request),
	{reply, Reply, StateName, State};

handle_sync_event(Msg, _From, StateName, State) ->
	{reply, {error, Msg}, StateName, State}.

% ======================================================================
% HANDLE_EVENT
% ======================================================================

handle_event({blab, Text}, Statename, #state{agent_rec = Agent} = State) ->
	lager:debug("sending blab ~p", [Text]),
	inform_connection(Agent, {blab, Text}),
	{next_state, Statename, State};

handle_event({stop, Reason, Msg}, _StateName, #state{agent_rec = Agent} = State) ->
	inform_connection(Agent, {stop, Reason, Msg}),

	{stop, Reason, State};

handle_event({add_skills, Skills}, StateName, #state{agent_rec = Agent} = State) ->
	NewSkills = util:merge_skill_lists(expand_magic_skills(Agent, Skills), Agent#agent.skills, ['_queue', '_brand']),
	agent_manager:update_skill_list(Agent#agent.login, NewSkills),
	Newagent = Agent#agent{skills = NewSkills},
	{next_state, StateName, State#state{agent_rec = Newagent}};

handle_event({remove_skills, Skills}, StateName, #state{agent_rec = Agent} = State) ->
	NewSkills = util:subtract_skill_lists(Agent#agent.skills, expand_magic_skills(Agent, Skills)),
	agent_manager:update_skill_list(Agent#agent.login, NewSkills),
	Newagent = Agent#agent{skills = NewSkills},
	{next_state, StateName, State#state{agent_rec = Newagent}};

handle_event({set_endpoints, InEnds}, StateName, #state{agent_rec = Agent} = State) ->
	lager:info("Setting agent ~p endpoints to ~p", [Agent#agent.login, InEnds]),
	Ends = sort_endpoints(InEnds),
	NewAgent = priv_set_endpoints(Agent, State#state.original_endpoints, Ends),
	agent_manager:set_ends(NewAgent#agent.login, dict:fetch_keys(NewAgent#agent.endpoints)),
	{next_state, StateName, State#state{agent_rec = NewAgent}};

handle_event({verify_queue, QPid, Skills}, StateName, #state{agent_rec = Agent, call_queues = Queues} = State) ->
	AgentSkills = Agent#agent.skills,
	{NewQueues, CallRequests, ReqTimer} = case Skills -- AgentSkills of
		[] ->
			{CallReqs, Timer} = case StateName of
				idle ->
						Agent = State#state.agent_rec,
						CallReqTimer = grab_call(Agent#agent.login, [QPid]),
						{1, CallReqTimer};
				_ -> {0, undefined}
			end,
			{[QPid | Queues], CallReqs, Timer};
		_ -> {Queues, 0, undefined}
	end,
	{next_state, StateName, State#state{call_queues = NewQueues, pending_call_requests = CallRequests, call_req_timer = ReqTimer}};

handle_event({remove_queue, Qpid}, StateName, #state{call_queues = Queues} = State) ->
	lager:info("Deleting queue ~p from agent ~p queue list", [Qpid, self()]),
	NewQueues = lists:delete(Qpid, Queues),
	{next_state, StateName, State#state{call_queues = NewQueues}};

handle_event({reply_handshake, Qpid, Reply}, StateName, #state{call_queues=Queues,
		pending_handshakes = PendingHandshakes} = State) ->
	lager:info("received handshake reply from Q ~p with reply ~p", [Qpid, Reply]),
	NewQueues = case Reply of
		accept -> [Qpid|Queues];
		reject -> Queues
	end,
	RemHandShakes = PendingHandshakes - 1,
	lager:info("remaining handshakes left: ~p", [RemHandShakes]),
	%%TODO assumes all vqueues reply... need timer
	{CallRequests, Timer} = case RemHandShakes of
		0 -> case StateName of
				idle ->
					Agent = State#state.agent_rec,
					CallReqTimer = grab_call(Agent#agent.login, NewQueues),
					{length(NewQueues), CallReqTimer};
				released -> {0, undefined}
			end;
		_ -> {0, undefined}
	end,
	{next_state, StateName, State#state{call_queues=NewQueues, pending_handshakes = RemHandShakes,
										pending_call_requests = CallRequests, call_req_timer = Timer}};

handle_event({assess_call, Qpid, none}, StateName, State) ->
	CallTimer = State#state.call_req_timer,
	CallReq = State#state.pending_call_requests,
	CallRcvd = State#state.pending_call_received + 1,
	Top = State#state.top_pending_call,
	lager:info("request from ~p, CallRequests is ~p, CallReceived is ~p", [Qpid, CallReq, CallRcvd]),
	State2 = case CallReq =< CallRcvd of
		true ->
			cancel_timer(CallTimer),
			case Top of
				undefined ->
					State#state{pending_call_requests = 0, pending_call_received = 0, top_pending_call = undefined,
					call_req_timer = undefined};
				{NewQ, _, _, _} ->
					lager:info("all call requests received... claiming top priority call"),
					Agent = State#state.agent_rec,
					remove_agent(Agent#agent.login, State#state.call_queues),
					reach_vqueue:assign_call(NewQ, self()),
					State#state{pending_call_requests = 0, pending_call_received = 0, top_pending_call = undefined,
					call_req_timer = undefined}
			end;
		false -> State#state{pending_call_received = CallRcvd, top_pending_call = Top}
	end,
	{next_state, StateName, State2};

handle_event({assess_call, Qpid, Aging, Key, Value}, StateName, State) ->
	lager:info("assessing call from Q ~p with aging factor ~p, key ~p and value ~p", [Qpid, Aging, Key, Value]),
	CallTimer = State#state.call_req_timer,
	CallReq = State#state.pending_call_requests,
	CallRcvd = State#state.pending_call_received + 1,
	{NewQ, _, _, _} = NewTop =
		case State#state.top_pending_call of
			undefined -> {Qpid, Aging, Key, Value};
			{OldQ, OldAging, OldKey, OldValue} ->
                    lager:debug("state.top_pending_call ~p",[State#state.top_pending_call]),
                    case compare_keys(OldAging, OldKey, Aging, Key) of
                        OldKey -> {OldQ, OldAging, OldKey, OldValue};
                        Key -> {Qpid, Aging, Key, Value}
                    end
		end,
	lager:info("request from ~p, CallRequests is ~p, CallReceived is ~p", [Qpid, CallReq, CallRcvd]),
	State2 = case CallReq =< CallRcvd of
		true ->
				cancel_timer(CallTimer),
				lager:info("all call requests received... claiming top priority call"),
				reach_vqueue:assign_call(NewQ, self()),
				Agent = State#state.agent_rec,
				remove_agent(Agent#agent.login, State#state.call_queues),
				State#state{pending_call_requests = 0, pending_call_received = 0, top_pending_call = undefined,
					call_req_timer = undefined};
		false -> State#state{pending_call_received = CallRcvd, top_pending_call = NewTop,
					call_req_timer = undefined}
	end,
	{next_state, StateName, State2};

handle_event(notify_call, StateName, #state{call_queues=Queues} = State) ->
	lager:info("Agent ~p received notify_call, grabbing calls from queues", [self()]),
	Agent = State#state.agent_rec,
	CallReqTimer = grab_call(Agent#agent.login, Queues),
	CallRequests = length(Queues),
	{next_state, StateName, State#state{pending_call_requests = CallRequests, call_req_timer = CallReqTimer}};

handle_event({subscribe_events, Handler, Args}, StateName, State) ->
	gen_event:add_handler(State#state.event_manager, Handler, Args),
	{next_state, StateName, State};

handle_event({set_channel, {Channel, ChanSt}}, StateName, State) ->
	AgentState = agent_state_manager:set_channel_state(State#state.agent_rec, Channel, ChanSt, State#state.agent_state),
	% {CallReqs, Timer} = case AgentState#cpx_agent_state.ustate of
	% 	idle ->
	% 		Queues = State#state.call_queues,
	% 		Agent = State#state.agent_rec,
	% 		lager:info("Re-grab calls on idle channel state"),
	% 		CallReqTimer = grab_call(Agent#agent.login, Queues),
	% 		{length(Queues), CallReqTimer};
	% 	_ -> {0, undefined}
	% end,
	{next_state, StateName, State#state{agent_state = AgentState}};
		% pending_call_requests = CallReqs, call_req_timer = Timer}};

handle_event(_Msg, StateName, State) ->
	{next_state, StateName, State}.

% ======================================================================
% HANDLE_INFO
% ======================================================================

handle_info({'EXIT', From, Reason}, StateName, #state{agent_rec = #agent{connection = From} = _Agent} = State) ->
	lager:warning("agent connection died while ~w", [StateName]),
	Stopwhy = case Reason of
		normal ->
			normal;
		shutdown ->
			shutdown;
		Other ->
			{error, conn_exit, Other}
	end,
	{stop, Stopwhy, State};

handle_info({'EXIT', Pid, Reason}, StateName, #state{agent_rec = Agent, channel_map = ChannelMap} = State) ->
	case dict:find(Pid, Agent#agent.used_channels) of
		error ->
			case get_endpoint_by_pid(Pid, Agent#agent.endpoints) of
				error ->
					case whereis(agent_manager) of
						undefined ->
							agent_manager_exit(Reason, StateName, State);
						From when is_pid(From), From =:= Pid ->
							agent_manager_exit(Reason, StateName, State);
						_Else ->
							lager:info("unknown exit from ~p", [Pid]),
							{next_state, StateName, State}
					end;
				{End, Orig} ->
					Ends0 = dict:erase(End, Agent#agent.endpoints),
					Agent0 = Agent#agent{endpoints = Ends0},
					PrivRes = priv_set_endpoint(Agent0, End, Orig),
					Agent1 = case PrivRes of
						{ok, AgentEnds} -> AgentEnds;
						{error, Err} ->
							lager:notice("Endpoint ~p's pid exited, could not recover due to ~p", [End, Err]),
							Agent#agent{endpoints = Ends0}
					end,
					{next_state, StateName, State#state{agent_rec = Agent1}}
			end;
		{ok, _Type} ->
			lager:info("Agent channel stopped for agent ~p", [Agent#agent.login]),
			NewDict = dict:erase(Pid, Agent#agent.used_channels),
			Blockers = dict:fold(fun(_, ChanType, Acc) -> [ChanType | Acc] end, [], NewDict),
			NewAvail = block_channels(Blockers, Agent#agent.all_channels, ?default_category_blocks),
			lager:debug("unblocking channels ~p", [NewAvail]),
			NewAgent = Agent#agent{
				available_channels = NewAvail,
				used_channels = NewDict
			},
			{CallReqs, Timer} = case StateName of
				idle ->
					Queues = State#state.call_queues,
					Agent = State#state.agent_rec,
					lager:info("Re-grab calls on channel_died"),
					CallReqTimer = grab_call(Agent#agent.login, Queues),
					dispatch_manager:now_avail(self(), NewAvail),
					agent_manager:set_avail(Agent#agent.login, NewAvail),
					{length(Queues), CallReqTimer};
				_ ->
					{State#state.pending_call_requests, State#state.call_req_timer}
			end,
			{ChannelId, NewChannelMap} = case lists:keytake(Pid, 2, ChannelMap) of
						{value, {ChanId, Pid}, NewChMap} -> {ChanId, NewChMap};
						_ -> {undefined, ChannelMap}
			end,
			inform_connection(Agent, {channel_died, ChannelId, NewAvail, util:now_ms()}), %%TODO how to get ChanId
			% cpx_agent_event:change_agent_channel(Pid, exit, exit),

			{next_state, StateName, State#state{agent_rec = NewAgent, channel_map = NewChannelMap,
				pending_call_requests = CallReqs, call_req_timer = Timer}}
	end;

handle_info(call_req_timeout, Statename, State) ->
	lager:info("call requests timed out... ignoring other queues"),
	State2 = case State#state.top_pending_call of
			undefined -> State#state{pending_call_requests = 0, pending_call_received = 0};
			{Qpid, _Age, _Key, _Value} ->
				reach_vqueue:assign_call(Qpid, self()),
				Agent = State#state.agent_rec,
				remove_agent(Agent#agent.login, State#state.call_queues),
				State#state{pending_call_requests = 0, pending_call_received = 0, top_pending_call = undefined}
	end,
	{next_state, Statename, State2};

handle_info(Msg, Statename, State) ->
	lager:debug("Disregarding:  ~p", [Msg]),
	{next_state, Statename, State}.

% ======================================================================
% TERMINATE
% ======================================================================

%% @private
%-spec(terminate/3 :: (Reason :: any(), StateName :: statename(), State :: #state{}) -> 'ok').
terminate(Reason, StateName, #state{agent_rec = Agent} = State) ->
	AgentState = State#state.agent_state,
	lager:notice("Agent terminating:  ~p, State:  ~p", [Reason, StateName]),
	lager:notice("Removing self ~p from all vqueues", [self()]),
	remove_agent(Agent#agent.login, State#state.call_queues),
	remove_eligible(Agent#agent.login, State#state.call_queues),
	cpx_monitor:drop({agent, Agent#agent.id}),
	agent_state_manager:set_offline(Agent, AgentState),
	send_gproc_logout({Agent#agent.release_data, State}),
	ok.

% ======================================================================
% CODE_CHANGE
% ======================================================================

%% @private
%-spec(code_change/4 :: (OldVsn :: string(), StateName :: statename(), State :: #state{}, Extra :: any()) -> {'ok', statename(), #state{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
	{ok, StateName, State}.

% ======================================================================
% FORMAT_STATUS
% ======================================================================

%-spec(format_status/2 :: (Cause :: atom(), Data :: [any()]) -> any()).
%format_status(normal, [PDict, State]) ->
%	[{data, [{"State", format_status(terminate, [PDict, State])}]}];
%format_status(terminate, [_PDict, #state{agent_rec = Agent} = _State]) ->
%	% prevent client data from being dumped
%	Newagent = case Agent#agent.statedata of
%		#call{client = Client} = Call when is_record(Call#call.client, client) ->
%			Client = Call#call.client,
%			Agent#agent{statedata = Call#call{client = Client#client{options = []}}};
%		{onhold, #call{client = Client} = Call, calling, ID} when is_record(Client, client) ->
%			Agent#agent{statedata = {onhold, Call#call{client = Client#client{options = []}}, calling, ID}};
%		_ ->
%			Agent
%	end,
%	[Newagent#agent{password = "redacted"}].

% ======================================================================
% INTERNAL
% ======================================================================

init_handshake(#agent{login = Login, skills = Skills}) ->
	lager:info("Agent initializing handshake to vqueues."),
	Vqueues = reach_vqueue_manager:get_all(),
	[reach_vqueue:handshake(Qpid, self(), Login, Skills) || Qpid <- Vqueues],
	length(Vqueues).

grab_call(AgentLogin, Vqueues) ->
	lager:info("~p requesting calls from Qs ~p", [AgentLogin, Vqueues]),
	[reach_vqueue:request_call(Qpid, self(), AgentLogin) || Qpid <- Vqueues],
	Timer = erlang:send_after(?CALLREQTIMEOUT, self(), call_req_timeout),
	lager:info("created timer ~p for call req of agent ~p", [Timer, AgentLogin]),
	Timer.

remove_agent(Login, Queues) ->
	[reach_vqueue:remove_agent(Qpid, self(), Login) || Qpid <- Queues].

remove_eligible(Login, Queues) ->
	[reach_vqueue:remove_eligible(Qpid, self(), Login) || Qpid <- Queues].

compare_keys(AgingA, {PrioA, MsA} = KeyA, AgingB, {PrioB, MsB} = KeyB) ->
	case PrioA == PrioB of
		true ->
				Now = ouc_time:now_micro(),
				MicroMsA = ouc_time:now_micro(MsA),
				MicroMsB = ouc_time:now_micro(MsB),
				AgeA = (Now - MicroMsA) * AgingA,
				AgeB = (Now - MicroMsB) * AgingB,
				lager:info("AgeA = ~p, MsA = ~p, AgingA = ~p", [AgeA, MicroMsA, AgingA]),
				lager:info("AgeB = ~p, MsB = ~p, AgingB = ~p", [AgeB, MicroMsB, AgingB]),
				case AgeA > AgeB  of
					true -> KeyA;
					false -> KeyB
				end;
		false -> case PrioA < PrioB of %%TODO priority???
					true -> KeyA;
					false -> KeyB
				end
	end.

cancel_timer(Timer) ->
	case Timer of
		undefined -> lager:info("Cannot cancel undefined timer.");
		_ -> lager:info("Timer ~p cancelled", [Timer]),
			 timer:cancel(Timer)
	end.

get_endpoint_by_pid(_Pid, []) ->
	error;

get_endpoint_by_pid(Pid, [{End, {Orig, Pid}} | _]) ->
	{End, Orig};

get_endpoint_by_pid(Pid, [_Head | Tail]) ->
	get_endpoint_by_pid(Pid, Tail);

get_endpoint_by_pid(Pid, EndpointDict) ->
	Ends = dict:to_list(EndpointDict),
	get_endpoint_by_pid(Pid, Ends).

find_endpoint(Module, Ends) ->
	case dict:find(Module, Ends) of
		error -> {error, notfound};
		{ok, {_, inband}} -> inband;
		{ok, {_, {module, NewMod}}} -> find_endpoint(NewMod, Ends);
		{ok, Data} -> {ok, Data}
	end.

% ----------------------------------------------------------------------

priv_set_endpoint(_Agent, Module, {module, Module}) ->
	lager:debug("endpoint ~s is a circular reference", [Module]),
	{error, self_reference};
priv_set_endpoint(Agent, Module, {module, OtherMod} = Endpoint) ->
	case dict:find(OtherMod, Agent#agent.endpoints) of
		error ->
			lager:debug("Endpoint ~s references non-existant endpoing ~s", [Module, OtherMod]),
			{error, module_noexists};
		{ok, _} ->
			NewEndpoints = dict:store(Module, Endpoint, Agent#agent.endpoints),
			NewAgent = Agent#agent{endpoints = NewEndpoints},
			inform_connection(Agent, {new_endpoint, Module, Endpoint}),
			{ok, NewAgent}
	end;
priv_set_endpoint(Agent, Module, Data) ->
	case catch Module:prepare_endpoint(Agent, Data) of
		{error, Err} ->
			lager:debug("Didn't set endpoint ~s due to ~p", [Module, Err]),
			{error, Err};
		{ok, NewData} ->
			NewEndpoints = dict:store(Module, {Data, NewData}, Agent#agent.endpoints),
			NewAgent = Agent#agent{endpoints = NewEndpoints},
			inform_connection(Agent, {new_endpoint, Module, NewData}),
			{ok, NewAgent};
		Else ->
			lager:notice("prepare endpoint failed:  ~p", [Else]),
			{error, Else}
	end.

priv_set_endpoints(Agent, _, []) ->
	Agent;
priv_set_endpoints(Agent, OEnds, [{Module, Data} | Tail]) ->
	case priv_set_endpoint(Agent, Module, Data) of
		{ok, NewAgent} ->
			NewOEnds = dict:store(Module, Data, OEnds),
			priv_set_endpoints(NewAgent, NewOEnds, Tail);
		_ ->
			priv_set_endpoints(Agent, OEnds, Tail)
	end.

filter_endpoints(Endpoints) ->
	filter_endpoints(Endpoints, []).

filter_endpoints([], Acc) ->
	lists:reverse(Acc);
filter_endpoints([{Module, _Data} = Head | Tail], Acc) ->
	case code:ensure_loaded(Module) of
		{error, Err} ->
			lager:debug("Code not loaded for endpoint ~s:  ~p", [Module, Err]),
			filter_endpoints(Tail, Acc);
		{module, Module} ->
			case proplists:get_value(behaviour, Module:module_info(attributes)) of
				[gen_media] ->
					filter_endpoints(Tail, [Head | Acc]);
				_ ->
					lager:debug("endpoint ~s is not a gen_media", [Module]),
					filter_endpoints(Tail, Acc)
			end
	end.

sort_endpoints(Ends) ->
	{Full, Referencers} = lists:partition(fun sort_endpoint_pred/1, Ends),
	Full ++ Referencers.

sort_endpoint_pred({_Module, {module, Atom}}) when is_atom(Atom) ->
	false;
sort_endpoint_pred(_) ->
	true.

inform_connection(#agent{connection = undefined}, _Msg) ->
	ok;
inform_connection(#agent{connection = Conn}, Msg) ->
	Conn ! {agent, Msg}.

start_channel(Agent, Call, StateName, EventManager, ChCount) ->
	ChanAvail = lists:member(Call#call.type, Agent#agent.available_channels),
	EndPoint = get_endpoint(Call#call.source_module, Agent),
	case {ChanAvail, EndPoint} of
		{false, _} ->
			{error, nochannel};
		{true, {error, notfound}} ->
			{error, noendpoint};
		{true, {ok, {_Orig, Endpoint}}} ->
			ChanId = count_to_id(ChCount),
			case agent_channel:start_link(Agent, Call, Endpoint, StateName, EventManager, ChanId) of
				{ok, Pid} ->
					Available = block_channels(Call#call.type, Agent#agent.available_channels, ?default_category_blocks),
					dispatch_manager:now_avail(self(), Available),
					agent_manager:set_avail(Agent#agent.login, Available),
					NewAgent = Agent#agent{
						available_channels = Available,
						used_channels = dict:store(Pid, Call#call.type, Agent#agent.used_channels)
					},
					lager:info("Agent channel started for agent ~p", [Agent#agent.login]),
					{ok, Pid, NewAgent};
				Else ->
					{error, Else}
			end
	end.

block_channels(Channel, Blockables, BlocklistDefs) when is_atom(Channel) ->
	block_channels([Channel], Blockables, BlocklistDefs);
block_channels(_, [], _) ->
	[];
block_channels([], Blockables, _) ->
	Blockables;
block_channels([Chan | Tail], InBlockables, BlocklistDefs) ->
	Blocklist = proplists:get_value(Chan, BlocklistDefs, []),
	Blockables = lists:delete(Chan, InBlockables),
	case Blocklist of
		all ->
			[];
		none ->
			block_channels(Tail, Blockables, BlocklistDefs);
		self ->
			NewBlockables = [B || B <- Blockables, B =/= Chan],
			block_channels(Tail, NewBlockables, BlocklistDefs);
		others ->
			NewBlockables = [B || B <- Blockables, B == Chan],
			block_channels(Tail, NewBlockables, BlocklistDefs);
		List ->
			NewBlockables = [B || B <- Blockables, not lists:member(B, List)],
			block_channels(Tail, NewBlockables, BlocklistDefs)
	end.

%% @private
-spec(agent_manager_exit/3 :: (Reason :: any(), StateName :: statename(), State :: #state{}) -> {'stop', 'normal', #state{}} | {'stop', 'shutdown', #state{}} | {'stop', 'timeout', #state{}} | {'next_state', statename(), #state{}}).
agent_manager_exit(Reason, StateName, State) ->
	case Reason of
		normal ->
			lager:info("Agent manager exited normally", []),
			{stop, normal, State};
		shutdown ->
			lager:info("Agent manager shutdown", []),
			{stop, shutdown, State};
		_Else ->
			lager:info("Agent manager exited abnormally with reason ~p", [Reason]),
			wait_for_agent_manager(5, StateName, State)
	end.

-spec(wait_for_agent_manager/3 :: (Count :: non_neg_integer(), StateName :: statename(), State :: #state{}) -> {'stop', 'timeout', #state{}} | {'next_state', statename(), #state{}}).
wait_for_agent_manager(0, _StateName, State) ->
	lager:warning("Timed out waiting for agent manager respawn", []),
	{stop, timeout, State};
wait_for_agent_manager(Count, StateName, #state{agent_rec = Agent} = State) ->
	case whereis(agent_manager) of
		undefined ->
			timer:sleep(1000),
			wait_for_agent_manager(Count - 1, StateName, State);
		Else when is_pid(Else) ->
			lager:info("Agent manager respawned as ~p", [Else]),
			% this will throw an error if the agent is already registered as
			% a different pid and that error will crash this process
			lager:info("Notifying new agent manager of agent ~p at ~p", [Agent#agent.login, self()]),
			Time = util:now(),
			agent_manager:notify(Agent#agent.login, Agent#agent.id, self(), Time, Agent#agent.skills),
			{next_state, StateName, State}
	end.


init_gproc_prop({_, State}) ->
	Prop = get_agent_prop(State),
	gproc:reg({p, g, cpx_agent}, Prop),

	Event = #cpx_agent_login{pid = self(), now = now(), prop = Prop},
	gproc:send({p, g, cpx_agent_change}, Event).

set_gproc_prop({PrevReleaseData, State}) ->
	Prop = get_agent_prop(State),
	gproc:set_value({p, g, cpx_agent}, Prop),

	Event = #cpx_agent_state_update{pid = self(), now = now(), state = Prop#cpx_agent_prop.state, old_state = get_agent_state(PrevReleaseData), prop = Prop},
	gproc:send({p, g, cpx_agent_change}, Event).

send_gproc_logout({_, State}) ->
	Prop = get_agent_prop(State),

	Event = #cpx_agent_logout{pid = self(), now = now(), prop = Prop},
	gproc:send({p, g, cpx_agent_change}, Event).

-spec get_agent_prop(#state{}) -> #cpx_agent_prop{}.
get_agent_prop(State) ->
	StartTime = State#state.start_time,
	TimeAvail = State#state.time_avail,
	Agent = State#state.agent_rec,
	Login = Agent#agent.login,
	Profile = Agent#agent.profile,
	Skills = Agent#agent.skills,
	AgentState = get_agent_state(Agent#agent.release_data),
	#cpx_agent_prop{login=Login, profile=Profile, skills=Skills, state=AgentState, start_time=StartTime, time_avail=TimeAvail}.

-spec get_agent_state(release_code() | 'undefined') -> init | available | {released, term()}.
get_agent_state(Release) ->
	case Release of
		init ->
			init;
		undefined ->
			available;
		_ ->
			{released, Release}
	end.

get_agent_name(Login) ->
	case agent_auth:get_agent(Login) of
		{ok, AgentAuth} -> {AgentAuth#agent_auth.firstname,
							AgentAuth#agent_auth.lastname};
		_ -> {undefined, undefined}
	end.

count_to_id(Count) ->
	"ch" ++ erlang:integer_to_list(Count).

% set_cpx_monitor_release(#agent{release_data = {Id, Reason, Bias}} = Agent) ->
% 	set_cpx_monitor(Agent, [{released, true}, {reason, Reason}, {bias, Bias}, {reason_id, Id}]);
% set_cpx_monitor_release(#agent{release_data = undefined} = Agent) ->
% 	set_cpx_monitor(Agent, [{released, false}]).

% set_cpx_monitor(State, Otherdeatils)->
% 	set_cpx_monitor(State, Otherdeatils, ignore).

% set_cpx_monitor(State, Otherdeatils, Watch) ->
% 	Deatils = lists:append([
% 		{profile, State#agent.profile},
% 		{login, State#agent.login},
% 		{skills, State#agent.skills}],
% 	Otherdeatils),
% 	cpx_monitor:set({agent, State#agent.id}, Deatils, Watch).

-ifdef(TEST).

make_agent(Opts) ->
	Fields = record_info(fields, agent),
	BaseAgent = #agent{
		login = "agent",
		source = self()
	},
	make_agent(Opts, Fields, BaseAgent).

make_agent([], _Fields, Agent) ->
	Agent;
make_agent([{Key, Value} | Tail], Fields, Agent) when is_atom(Key) ->
	NewAgent = case util:list_index(Key, Fields) of
		0 ->
			Agent;
		X ->
			setelement(X+1, Agent, Value)
	end,
	make_agent(Tail, Fields, NewAgent);
make_agent([_ | Tail], Fields, Agent) ->
	make_agent(Tail, Fields, Agent).

external_api_test_() ->
	{setup, fun() ->
		meck:new(gen_fsm, [unstick]),
		Pid = util:zombie(),

		meck:expect(gen_fsm, start, fun(agent, [_, _], []) -> {ok, Pid} end),
		meck:expect(gen_fsm, start_link, fun(agent, [_, _], []) -> {ok, Pid} end),
		meck:expect(gen_fsm, send_event, fun(_, _) -> ok end),
		meck:expect(gen_fsm, sync_send_event, fun(_, _) -> ok end),
		meck:expect(gen_fsm, send_all_state_event, fun(_, _) -> ok end),
		meck:expect(gen_fsm, sync_send_all_state_event, fun(_, _) -> ok end),

		Pid
	end,
	fun(_) ->
		meck:unload()
	end,
	fun(Pid) -> [
		{"start/1", fun() ->
			Agent = make_agent([]),

			agent:start(Agent),
			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, start, [agent, [Agent, []], []]))
		end},
		{"start/2", fun() ->
			Agent = make_agent([]),
			Options = [],

			agent:start(Agent, Options),
			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, start, [agent, [Agent, Options], []]))
		end},
		{"start_link/2", fun() ->
			Agent = make_agent([]),
			Options = [],

			agent:start_link(Agent, Options),
			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, start_link, [agent, [Agent, Options], []]))
		end},
		{"stop/1", fun() ->
			agent:stop(Pid),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, send_all_state_event, [Pid, {stop, normal, undefined}]))
		end},
		{"set_release/2 default", fun() ->
			agent:set_release(Pid, default),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_event, [Pid, {set_release, ?DEFAULT_RELEASE}]))
		end},
		{"set_release/2 other", fun() ->
			Release = none,
			agent:set_release(Pid, Release),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_event, [Pid, {set_release, Release}]))
		end},
		{"set_connection/2", fun() ->
			Connection = util:zombie(),

			agent:set_connection(Pid, Connection),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, {set_connection, Connection}]))
		end},
		{"register_rejected/1", fun() ->
			agent:register_rejected(Pid),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, send_event, [Pid, register_rejected]))
		end},
		{"dump_state/1", fun() ->
			agent:dump_state(Pid),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, dump_state]))
		end},
		{"add_skills/2", fun() ->
			Skills = [tech, spanish],
			agent:add_skills(Pid, Skills),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, {add_skills, Skills}]))
		end},
		{"remove_skills/2", fun() ->
			Skills = [tech, spanish],
			agent:remove_skills(Pid, Skills),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, {remove_skills, Skills}]))
		end},
		{"change_profile/2", fun() ->
			Profile = "support",
			agent:change_profile(Pid, Profile),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, {change_profile, Profile}]))
		end},
		{"query_state/1", fun() ->
			agent:query_state(Pid),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, sync_send_all_state_event, [Pid, query_state]))
		end},
		{"blab/2", fun() ->
			Text = "hello",
			agent:blab(Pid, Text),

			?assert(meck:validate(gen_fsm)),
			?assert(meck:called(gen_fsm, send_all_state_event, [Pid, {blab, Text}]))
		end},
		{"set_endpoints/2", {setup, fun() -> meck:new(notgenmedia) end, fun(_) -> meck:unload(notgenmedia) end, fun() ->
			%% TODO add true gen_media
			agent:set_endpoints(Pid, [{notexistingmod, []}, {notgenmedia, []}]),
			?assert(meck:called(gen_fsm, send_all_state_event, [Pid, {set_endpoints, []}]))
		end}},
		{"set_endpoint/3", [
			{"notloaded",
				?_assertEqual({error, nofile}, agent:set_endpoint(Pid, notexistingmod, []))},
			{"notgenmedia", {setup, fun() -> meck:new(notgenmedia) end, fun(_) -> meck:unload(notgenmedia) end,
				?_assertEqual({error, badmodule}, agent:set_endpoint(Pid, notgenmedia, []))}}
			%% TODO add true gen_media
		]}
	] end}.

expand_magic_skills_test_() ->
	Agent = #agent{login = "testagent", profile = "testprofile", skills = ['_agent', '_node', '_profile', english, {'_brand', "testbrand"}]},
	Newskills = expand_magic_skills(Agent, Agent#agent.skills),
	[?_assert(lists:member({'_agent', "testagent"}, Newskills)),
	?_assert(lists:member({'_node', node()}, Newskills)),
	?_assert(lists:member(english, Newskills)),
	?_assert(lists:member({'_profile', "testprofile"}, Newskills)),
	?_assert(lists:member({'_brand', "testbrand"}, Newskills))].

block_channel_test_() ->
	FullAvail = [dummy, dummy, voice, voice, visual, visual, slow_text,
		slow_text, fast_text, fast_text],
	% {TestName, Channel, BlocListDefs, Expected}
	TestData = [
		{"blocks all", nomatches, [{nomatches, all}], []},
		{"blocks none", nomatches, [{nomatches, none}], FullAvail},
		{"blocks self", slow_text, ?default_category_blocks, [dummy,
			dummy, voice, voice, visual, visual, fast_text, fast_text]},
		{"blocks others", fast_text, ?default_category_blocks, [fast_text]},
		{"blocks specific", channel, [{channel, [visual, slow_text]}],
			[dummy, dummy, voice, voice, fast_text, fast_text]}
	],
	block_channel_test_gen(TestData).

block_channel_test_gen([]) ->
	[];
block_channel_test_gen([{Name, Chan, ListDef, Expected} | Tail]) ->
	FullAvail = [dummy, dummy, voice, voice, visual, visual, slow_text,
		slow_text, fast_text, fast_text],
	{generator, fun() ->
		[{Name, fun() ->
			Out = block_channels(Chan, FullAvail, ListDef),
			?assertEqual(Expected, Out)
		end} | block_channel_test_gen(Tail)]
	end}.

% TODO meck-anize these tests.
handle_sync_event_test_() ->
	[{"handle set_endpoint", setup, fun() ->
			Endpoints = dict:from_list([
				{freeswitch_media, sip},
				{email_media, inband},
				{asterix, {module, freeswitch_media}}
			]),
			Agent = make_agent([{endpoints, Endpoints}]),
			State = #state{agent_rec = Agent},
			{Agent, State, Endpoints}
		end,
		fun({_Agent, State, Endpoints}) -> [
			% {"Adding new inband endpoint", fun() ->
			% 	Expected = [{dummy_media, {inband, {dummy_media,start_ring,[transient]}}} | dict:to_list(Endpoints)],
			% 	{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, dummy_media, inband}, "from", idle, State),
			% 	?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			% end},

			{"Adding new module ref endpoint", fun() ->
				Expected = [{fast_text, {module, email_media}} | dict:to_list(Endpoints)],
				{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, fast_text, {module, email_media}}, "from", idle, State),
				?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			end},

			{"Adding a self-refertial endpoint", fun() ->
				?assertEqual({reply, {error, self_reference}, idle, State}, handle_sync_event({set_endpoint, fast_text, {module, fast_text}}, "from", idle, State))
			end},

			{"adding a missing referencital endpoint", fun() ->
				?assertEqual({reply, {error, module_noexists}, idle, State}, handle_sync_event({set_endpoint, fast_text, {module, goober_pants}}, "from", idle, State))
			end}

			% {"adding arbitary data endpoint", fun() ->
			% 	Expected = [{dummy_media, {inband, {dummy_media,start_ring,[transient]}}} | dict:to_list(Endpoints)],
			% 	{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, dummy_media, inband}, "from", idle, State),
			% 	?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			% end}
		]
	end},

	% {"{set_connection, Pid}", fun() ->
	% 	Self = self(),
	% 	Zombie = util:zombie(),
	% 	Agent = #agent{id = "testid", login = "testlogin", source = Self,
	% 		used_channels = dict:from_list([{Zombie, voice}])},
	% 	State = #state{agent_rec = Agent},
	% 	meck:new(agent_channel),
	% 	meck:expect(agent_channel, set_connection, fun(ChanPid, InPid) ->
	% 		?assertEqual(Zombie, ChanPid),
	% 		?assertEqual(Self, InPid)
	% 	end),
	% 	ExpectState = State#state{
	% 		agent_rec = Agent#agent{connection = Self}
	% 	},
	% 	?assertEqual({reply, ok, idle, ExpectState}, handle_sync_event({set_connection, Self}, from, idle, State)),
	% 	?assert(meck:validate(agent_channel)),
	% 	?assertEqual(1, length(meck:history(agent_channel))),
	% 	meck:unload(agent_channel)
	% end},

	{"{set_connection, _Pid}", fun() ->
		Self = self(),
		Zombie = util:zombie(),
		Agent = #agent{id = "testid", login = "testlogin", source = Self,
			used_channels = dict:from_list([{Zombie, voice}]), connection = Zombie},
		State = #state{agent_rec = Agent},
		?assertEqual({reply, error, idle, State}, handle_sync_event({set_connection, Zombie}, from, idle, State))
	end}].

	% {"{change_profile, Profile}, success", fun() ->
	% 	OldAgent = #agent{id = "testid", login = "testagent", profile = "oldprofile", skills = [old_skill]},
	% 	NewAgent = OldAgent#agent{profile = "newprofile", skills = [new_skill]},
	% 	Mecks = [agent_auth, cpx_agent_event, cpx_monitor],
	% 	[meck:new(M) || M <- Mecks],
	% 	meck:expect(agent_auth, get_profile, fun
	% 		("oldprofile") ->
	% 			#agent_profile{name = "oldprofile", skills = [old_skill]};
	% 		("newprofile") ->
	% 			#agent_profile{name = "newprofile", skills = [new_skill]}
	% 	end),
	% 	meck:expect(cpx_agent_event, change_agent, fun(InOld, InNew) ->
	% 		?assertEqual(OldAgent, InOld),
	% 		?assertEqual(NewAgent, InNew),
	% 		ok
	% 	end),
	% 	meck:expect(cpx_monitor, set, fun({agent, "testid"}, [
	% 		{profile, "newprofile"}, {login, "testagent"}, {skills, [new_skill]}
	% 	]) ->
	% 		ok
	% 	end),
	% 	?assertEqual({reply, ok, idle, #state{agent_rec = NewAgent}},
	% 		handle_sync_event({change_profile, "newprofile"}, from, idle, #state{agent_rec = OldAgent})),
	% 	[begin meck:validate(M), meck:unload(M) end || M <- Mecks]
	% end}].

	% {"{change_profile, Profile}, no profile", fun() ->
	% 	OldAgent = #agent{id = "testid", login = "testagent", profile = "oldprofile", skills = [old_skill]},
	% 	Mecks = [agent_auth],
	% 	[meck:new(M) || M <- Mecks],
	% 	meck:expect(agent_auth, get_profile, fun
	% 		("oldprofile") ->
	% 			#agent_profile{name = "oldprofile", skills = [old_skill]};
	% 		("newprofile") ->
	% 			undefined
	% 	end),
	% 	?assertEqual({reply, {error, unknown_profile}, idle, #state{agent_rec = OldAgent}},
	% 		handle_sync_event({change_profile, "newprofile"}, from, idle, #state{agent_rec = OldAgent})),
	% 	[begin meck:validate(M), meck:unload(M) end || M <- Mecks]
	% end}].

state_test_() ->
	{setup, fun() ->
		Mecks = [dispatch_manager, cpx_monitor, agent_manager, agent_event,
			cpx_agent_event, dummy_connection],
		Zombie = proc_lib:spawn(fun() ->
			gen_server:enter_loop(dummy_connection, [], state)
		end),
		Setup = fun() ->
			[meck:new(M) || M <- Mecks],
			meck:expect(dummy_connection, terminate, fun(_,_) -> ok end)
		end,
		Validator = fun() ->
			[meck:validate(M) || M <- Mecks]
		end,
		Teardown = fun() ->
			[meck:unload(M) || M <- Mecks]
		end,
		{Setup, Validator, Teardown, Mecks, Zombie}
	end,
	fun({Setup, Validate, Teardown, _Mecks, Zombie}) -> [
		{"from release", {foreach, fun() ->
			Setup()
		end,
		fun(_) ->
			Teardown()
		end, [

			% fun(_) ->
			% 	{"From release to release", fun() ->
			% 		Agent = #agent{id = "testid", login = "testagent", connection = Zombie},
			% 		State = #state{agent_rec = Agent},
			% 		meck:expect(cpx_monitor, set, fun({agent, "testid"}, Data, ignore) ->
			% 			Expected = [{released, true}, {reason, "label"}, {bias, -1},
			% 				{released, true}, {reason_id, "id"}],
			% 			[?assertEqual(Val, proplists:get_value(Key, Data)) ||
			% 				{Key, Val} <- Expected],
			% 			ok
 			% 		end),
			% 		meck:expect(cpx_agent_event, change_agent, fun(InAgent, NewAgent) ->
			% 			?assertEqual(Agent, InAgent),
			% 			?assertEqual({"id", "label", -1}, NewAgent#agent.release_data)
			% 		end),
			% 		meck:expect(dummy_connection, handle_cast, fun({set_release, {"id", "label", -1}, _Timestamp}, state) -> {noreply, state} end),
			% 		Out = released({set_release, {"id", "label", -1}}, "from", State),
			% 		?assertMatch({reply, ok, released, _NewState}, Out),
			% 		Validate()
			% 	end}
			% end,

			% fun(_) ->
			% 	{"From release to idle", fun() ->
			% 		Agent = #agent{id = "testid", login = "testagent", connection = connection},
			% 		State = #state{agent_rec = Agent},
			% 		meck:expect(cpx_monitor, set, fun({agent, "testid"}, Data, ignore) ->
			% 			?assertNot(proplists:get_value(released, Data)),
			% 			ok
			% 		end),
			% 		meck:expect(agent_manager, set_avail, fun("testagent", InChans) ->
			% 			?assertEqual(Agent#agent.available_channels, InChans),
			% 			ok
			% 		end),
			% 		meck:expect(cpx_agent_event, change_agent, fun(InAgent, _Agent) ->
			% 			?assertEqual(Agent, InAgent),
			% 			?assertEqual(undefined, InAgent#agent.release_data)
			% 		end),
			% 		Self = self(),
			% 		meck:expect(dispatch_manager, now_avail, fun(InPid, [dummy, voice,visual,slow_text,fast_text,fast_text,fast_text]) ->
			% 			?assertEqual(Self, InPid),
			% 			ok
			% 		end),
			% 		Out = released({set_release, none}, "from", State),
			% 		?assertMatch({reply, ok, idle, _NewState}, Out),
			% 		Validate()
			% 	end}
			% end
		]}},

		{"from idle", {foreach, fun() ->
			Setup()
		end,
		fun(_) ->
			Teardown()
		end, [

			fun(_) -> {"to idle", fun() ->
				Out = idle({set_release, none}, "from", state),
				?assertEqual({reply, ok, idle, state}, Out),
				Validate()
			end} end,

			% fun(_) -> {"to release", fun() ->
			% 		Agent = #agent{id = "testid", login = "testagent", connection = Zombie, release_data = undefined},
			% 	State = #state{agent_rec = Agent},
			% 	meck:expect(cpx_monitor, set, fun({agent, "testid"}, Data, ignore) ->
			% 		Expected = [{released, true}, {reason, "label"},
			% 			{reason_id, "id"}, {bias, -1}],
			% 		[?assertEqual(Val, proplists:get_value(Key, Data)) ||
			% 			{Key, Val} <- Expected],
			% 		ok
			% 	end),
			% 	meck:expect(agent_manager, set_avail, fun("testagent", []) ->
			% 		ok
			% 	end),
			% 	Self = self(),
			% 	meck:expect(dispatch_manager, end_avail, fun(InPid) ->
			% 		?assertEqual(Self, InPid),
			% 		ok
			% 	end),
			% 	meck:expect(dummy_connection, handle_cast, fun({set_release, {"id", "label", -1},_Time}, state) -> {noreply, state} end),
			% 	meck:expect(cpx_agent_event, change_agent, fun(InAgent, NewAgent) ->
			% 		?assertEqual(Agent, InAgent),
			% 		?assertEqual({"id", "label", -1}, NewAgent#agent.release_data)
			% 	end),
			% 	Out = idle({set_release, {"id", "label", -1}}, "from", State),
			% 	?assertMatch({reply, ok, released, _NewState}, Out),
			% 	Validate()
			% end} end,

			fun(_) -> {"agent channel starting",
				{foreach, fun() ->
					meck:new(agent_channel)
				end,
				fun(_) ->
					meck:unload(agent_channel)
				end, [

				% fun(_) -> {"channel not found", fun() ->
				% 	Agent = #agent{login = "testagent", id = "testid",
				% 		available_channels = []},
				% 	Call = #call{id = "media", type = voice, source = self()},
				% 	State = #state{agent_rec = Agent},
				% 	?assertEqual({reply, {error, nochannel}, idle, State}, idle({prering, Call}, from, State))
				% end} end,

				% fun(_) -> {"endpoint not found", fun() ->
				% 	Agent = #agent{login = "testagent", id = "testid",
				% 		available_channels = [voice]},
				% 	Call = #call{id = "media", type = voice, source = self(),
				% 		source_module = dummy_media},
				% 	State = #state{agent_rec = Agent},
				% 	?assertEqual({reply, {error, noendpoint}, idle, State}, idle({prering, Call}, from, State))
				% end} end,

				fun(_) -> {"precall success", fun() ->
					Agent = #agent{login = "testagent", id = "testid",
						available_channels = [voice], endpoints = dict:from_list([
							{dummy_media, {inband, self_ring}}
						])},
					Call = #call{id = "media", type = voice, source = self(),
						source_module = dummy_media},
					meck:expect(agent_channel, start_link, fun(InAgent, InCall, _End, precall, _EventMgr) ->
						?assertEqual(Agent, InAgent),
						?assertEqual(Call, InCall),
						{ok, Zombie}
					end),
					Self = self(),
					meck:expect(dispatch_manager, now_avail, fun(InPid, []) ->
						?assertEqual(Self, InPid),
						ok
					end),
					meck:expect(agent_manager, set_avail, fun("testagent", []) ->
						ok
					end),
					State = #state{agent_rec = Agent},
					ExpectAgent = Agent#agent{available_channels = [],
						used_channels = dict:from_list([{Zombie, voice}])},
					ExpectState = #state{agent_rec = ExpectAgent},
					?assertEqual({reply, {ok, Zombie}, idle, ExpectState}, idle({precall, Call}, from, State))
				end} end,

				fun(_) -> {"prering success", fun() ->
					Agent = #agent{login = "testagent", id = "testid",
						available_channels = [voice], endpoints = dict:from_list([
							{dummy_media, {inband, self_ring}}
						])},
					Call = #call{id = "media", type = voice, source = self(),
						source_module = dummy_media},
					meck:expect(agent_channel, start_link, fun(InAgent, InCall, self_ring, prering, _EventMgr) ->
						?assertEqual(Agent, InAgent),
						?assertEqual(Call, InCall),
						{ok, Zombie}
					end),
					Self = self(),
					meck:expect(dispatch_manager, now_avail, fun(InPid, []) ->
						?assertEqual(Self, InPid),
						ok
					end),
					meck:expect(agent_manager, set_avail, fun("testagent", []) ->
						ok
					end),
					State = #state{agent_rec = Agent},
					ExpectAgent = Agent#agent{available_channels = [],
						used_channels = dict:from_list([{Zombie, voice}])},
					ExpectState = #state{agent_rec = ExpectAgent},
					?assertEqual({reply, {ok, Zombie}, idle, ExpectState}, idle({prering, Call}, from, State))
				end} end,

				fun(_) -> {"ringing success", fun() ->
					Agent = #agent{login = "testagent", id = "testid",
						available_channels = [voice], endpoints = dict:from_list([
							{dummy_media, {inband, self_ring}}
						])},
					Call = #call{id = "media", type = voice, source = self(),
						source_module = dummy_media},
					meck:expect(agent_channel, start_link, fun(InAgent, InCall, self_ring, ringing, _EventMgr) ->
						?assertEqual(Agent, InAgent),
						?assertEqual(Call, InCall),
						{ok, Zombie}
					end),
					Self = self(),
					meck:expect(dispatch_manager, now_avail, fun(InPid, []) ->
						?assertEqual(Self, InPid),
						ok
					end),
					meck:expect(agent_manager, set_avail, fun("testagent", []) ->
						ok
					end),
					State = #state{agent_rec = Agent},
					ExpectAgent = Agent#agent{available_channels = [],
						used_channels = dict:from_list([{Zombie, voice}])},
					ExpectState = #state{agent_rec = ExpectAgent},
					?assertEqual({reply, {ok, Zombie}, idle, ExpectState}, idle({ringing, Call}, from, State))
				end} end

				]}
			} end



		]}}
	] end}.

idle_to_prering_error_test_() ->
	EvtMgr = spawn(fun() -> ok end),

	Agent = #agent{login = "test_agent", available_channels = [voice]},
	State = #state{agent_rec = Agent, event_manager = EvtMgr},

	RelAgent = Agent#agent{release_data = ?DEFAULT_RELEASE},
	RelState = State#state{agent_rec = RelAgent},

	Call = #call{id = "media", type = voice, source = self()},

	{setup, fun() ->
		application:start(gproc),
		cpx_agent_event:start()
	end, fun(_) ->
		meck:unload(),
		cpx_agent_event:stop()
	end, [
	{"no channel", fun() ->
		init_gproc_prop({init, State}),
		NoChannelState = State#state{agent_rec = Agent#agent{available_channels=[]}},

		?assertEqual({reply, {error, nochannel}, idle, NoChannelState}, idle({prering, Call}, from, NoChannelState))
	end},
	{"no endpoint, autorelease default", fun() ->
		?assertEqual({reply, {error, noendpoint}, released, RelState}, idle({prering, Call}, from, State))
	end},
	{"no endpoint, autorelease enabled" , fun() ->
		application:set_env(openacd, release_on_ring_failure, true),
		?assertEqual({reply, {error, noendpoint}, released, RelState}, idle({prering, Call}, from, State))

	end},
	{"no endpoint, autorelease disabled" , fun() ->
		application:set_env(openacd, release_on_ring_failure, false),
		?assertEqual({reply, {error, noendpoint}, idle, State}, idle({prering, Call}, from, State))
	end}]}.

handle_event_test_() ->
	{foreach, fun() ->
		meck:new(agent_manager),
		LengthAssert = fun(N) ->
			?assertEqual(N, length(meck:history(agent_manager)))
		end,
		Agent = #agent{id = "testid", login = "testagent",
			skills = [old_skill]},
		{LengthAssert, Agent}
	end,
	fun(_) ->
		?assert(meck:validate(agent_manager)),
		meck:unload(agent_manager)
	end, [

	fun({L, Agent}) -> {"{blab, Text}", fun() ->
		?assertEqual({next_state, idle, #state{agent_rec = Agent}},
			handle_event({blab, "text"}, idle, #state{agent_rec = Agent})),
		L(0)
	end} end,

	fun({L, Agent}) -> {"stop", fun() ->
		?assertEqual({stop, normal, #state{agent_rec = Agent}},
			handle_event({stop, normal, undefined}, idle, #state{agent_rec = Agent})),
		L(0)
	end} end,

	fun({L, Agent}) -> {"{add_skills, Skills}", fun() ->
		NewAgent = Agent#agent{skills = [new_skill, old_skill]},
		meck:expect(agent_manager, update_skill_list, fun("testagent", [new_skill, old_skill]) -> ok end),
		?assertEqual({next_state, idle, #state{agent_rec = NewAgent}},
			handle_event({add_skills, [new_skill]}, idle, #state{agent_rec = Agent})),
		L(1)
	end} end,

	fun({L, Agent}) -> {"{remove_skills, Skills}", fun() ->
		NewAgent = Agent#agent{skills = []},
		meck:expect(agent_manager, update_skill_list, fun("testagent", []) -> ok end),
		?assertEqual({next_state, idle, #state{agent_rec = NewAgent}},
			handle_event({remove_skills, [old_skill]}, idle, #state{agent_rec = Agent})),
		L(1)
	end} end

	% fun({L, Agent}) -> {"{set_endpoints, InEnds}", fun() ->
	% 	NewAgent = Agent#agent{endpoints = dict:from_list([{dummy_media, {inband, self_ring}}])},
	% 	meck:new(dummy_media),
	% 	meck:expect(dummy_media, prepare_endpoint, fun(_Agent, inband) ->
	% 		{ok, self_ring}
	% 	end),
	% 	meck:expect(agent_manager, set_ends, fun(A,B) ->
	% 		lager:error("~p  ~p", [A,B]),
	% 		ok
	% 	end),
	% 	Expected = {next_state, idle, #state{agent_rec = NewAgent}},
	% 	Got = handle_event({set_endpoints, [{dummy_media, inband}]}, idle, #state{agent_rec = Agent}),
	% 	lager:debug("Expect:  ~p;\ngot:  ~p", [Expected, Got]),
	% 	?assertEqual(Expected, Got),
	% 	L(1),
	% 	meck:validate(dummy_media),
	% 	meck:unload(dummy_media)
	% end} end

	]}.

handle_info_test_() ->
	{setup, fun() ->
		Z = util:zombie(),
		Agent = #agent{id = "testid", login = "testlogin", source = self()},
		{Z, Agent}
	end,
	fun({Z,_}) ->
		exit(Z, normal)
	end,
	fun({Zombie,ProtoAgent}) -> [

		{"connection exit", fun() ->
			Agent = ProtoAgent#agent{connection = Zombie},
			State = #state{agent_rec = Agent},
			?assertEqual({stop, {error, conn_exit, <<"hagurk">>}, State},
				handle_info({'EXIT', Zombie, <<"hagurk">>}, idle, State))
		end},

		{"endpoint exit", fun() ->
			Agent = ProtoAgent#agent{endpoints = dict:from_list([
				{dummy_media, {inband, Zombie}}
			])},
			NewEnd = util:zombie(),
			meck:new(dummy_media),
			meck:expect(dummy_media, prepare_endpoint, fun(_,inband) ->
				{ok, NewEnd}
			end),
			ExpectAgent = ProtoAgent#agent{endpoints = dict:from_list([
				{dummy_media, {inband, NewEnd}}
			])},
			?assertEqual({next_state, idle, #state{agent_rec = ExpectAgent}},
				handle_info({'EXIT', Zombie, <<"hagurk">>}, idle, #state{agent_rec = Agent})),
			?assert(meck:validate(dummy_media)),
			?assertEqual(1, length(meck:history(dummy_media))),
			meck:unload(dummy_media)
		end}

	] end}.


-endif.