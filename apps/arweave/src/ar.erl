%%%
%%% @doc Arweave server entrypoint and basic utilities.
%%%
-module(ar).

-behaviour(application).

-export([main/0, main/1, create_wallet/0, create_wallet/1,
		benchmark_packing/1, benchmark_packing/0, benchmark_vdf/0, start/0,
		start/1, start/2, stop/1, stop_dependencies/0, tests/0, tests/1, tests/2, test_ipfs/0,
		docs/0, start_for_tests/0, shutdown/1, console/1, console/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_config.hrl").

-include_lib("eunit/include/eunit.hrl").

%% A list of the modules to test.
%% At some point we might want to make this just test all mods starting with
%% ar_.
-define(
	CORE_TEST_MODS,
	[
		%% tests embedded in modules
		ar,
		ar_block,
		ar_block_cache,
		ar_chunk_storage,
		ar_data_sync_worker_master,
		ar_deep_hash,
		ar_diff_dag,
		ar_ets_intervals,
		ar_inflation,
		ar_intervals,
		ar_join,
		ar_kv,
		ar_merkle,
		ar_mining_server,
		ar_node,
		ar_node_utils,
		ar_nonce_limiter,
		ar_packing_server,
		ar_patricia_tree,
		ar_peers,
		ar_poa,
		ar_pricing,
		ar_retarget,
		ar_serialize,
		ar_storage,
		ar_sync_buckets,
		ar_tx,
		ar_tx_db,
		ar_unbalanced_merkle,
		ar_util,
		ar_weave,

		%% test modules
		ar_base64_compatibility_tests,
		ar_config_tests,
		ar_data_sync_tests,
		ar_difficulty_tests,
		ar_fork_recovery_tests,
		ar_gateway_middleware_tests,
		ar_header_sync_tests,
		ar_http_iface_tests,
		ar_http_util_tests,
		ar_mempool_tests,
		ar_mine_randomx_tests,
		ar_mine_vdf_tests,
		ar_multiple_txs_per_wallet_tests,
		ar_node_tests,
		ar_poa_tests,
		ar_poller_tests,
		ar_post_block_tests,
		ar_pricing_tests,
		ar_semaphore_tests,
		ar_tx_blacklist_tests,
		ar_tx_replay_pool_tests,
		ar_vdf_server_tests,
		ar_vdf_tests,
		ar_wallet_tests,
		ar_webhook_tests
	]
).

%% Supported feature flags (default behaviour)
% http_logging (false)
% disk_logging (false)
% miner_logging (true)
% subfield_queries (false)
% blacklist (true)
% time_syncing (true)

%% @doc Command line program entrypoint. Takes a list of arguments.
main() ->
	show_help().

main("") ->
	show_help();
main(Args) ->
	start(parse_config_file(Args, [], #config{})).

show_help() ->
	io:format("Usage: arweave-server [options]~n"),
	io:format("Compatible with network: ~s~n", [?NETWORK_NAME]),
	io:format("Options:~n"),
	lists:foreach(
		fun({Opt, Desc}) ->
			io:format("\t~s~s~n",
				[
					string:pad(Opt, 40, trailing, $ ),
					Desc
				]
			)
		end,
		[
			{"config_file (path)", "Load the configuration from the specified JSON file."
				" The keys in the root object are mapped to the command line arguments "
				"described here. Additionally, you may specify a semaphores key. Its value "
				"has to be a nested JSON object where keys are some of: get_chunk, "
				"get_and_pack_chunk, get_tx_data, post_chunk, post_tx, get_block_index, "
				"get_wallet_list, arql, gateway_arql, get_sync_record. For instance, your"
				" config file contents may look like {\"semaphores\": {\"post_tx\": 100}}."
				" In this case, the node will validate up to 100 incoming transactions in "
				"parallel."},
			{"peer (IP:port)", "Join a network on a peer (or set of peers)."},
			{"block_gossip_peer (IP:port)", "Optionally specify peer(s) to always"
					" send blocks to."},
			{"local_peer (IP:port)", "The local network peer. Local peers do not rate limit "
					"each other so we recommend you connect all your nodes from the same "
					"network via this configuration parameter."},
			{"sync_from_local_peers_only", "If set, the data (not headers) is only synced "
					"from the local network peers specified via the local_peer parameter."},
			{"start_from_block_index", "Start the node from the latest stored block index."},
			{"mine", "Automatically start mining once the netwok has been joined."},
			{"port", "The local port to use for mining. "
						"This port must be accessible by remote peers."},
			{"data_dir",
				"The directory for storing the weave and the wallets (when generated)."},
			{"log_dir", "The directory for logs. If the \"debug\" flag is set, the debug logs "
					"are written to logs/debug_logs/. The RocksDB logs are written to "
					"logs/rocksdb/."},
			{"metrics_dir", "The directory for persisted metrics."},
			{"storage_module", "A storage module is responsible for syncronizing and storing "
					"a particular data range. The data and metadata related to the module "
					"are stored in a dedicated folder "
					"([data_dir]/storage_modules/storage_module_[partition_number]_[packing]/"
					") where packing is either a mining address or \"unpacked\"."
					" Example: storage_module 0,En2eqsVJARnTVOSh723PBXAKGmKgrGSjQ2YIGwE_ZRI. "
					"To configure a module of a custom size, set "
					"storage_module [number],[size_in_bytes],[packing]. For instance, "
					"storage_module "
					"22,1000000000000,En2eqsVJARnTVOSh723PBXAKGmKgrGSjQ2YIGwE_ZRI will be "
					"syncing the weave data between the offsets 22 TB and 23 TB. Make sure "
					"the corresponding disk contains some extra space for the proofs and "
					"other metadata, about 10% of the configured size."},
			{"polling (num)", lists:flatten(
					io_lib:format(
						"Ask some peers about new blocks every N seconds. Default is ~p.",
						[?DEFAULT_POLLING_INTERVAL]
					)
			)},
			{"block_pollers (num)", io_lib:format(
					"How many peer polling jobs to run. Default is ~p.",
					[?DEFAULT_BLOCK_POLLERS])},
			{"no_auto_join", "Do not automatically join the network of your peers."},
			{"join_workers (num)", io_lib:format("The number of workers fetching the recent "
					"blocks and transactions simultaneously when joining the network. "
					"Default: ~B. ", [?DEFAULT_JOIN_WORKERS])},
			{"mining_addr (addr)",
				io_lib:format(
				"The address mining rewards should be credited to. If the \"mine\" flag"
				" is set but no mining_addr is specified, an RSA PSS key is created"
				" and stored in the [data_dir]/~s directory. If the directory already"
				" contains such keys, the one written later is picked, no new files are"
				" created. After the fork 2.6, the specified address is also a packing key, "
				"so it is used to pack synced data even if the \"mine\" flag is not "
				"specified. The data already packed with different addresses is not repacked.",
				[?WALLET_DIR])},
			{"stage_one_hashing_threads (num)",
				io_lib:format(
					"The number of mining processes searching for the SPoRA chunks to read."
					"Default: ~B. If the total number of stage one and stage two processes "
					"exceeds the number of available CPU cores, the excess processes will be "
					"hashing chunks when anything gets queued, and search for chunks "
					"otherwise. Only takes effect until the fork 2.6.",
					[?NUM_STAGE_ONE_HASHING_PROCESSES]
				)},
			{"hashing_threads (num)", io_lib:format("The number of hashing processes to spawn."
					" Takes effect starting from the fork 2.6 block."
					" Default is ~B.", [?NUM_HASHING_PROCESSES])},
			{"data_cache_size_limit (num)", "The approximate maximum number of data chunks "
					"kept in memory by the syncing processes."},
			{"packing_cache_size_limit (num)", "The approximate maximum number of data chunks "
					"kept in memory by the packing process."},
			{"mining_server_chunk_cache_size_limit (num)", "The mining server will not read "
					"new data unless the number of already fetched unprocessed chunks does "
					"not exceed this number. When omitted, it is determined based on the "
					"number of mining partitions and available RAM."},
			{"io_threads (num)",
				io_lib:format("The number of processes reading SPoRA chunks during mining. "
					"Default: ~B. Only takes effect until the fork 2.6.",
					[?NUM_IO_MINING_THREADS])},
			{"stage_two_hashing_threads (num)",
				io_lib:format(
					"The number of mining processes hashing SPoRA chunks."
					"Default: ~B. If the total number of stage one and stage two processes "
					"exceeds the number of available CPU cores, the excess processes will be "
					"hashing chunks when anything gets queued, and search for chunks "
					"otherwise. Only takes effect until the fork 2.6.",
					[?NUM_STAGE_TWO_HASHING_PROCESSES])},
			{"max_emitters (num)", io_lib:format("The number of transaction propagation "
				"processes to spawn. Default is ~B.", [?NUM_EMITTER_PROCESSES])},
			{"tx_validators (num)", "Ignored. Set the post_tx key in the semaphores object"
				" in the configuration file instead."},
			{"post_tx_timeout", io_lib:format("The time in seconds to wait for the available"
				" tx validation process before dropping the POST /tx request. Default is ~B."
				" By default ~B validation processes are running. You can override it by"
				" setting a different value for the post_tx key in the semaphores object"
				" in the configuration file.", [?DEFAULT_POST_TX_TIMEOUT,
						?MAX_PARALLEL_POST_TX_REQUESTS])},
			{"tx_propagation_parallelization (num)",
				"DEPRECATED. Does not affect anything."},
			{"max_propagation_peers", io_lib:format(
				"The maximum number of peers to propagate transactions to. "
				"Default is ~B.", [?DEFAULT_MAX_PROPAGATION_PEERS])},
			{"max_block_propagation_peers", io_lib:format(
				"The maximum number of best peers to propagate blocks to. "
				"Default is ~B.", [?DEFAULT_MAX_BLOCK_PROPAGATION_PEERS])},
			{"sync_jobs (num)",
				io_lib:format(
					"The number of data syncing jobs to run. Default: ~B."
					" Each job periodically picks a range and downloads it from peers.",
					[?DEFAULT_SYNC_JOBS]
				)},
			{"header_sync_jobs (num)",
				io_lib:format(
					"The number of header syncing jobs to run. Default: ~B."
					" Each job periodically picks the latest not synced block header"
					" and downloads it from peers.",
					[?DEFAULT_HEADER_SYNC_JOBS]
				)},
			{"disk_pool_jobs (num)",
				io_lib:format(
					"The number of disk pool jobs to run. Default: ~B."
					" Disk pool jobs scan the disk pool to index no longer pending or"
					" orphaned chunks, schedule packing for chunks with a sufficient"
					" number of confirmations and remove abandoned chunks.",
					[?DEFAULT_DISK_POOL_JOBS]
				)},
			{"load_mining_key (file)", "DEPRECATED. Does not take effect anymore."},
			{"transaction_blacklist (file)", "A file containing blacklisted transactions. "
											 "One Base64 encoded transaction ID per line."},
			{"transaction_blacklist_url", "An HTTP endpoint serving a transaction blacklist."},
			{"transaction_whitelist (file)", "A file containing whitelisted transactions. "
											 "One Base64 encoded transaction ID per line. "
											 "If a transaction is in both lists, it is "
											 "considered whitelisted."},
			{"transaction_whitelist_url", "An HTTP endpoint serving a transaction whitelist."},
			{"disk_space (num)", "DEPRECATED. Does not take effect anymore."},
			{"disk_space_check_frequency (num)",
				io_lib:format(
					"The frequency in seconds of requesting the information "
					"about the available disk space from the operating system, "
					"used to decide on whether to continue syncing the historical "
					"data or clean up some space. Default is ~B.",
					[?DISK_SPACE_CHECK_FREQUENCY_MS div 1000]
				)},
			{"init", "Start a new weave."},
			{"internal_api_secret (secret)",
				lists:flatten(io_lib:format(
						"Enables the internal API endpoints, only accessible with this secret."
						" Min. ~B chars.",
						[?INTERNAL_API_SECRET_MIN_LEN]))},
			{"enable (feature)", "Enable a specific (normally disabled) feature. For example, "
					"subfield_queries."},
			{"disable (feature)", "Disable a specific (normally enabled) feature."},
			{"requests_per_minute_limit (number)", "Limit the maximum allowed number of HTTP "
					"requests per IP address per minute. Default is 900."},
			{"max_connections", "The number of connections to be handled concurrently. "
					"Its purpose is to prevent your system from being overloaded and ensuring "
					"all the connections are handled optimally. Default is 1024."},
			{"disk_pool_data_root_expiration_time",
				"The time in seconds of how long a pending or orphaned data root is kept in "
				"the disk pool. The default is 2 * 60 * 60 (2 hours)."},
			{"max_disk_pool_buffer_mb",
				"The max total size in mebibytes of the pending chunks in the disk pool."
				"The default is 2000 (2 GiB)."},
			{"max_disk_pool_data_root_buffer_mb",
				"The max size in mebibytes per data root of the pending chunks in the disk"
				" pool. The default is 50."},
			{"randomx_bulk_hashing_iterations",
				"The number of hashes RandomX generates before reporting the result back"
				" to the Arweave miner. The faster CPU hashes, the higher this value should be."
			},
			{"disk_cache_size_mb",
				lists:flatten(io_lib:format(
					"The maximum size in mebibytes of the disk space allocated for"
					" storing recent block and transaction headers. Default is ~B.",
					[?DISK_CACHE_SIZE]
				)
			)},
			{"packing_rate",
				"The maximum number of chunks per second to pack or unpack. "
				"The default value is determined based on the number of CPU cores."},
			{"max_vdf_validation_thread_count", io_lib:format("\tThe maximum number "
					"of threads used for VDF validation. Default: ~B",
					[?DEFAULT_MAX_NONCE_LIMITER_VALIDATION_THREAD_COUNT])},
			{"max_vdf_last_step_validation_thread_count", io_lib:format(
					"\tThe maximum number of threads used for VDF last step "
					"validation. Default: ~B",
					[?DEFAULT_MAX_NONCE_LIMITER_LAST_STEP_VALIDATION_THREAD_COUNT])},
			{"vdf_server_trusted_peer", "If the option is set, we expect the given "
					"peer(s) to push VDF updates to us; we will thus not compute VDF outputs "
					"ourselves. Recommended on CPUs without hardware extensions for computing"
					" SHA-2. We will nevertheless validate VDF chains in blocks. Also, we "
					"recommend you specify at least two trusted peers to aim for shorter "
					"mining downtime."},
			{"vdf_client_peer", "If the option is set, the node will push VDF updates "
					"to this peer. You can specify several vdf_client_peer options."},
			{"debug",
				"Enable extended logging."},
			{"repair_rocksdb (file)", "Attempt to repair the given RocksDB database."},
			{"run_defragmentation",
				"Run defragmentation of chunk storage files."},
			{"defragmentation_trigger_threshold",
				"File size threshold in bytes for it to be considered for defragmentation."},
			{"block_throttle_by_ip_interval (number)",
					io_lib:format("The number of milliseconds that have to pass before "
							"we accept another block from the same IP address. Default: ~B.",
							[?DEFAULT_BLOCK_THROTTLE_BY_IP_INTERVAL_MS])},
			{"block_throttle_by_solution_interval (number)",
					io_lib:format("The number of milliseconds that have to pass before "
							"we accept another block with the same solution hash. "
							"Default: ~B.", [?DEFAULT_BLOCK_THROTTLE_BY_SOLUTION_INTERVAL_MS])},
			{"defragment_module",
				"Run defragmentation of the chunk storage files from the given storage module."
				" Assumes the run_defragmentation flag is provided."}
		]
	),
	erlang:halt().

parse_config_file(["config_file", Path | Rest], Skipped, _) ->
	case read_config_from_file(Path) of
		{ok, Config} ->
			parse_config_file(Rest, Skipped, Config);
		{error, Reason, Item} ->
			io:format("Failed to parse config: ~p: ~p.~n", [Reason, Item]),
			show_help();
		{error, Reason} ->
			io:format("Failed to parse config: ~p.~n", [Reason]),
			show_help()
	end;
parse_config_file([Arg | Rest], Skipped, Config) ->
	parse_config_file(Rest, [Arg | Skipped], Config);
parse_config_file([], Skipped, Config) ->
	Args = lists:reverse(Skipped),
	parse_cli_args(Args, Config).

read_config_from_file(Path) ->
	case file:read_file(Path) of
		{ok, FileData} -> ar_config:parse(FileData);
		{error, _} -> {error, file_unreadable, Path}
	end.

parse_cli_args([], C) -> C;
parse_cli_args(["mine" | Rest], C) ->
	parse_cli_args(Rest, C#config{ mine = true });
parse_cli_args(["peer", Peer | Rest], C = #config{ peers = Ps }) ->
	case ar_util:safe_parse_peer(Peer) of
		{ok, ValidPeer} ->
			parse_cli_args(Rest, C#config{ peers = [ValidPeer|Ps] });
		{error, _} ->
			io:format("Peer ~p is invalid.~n", [Peer]),
			parse_cli_args(Rest, C)
	end;
parse_cli_args(["block_gossip_peer", Peer | Rest],
		C = #config{ block_gossip_peers = Peers }) ->
	case ar_util:safe_parse_peer(Peer) of
		{ok, ValidPeer} ->
			parse_cli_args(Rest, C#config{ block_gossip_peers = [ValidPeer | Peers] });
		{error, _} ->
			io:format("Peer ~p invalid ~n", [Peer]),
			parse_cli_args(Rest, C)
	end;
parse_cli_args(["local_peer", Peer | Rest], C = #config{ local_peers = Peers }) ->
	case ar_util:safe_parse_peer(Peer) of
		{ok, ValidPeer} ->
			parse_cli_args(Rest, C#config{ local_peers = [ValidPeer | Peers] });
		{error, _} ->
			io:format("Peer ~p is invalid.~n", [Peer]),
			parse_cli_args(Rest, C)
	end;
parse_cli_args(["sync_from_local_peers_only" | Rest], C) ->
	parse_cli_args(Rest, C#config{ sync_from_local_peers_only = true });
parse_cli_args(["transaction_blacklist", File | Rest],
	C = #config{ transaction_blacklist_files = Files } ) ->
	parse_cli_args(Rest, C#config{ transaction_blacklist_files = [File | Files] });
parse_cli_args(["transaction_blacklist_url", URL | Rest],
		C = #config{ transaction_blacklist_urls = URLs} ) ->
	parse_cli_args(Rest, C#config{ transaction_blacklist_urls = [URL | URLs] });
parse_cli_args(["transaction_whitelist", File | Rest],
		C = #config{ transaction_whitelist_files = Files } ) ->
	parse_cli_args(Rest, C#config{ transaction_whitelist_files = [File | Files] });
parse_cli_args(["transaction_whitelist_url", URL | Rest],
		C = #config{ transaction_whitelist_urls = URLs} ) ->
	parse_cli_args(Rest, C#config{ transaction_whitelist_urls = [URL | URLs] });
parse_cli_args(["port", Port | Rest], C) ->
	parse_cli_args(Rest, C#config{ port = list_to_integer(Port) });
parse_cli_args(["data_dir", DataDir | Rest], C) ->
	parse_cli_args(Rest, C#config{ data_dir = DataDir });
parse_cli_args(["log_dir", Dir | Rest], C) ->
	parse_cli_args(Rest, C#config{ log_dir = Dir });
parse_cli_args(["metrics_dir", MetricsDir | Rest], C) ->
	parse_cli_args(Rest, C#config{ metrics_dir = MetricsDir });
parse_cli_args(["storage_module", StorageModuleString | Rest], C) ->
	StorageModules = C#config.storage_modules,
	try
		StorageModule = ar_config:parse_storage_module(StorageModuleString),
		parse_cli_args(Rest, C#config{ storage_modules = [StorageModule | StorageModules] })
	catch _:_ ->
		io:format("~nstorage_module value must be in the [number],[address] format.~n~n"),
		erlang:halt()
	end;
parse_cli_args(["polling", Frequency | Rest], C) ->
	parse_cli_args(Rest, C#config{ polling = list_to_integer(Frequency) });
parse_cli_args(["block_pollers", N | Rest], C) ->
	parse_cli_args(Rest, C#config{ block_pollers = list_to_integer(N) });
parse_cli_args(["no_auto_join" | Rest], C) ->
	parse_cli_args(Rest, C#config{ auto_join = false });
parse_cli_args(["join_workers", N | Rest], C) ->
	parse_cli_args(Rest, C#config{ join_workers = list_to_integer(N) });
parse_cli_args(["mining_addr", Addr | Rest], C) ->
	case C#config.mining_addr of
		not_set ->
			case ar_util:safe_decode(Addr) of
				{ok, DecodedAddr} when byte_size(DecodedAddr) == 32 ->
					parse_cli_args(Rest, C#config{ mining_addr = DecodedAddr });
				_ ->
					io:format("~nmining_addr must be a valid Base64Url string, 43"
							" characters long.~n~n"),
					erlang:halt()
			end;
		_ ->
			io:format("~nYou may specify at most one mining_addr.~n~n"),
			erlang:halt()
	end;
parse_cli_args(["max_miners", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_miners = list_to_integer(Num) });
parse_cli_args(["io_threads", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ io_threads = list_to_integer(Num) });
parse_cli_args(["hashing_threads", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ hashing_threads = list_to_integer(Num) });
parse_cli_args(["data_cache_size_limit", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			data_cache_size_limit = list_to_integer(Num) });
parse_cli_args(["packing_cache_size_limit", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			packing_cache_size_limit = list_to_integer(Num) });
parse_cli_args(["mining_server_chunk_cache_size_limit", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			mining_server_chunk_cache_size_limit = list_to_integer(Num) });
parse_cli_args(["stage_one_hashing_threads", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ stage_one_hashing_threads = list_to_integer(Num) });
parse_cli_args(["stage_two_hashing_threads", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ stage_two_hashing_threads = list_to_integer(Num) });
parse_cli_args(["max_emitters", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_emitters = list_to_integer(Num) });
parse_cli_args(["disk_space", Size | Rest], C) ->
	parse_cli_args(Rest, C#config{ disk_space = (list_to_integer(Size) * 1024 * 1024 * 1024) });
parse_cli_args(["disk_space_check_frequency", Frequency | Rest], C) ->
	parse_cli_args(Rest, C#config{
		disk_space_check_frequency = list_to_integer(Frequency) * 1000
	});
parse_cli_args(["ipfs_pin" | Rest], C) ->
	parse_cli_args(Rest, C#config{ ipfs_pin = true });
parse_cli_args(["start_from_block_index" | Rest], C) ->
	parse_cli_args(Rest, C#config{ start_from_block_index = true });
parse_cli_args(["init" | Rest], C)->
	parse_cli_args(Rest, C#config{ init = true });
parse_cli_args(["internal_api_secret", Secret | Rest], C)
		when length(Secret) >= ?INTERNAL_API_SECRET_MIN_LEN ->
	parse_cli_args(Rest, C#config{ internal_api_secret = list_to_binary(Secret)});
parse_cli_args(["internal_api_secret", _ | _], _) ->
	io:format("~nThe internal_api_secret must be at least ~B characters long.~n~n",
			[?INTERNAL_API_SECRET_MIN_LEN]),
	erlang:halt();
parse_cli_args(["enable", Feature | Rest ], C = #config{ enable = Enabled }) ->
	parse_cli_args(Rest, C#config{ enable = [ list_to_atom(Feature) | Enabled ] });
parse_cli_args(["disable", Feature | Rest ], C = #config{ disable = Disabled }) ->
	parse_cli_args(Rest, C#config{ disable = [ list_to_atom(Feature) | Disabled ] });
parse_cli_args(["gateway", Domain | Rest ], C) ->
	parse_cli_args(Rest, C#config{ gateway_domain = list_to_binary(Domain) });
parse_cli_args(["custom_domain", Domain | Rest], C = #config{ gateway_custom_domains = Ds }) ->
	parse_cli_args(Rest, C#config{ gateway_custom_domains = [ list_to_binary(Domain) | Ds ] });
parse_cli_args(["requests_per_minute_limit", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ requests_per_minute_limit = list_to_integer(Num) });
parse_cli_args(["max_propagation_peers", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_propagation_peers = list_to_integer(Num) });
parse_cli_args(["max_block_propagation_peers", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_block_propagation_peers = list_to_integer(Num) });
parse_cli_args(["sync_jobs", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ sync_jobs = list_to_integer(Num) });
parse_cli_args(["header_sync_jobs", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ header_sync_jobs = list_to_integer(Num) });
parse_cli_args(["tx_validators", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ tx_validators = list_to_integer(Num) });
parse_cli_args(["post_tx_timeout", Num | Rest], C) ->
	parse_cli_args(Rest, C#config { post_tx_timeout = list_to_integer(Num) });
parse_cli_args(["tx_propagation_parallelization", Num|Rest], C) ->
	parse_cli_args(Rest, C#config{ tx_propagation_parallelization = list_to_integer(Num) });
parse_cli_args(["max_connections", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_connections = list_to_integer(Num) });
parse_cli_args(["max_gateway_connections", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_gateway_connections = list_to_integer(Num) });
parse_cli_args(["max_poa_option_depth", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_poa_option_depth = list_to_integer(Num) });
parse_cli_args(["disk_pool_data_root_expiration_time", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			disk_pool_data_root_expiration_time = list_to_integer(Num) });
parse_cli_args(["max_disk_pool_buffer_mb", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_disk_pool_buffer_mb = list_to_integer(Num) });
parse_cli_args(["max_disk_pool_data_root_buffer_mb", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ max_disk_pool_data_root_buffer_mb = list_to_integer(Num) });
parse_cli_args(["randomx_bulk_hashing_iterations", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ randomx_bulk_hashing_iterations = list_to_integer(Num) });
parse_cli_args(["disk_cache_size_mb", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ disk_cache_size = list_to_integer(Num) });
parse_cli_args(["packing_rate", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ packing_rate = list_to_integer(Num) });
parse_cli_args(["max_vdf_validation_thread_count", Num | Rest], C) ->
	parse_cli_args(Rest,
			C#config{ max_nonce_limiter_validation_thread_count = list_to_integer(Num) });
parse_cli_args(["max_vdf_last_step_validation_thread_count", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			max_nonce_limiter_last_step_validation_thread_count = list_to_integer(Num) });
parse_cli_args(["vdf_server_trusted_peer", Peer | Rest], C) ->
	#config{ nonce_limiter_server_trusted_peers = Peers } = C,
	parse_cli_args(Rest, C#config{ nonce_limiter_server_trusted_peers = [Peer | Peers] });
parse_cli_args(["vdf_client_peer", RawPeer | Rest],
		C = #config{ nonce_limiter_client_peers = Peers }) ->
	parse_cli_args(Rest, C#config{ nonce_limiter_client_peers = [RawPeer | Peers] });
parse_cli_args(["debug" | Rest], C) ->
	parse_cli_args(Rest, C#config{ debug = true });
parse_cli_args(["repair_rocksdb", Path | Rest], #config{ repair_rocksdb = L } = C) ->
	parse_cli_args(Rest, C#config{ repair_rocksdb = [filename:absname(Path) | L] });
parse_cli_args(["run_defragmentation" | Rest], C) ->
	parse_cli_args(Rest, C#config{ run_defragmentation = true });
parse_cli_args(["defragmentation_trigger_threshold", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ defragmentation_trigger_threshold = list_to_integer(Num) });
parse_cli_args(["block_throttle_by_ip_interval", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{ block_throttle_by_ip_interval = list_to_integer(Num) });
parse_cli_args(["block_throttle_by_solution_interval", Num | Rest], C) ->
	parse_cli_args(Rest, C#config{
			block_throttle_by_solution_interval = list_to_integer(Num) });
parse_cli_args(["defragment_module", DefragModuleString | Rest], C) ->
	DefragModules = C#config.defragmentation_modules,
	try
		DefragModule = ar_config:parse_storage_module(DefragModuleString),
		DefragModules2 = [DefragModule | DefragModules],
		parse_cli_args(Rest, C#config{ defragmentation_modules = DefragModules2 })
	catch _:_ ->
		io:format("~ndefragment_module value must be in the [number],[address] format.~n~n"),
		erlang:halt()
	end;
parse_cli_args([Arg | _Rest], _O) ->
	io:format("~nUnknown argument: ~s.~n", [Arg]),
	show_help().

%% @doc Start an Arweave node on this BEAM.
start() ->
	start(?DEFAULT_HTTP_IFACE_PORT).
start(Port) when is_integer(Port) ->
	start(#config{ port = Port });
start(Config) ->
	%% Start the logging system.
	ok = application:set_env(arweave, config, Config),
	filelib:ensure_dir(Config#config.log_dir ++ "/"),
	io:format(
		"~n****************************************~n"
		"Launching with config:~n~s~n"
		"****************************************~n",
		[ar_config:format_config(Config)]),
	warn_if_single_scheduler(),
	case Config#config.nonce_limiter_server_trusted_peers of
		[] ->
			ar_bench_vdf:run_benchmark();
		_ ->
			ok
	end,
	{ok, _} = application:ensure_all_started(arweave, permanent).

start(normal, _Args) ->
	{ok, Config} = application:get_env(arweave, config),
	%% Configure logging for console output.
	LoggerFormatterConsole = #{
		legacy_header => false,
		single_line => true,
		chars_limit => 16256,
		max_size => 8128,
		depth => 256,
		template => [time," [",level,"] ",mfa,":",line," ",msg,"\n"]
	},
	logger:set_handler_config(default, formatter, {logger_formatter, LoggerFormatterConsole}),
	logger:set_handler_config(default, level, error),
	%% Configure logging to the logfile.
	LoggerConfigDisk = #{
		file => lists:flatten(filename:join(Config#config.log_dir, atom_to_list(node()))),
		type => wrap,
		max_no_files => 10,
		max_no_bytes => 51418800 % 10 x 5MB
	},
	logger:add_handler(disk_log, logger_disk_log_h,
			#{ config => LoggerConfigDisk, level => info }),
	Level =
		case Config#config.debug of
			false ->
				info;
			true ->
				DebugLoggerConfigDisk = #{
					file => lists:flatten(filename:join([Config#config.log_dir, "debug_logs",
							atom_to_list(node())])),
					type => wrap,
					max_no_files => 20,
					max_no_bytes => 51418800 % 10 x 5MB
				},
				logger:add_handler(disk_debug_log, logger_disk_log_h,
						#{ config => DebugLoggerConfigDisk, level => debug }),
				debug
		end,
	LoggerFormatterDisk = #{
		chars_limit => 16256,
		max_size => 8128,
		depth => 256,
		legacy_header => false,
		single_line => true,
		template => [time," [",level,"] ",mfa,":",line," ",msg,"\n"]
	},
	logger:set_handler_config(disk_log, formatter, {logger_formatter, LoggerFormatterDisk}),
	logger:set_application_level(arweave, Level),
	%% Start the Prometheus metrics subsystem.
	prometheus_registry:register_collector(prometheus_process_collector),
	prometheus_registry:register_collector(ar_metrics_collector),
	%% Register custom metrics.
	ar_metrics:register(Config#config.metrics_dir),
	%% Verify port collisions when gateway is enabled.
	case {Config#config.port, Config#config.gateway_domain} of
		{P, D} when is_binary(D) andalso (P == 80 orelse P == 443) ->
			io:format(
				"~nThe port must be different than 80 or 443 when the gateway is enabled.~n~n"),
			erlang:halt();
		_ ->
			do_nothing
	end,
	%% Start other apps which we depend on.
	ok = prepare_graphql(),
	case Config#config.ipfs_pin of
		false -> ok;
		true  -> app_ipfs:start_pinning()
	end,
	set_mining_address(Config),
	ar_chunk_storage:run_defragmentation(),
	%% Start Arweave.
	ar_sup:start_link().

set_mining_address(#config{ mining_addr = not_set } = C) ->
	W = ar_wallet:get_or_create_wallet([{?RSA_SIGN_ALG, 65537}]),
	Addr = ar_wallet:to_address(W),
	ar:console("~nSetting the mining address to ~s.~n", [ar_util:encode(Addr)]),
	C2 = C#config{ mining_addr = Addr },
	application:set_env(arweave, config, C2),
	set_mining_address(C2);
set_mining_address(#config{ mine = false }) ->
	ok;
set_mining_address(#config{ mining_addr = Addr }) ->
	case ar_wallet:load_key(Addr) of
		not_found ->
			ar:console("~nThe mining key for the address ~s was not found."
				" Make sure you placed the file in [data_dir]/~s (the node is looking for"
				" [data_dir]/~s/[mining_addr].json or "
				"[data_dir]/~s/arweave_keyfile_[mining_addr].json file)."
				" Do not specify \"mining_addr\" if you want one to be generated.~n~n",
				[ar_util:encode(Addr), ?WALLET_DIR, ?WALLET_DIR, ?WALLET_DIR]),
			erlang:halt();
		_Key ->
			ok
	end.

create_wallet([DataDir]) ->
	case filelib:is_dir(DataDir) of
		false ->
			create_wallet_fail();
		true ->
			ok = application:set_env(arweave, config, #config{ data_dir = DataDir }),
			W = ar_wallet:new_keyfile({?RSA_SIGN_ALG, 65537}),
			Addr = ar_wallet:to_address(W),
			ar:console("Created a wallet with address ~s.~n", [ar_util:encode(Addr)]),
			erlang:halt()
	end;
create_wallet(_) ->
	create_wallet_fail().

create_wallet() ->
	create_wallet_fail().

create_wallet_fail() ->
	io:format("Usage: ./bin/create-wallet [data_dir]~n"),
	erlang:halt().

benchmark_packing() ->
	benchmark_packing([]).
benchmark_packing(Args) ->
	ar_bench_timer:initialize(),
	ar_bench_packing:run_benchmark_from_cli(Args),
	erlang:halt().

benchmark_vdf() ->
	ar_bench_vdf:run_benchmark(),
	erlang:halt().

shutdown([NodeName]) ->
	rpc:cast(NodeName, init, stop, []).

stop(_State) ->
	ok.

stop_dependencies() ->
	{ok, [_Kernel, _Stdlib, _SASL, _OSMon | Deps]} = application:get_key(arweave, applications),
	lists:foreach(fun(Dep) -> application:stop(Dep) end, Deps).

prepare_graphql() ->
	ok = ar_graphql:load_schema(),
	ok.

%% One scheduler => one dirty scheduler => Calculating a RandomX hash, e.g.
%% for validating a block, will be blocked on initializing a RandomX dataset,
%% which takes minutes.
warn_if_single_scheduler() ->
	case erlang:system_info(schedulers_online) of
		1 ->
			?LOG_WARNING(
				"WARNING: Running only one CPU core / Erlang scheduler may cause issues.");
		_ ->
			ok
	end.

%% @doc Run all of the tests associated with the core project.
tests() ->
	tests(?CORE_TEST_MODS, #config{ debug = true }).

tests(Mods, Config) when is_list(Mods) ->
	start_for_tests(Config),
	case eunit:test({timeout, ?TEST_TIMEOUT, [Mods]}, [verbose, {print_depth, 100}]) of
		ok ->
			ok;
		_ ->
			exit(tests_failed)
	end.

start_for_tests() ->
	start_for_tests(#config{}).

start_for_tests(Config) ->
	start(Config#config{
		peers = [],
		data_dir = "data_test_master",
		metrics_dir = "metrics_master",
		disable = [randomx_jit],
		packing_rate = 20,
		auto_join = false
	}).

%% @doc Run the tests for a set of module(s).
%% Supports strings so that it can be trivially induced from a unix shell call.
tests(Mod) when not is_list(Mod) -> tests([Mod]);
tests(Args) ->
	Mods =
		lists:map(
			fun(Mod) when is_atom(Mod) -> Mod;
			   (Str) -> list_to_atom(Str)
			end,
			Args
		),
	tests(Mods, #config{}).

%% @doc Run the tests for the IPFS integration. Requires a running local IPFS node.
test_ipfs() ->
	Mods = [app_ipfs_tests],
	tests(Mods, #config{}).

%% @doc Generate the project documentation.
docs() ->
	Mods =
		lists:filter(
			fun(File) -> filename:extension(File) == ".erl" end,
			element(2, file:list_dir("apps/arweave/src"))
		),
	edoc:files(
		["apps/arweave/src/" ++ Mod || Mod <- Mods],
		[
			{dir, "source_code_docs"},
			{hidden, true},
			{private, true}
		]
	).

%% @doc Ensure that parsing of core command line options functions correctly.
commandline_parser_test_() ->
	{timeout, 20, fun() ->
		Addr = crypto:strong_rand_bytes(32),
		Tests =
			[
				{"peer 1.2.3.4 peer 5.6.7.8:9", #config.peers, [{5,6,7,8,9},{1,2,3,4,1984}]},
				{"mine", #config.mine, true},
				{"port 22", #config.port, 22},
				{"mining_addr "
					++ binary_to_list(ar_util:encode(Addr)), #config.mining_addr, Addr}
			],
		X = string:split(string:join([ L || {L, _, _} <- Tests ], " "), " ", all),
		C = parse_cli_args(X, #config{}),
		lists:foreach(
			fun({_, Index, Value}) ->
				?assertEqual(element(Index, C), Value)
			end,
			Tests
		)
	end}.

-ifdef(DEBUG).
console(_) ->
	ok.

console(_, _) ->
	ok.
-else.
console(Format) ->
	io:format(Format).

console(Format, Params) ->
	io:format(Format, Params).
-endif.
