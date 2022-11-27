local serde       = require("manager.serde")
local util        = require("manager.util")
local atexit      = require("manager.atexit")
local logger      = require("manager.logger")
local config      = require("manager.config")
local environment = require("manager.environment")
local sandbox     = require("manager.sandbox")

local manager = {
	how_are_you_holding_up = "because I'm a potato",
}

local log = logger.make_logger("manager")
local log_manager = log

local atexit_manager = atexit.make_atexit()
function manager.unload()
	local log = log:sub("unloading manager")
	atexit_manager:exit(log)
end

local function add_permanent_global(key, value)
	_G[key] = value
	atexit_manager:atexit(function()
		_G[key] = nil
	end)
end

local function add_permanent_event(name, func)
	event.register(name, func)
	atexit_manager:atexit(function()
		event.unregister(name, func)
	end)
end

local function tick_handler()
	-- TODO
	config.save_if_needed()
end

local function mousedown_handler(x, y, button)
	-- return myimgui:mousedown_handler(button)
	-- TODO
end

local function mouseup_handler(x, y, button, reason)
	-- return myimgui:mouseup_handler(button, reason)
	-- TODO
end

local function mousewheel_handler(x, y, offset)
	-- return myimgui:mousewheel_handler(offset)
	-- TODO
end

local function mousemove_handler(x, y)
	-- return myimgui:mousemove_handler(x, y)
	-- TODO
end

local function blur_handler()
	-- return myimgui:blur_handler()
	-- TODO
end

local function close_handler()
	manager.unload()
end

if not tpt.version or util.version_less({ tpt.version.major, tpt.version.minor }, { 97, 0 }) then
	error("version not supported")
end
if _G.manager ~= nil then
	local failed
	if type(_G.manager) == "table" and _G.manager.how_are_you_holding_up == "because I'm a potato" then
		environment.xpcall_wrap(_G.manager.unload, function(_, full)
			print("top-level error: " .. full)
			failed = true
		end)()
	else
		failed = true
	end
	if failed then
		error("failed to unload active script manager instance, try restarting TPT")
	end
end
add_permanent_global("manager", manager)

local function event_error_handler(_, full)
	print("top-level error: " .. full)
end
add_permanent_event(event.tick      , environment.xpcall_wrap(tick_handler      , event_error_handler))
add_permanent_event(event.mousedown , environment.xpcall_wrap(mousedown_handler , event_error_handler))
add_permanent_event(event.mouseup   , environment.xpcall_wrap(mouseup_handler   , event_error_handler))
add_permanent_event(event.mousewheel, environment.xpcall_wrap(mousewheel_handler, event_error_handler))
add_permanent_event(event.mousemove , environment.xpcall_wrap(mousemove_handler , event_error_handler))
add_permanent_event(event.blur      , environment.xpcall_wrap(blur_handler      , event_error_handler))
add_permanent_event(event.close     , environment.xpcall_wrap(close_handler     , event_error_handler))

local function validate_script_manifest(manifest)
	if type(manifest) ~= "table" then
		return nil, "root is not a table"
	end
	if type(manifest.dependencies) ~= "table" then
		return nil, ".dependencies is not a table"
	end
	local ok, bad_key = util.pure_array(manifest.dependencies)
	if not ok then
		return nil, (".dependencies is not a pure array due to key %s"):format(tostring(bad_key))
	end
	for index, value in ipairs(manifest.dependencies) do
		if type(value) ~= "string" then
			return nil, (".dependencies has non-string item %s at index %i"):format(tostring(value, index))
		end
	end
	return true
end

local script_providers, index_scripts
do
	local function make_loader(vfs)
		return function(name)
			local manifest_path = util.join_paths(name, "manifest")
			local manifest
			if vfs.is_file(manifest_path) then
				local str, err = vfs.read_file(manifest_path)
				if not str then
					return nil, ("failed to read manifest: %s: %s"):format(vfs.resolve(manifest_path), err)
				end
				local ok, data = serde.deserialize(str, vfs.resolve(manifest_path))
				if not ok then
					return nil, ("failed to read manifest: %s: %s"):format(vfs.resolve(manifest_path), data)
				end
				manifest = data
			else
				manifest = {
					dependencies = {},
					top_level    = true,
				}
			end
			local ok, err = validate_script_manifest(manifest)
			if not ok then
				return nil, ("invalid manifest: %s"):format(err)
			end
			local chunks = {}
			local to_visit = {
				{ path = name .. ".lua", dir = false, link_allowed = true },
				{ path = name, dir = true , link_allowed = true },
			}
			while next(to_visit) do
				local next_to_visit = {}
				for _, entry in ipairs(to_visit) do
					if not vfs.is_link(entry.path) or entry.link_allowed then
						if entry.dir then
							if vfs.is_dir(entry.path) then
								local list, err = vfs.list_dir(entry.path)
								if not list then
									return nil, ("failed to list directory %s: %s: %s"):format(entry.path, vfs.resolve(entry.path), err)
								end
								for _, item in ipairs(list) do
									local path = util.join_paths(entry.path, item)
									if vfs.is_dir(path) then
										table.insert(next_to_visit, { path = path, dir = true, link_allowed = false })
									elseif vfs.is_file(path) then
										table.insert(next_to_visit, { path = path, dir = false, link_allowed = false })
									end
								end
							end
						else
							if vfs.is_file(entry.path) then
								local data, err = vfs.read_file(entry.path)
								if not data then
									return nil, ("failed to read chunk %s: %s: %s"):format(entry.path, vfs.resolve(entry.path), err)
								end
								chunks[entry.path] = data
							end
						end
					end
				end
				to_visit = next_to_visit
			end
			return {
				dependencies   = util.array_to_keys(manifest.dependencies),
				chunks         = chunks,
				make_sandbox   = manifest.top_level and sandbox.factory(name),
			}
		end
	end
	local provider_user = {
		name = "user",
		precedence = 2,
		load = make_loader({
			is_file = function(path)
				return fs.isFile(util.join_paths(config.scripts_dir, path))
			end,
			is_dir = function(path)
				return fs.isDirectory(util.join_paths(config.scripts_dir, path))
			end,
			is_link = function(path)
				return fs.isLink(config.scripts_dir, path)
			end,
			list_dir = function(path)
				return fs.list(util.join_paths(config.scripts_dir, path))
			end,
			read_file = function(path)
				return util.read_file(util.join_paths(config.scripts_dir, path))
			end,
			write_file = function(path)
				return util.write_file(util.join_paths(config.scripts_dir, path))
			end,
			resolve = function(path)
				return util.join_paths(config.scripts_dir, path)
			end,
		}),
	}
	local provider_bundle = {
		name = "bundle",
		precedence = 1,
		load = function(name)
			-- TODO
			return {
				dependencies = {},
			}
		end,
	}

	function index_scripts(log)
		local log = log:sub("indexing scripts in user script directory %s", config.scripts_dir)

		script_providers = {}
		local function index_one(name, provider)
			local script_log = log:sub("found script %s with provider %s", name, provider.name)
			if not name:find(config.module_pattern) then
				script_log:err("discarding script provider due to its invalid name")
				return
			end
			script_providers[name] = script_providers[name] or {}
			script_providers[name][provider.name] = provider
		end

		for _, item in ipairs(fs.list(config.scripts_dir)) do
			local full_item = util.join_paths(config.scripts_dir, item)
			if fs.isDirectory(full_item) and fs.isFile(util.join_paths(full_item, "init.lua")) then
				index_one(item, provider_user)
			elseif fs.isFile(full_item) then
				local name_lua = item:match("^(.+)%.lua$")
				if name_lua then
					index_one(name_lua, provider_user)
				end
				local name_bundle = item:match("^(.+)%.bundle$")
				if name_bundle then
					index_one(name_bundle, provider_bundle)
				end
			end
		end
	end
end

local loaded_scripts = {}

local atexit_scripts, atexit_scripts_entry
local function init_atexit_scripts()
	atexit_scripts = atexit.make_atexit()
	atexit_scripts_entry = atexit_manager:atexit(function(log)
		local log = log:sub("unloading scripts")
		atexit_scripts:exit(log)
	end)
end

local unload_script

local function load_script(log, name, provider_name)
	local log = log:sub("loading script %s", name)
	assert(not loaded_scripts[name])
	local provider = script_providers[name] and script_providers[name][provider_name]
	if not provider then
		log:err("cannot load script with provider %s: provider unavailable", tostring(provider_name))
		return nil, "prune"
	end
	local info, err = provider.load(name)
	if not info then
		log:err("cannot load script with provider %s: %s", tostring(provider_name), tostring(err))
		return nil, "prune"
	end
	local script = {
		info                   = info,
		name                   = name,
		atexit                 = atexit.make_atexit(),
		initialized_dependents = {},
	}
	loaded_scripts[name] = script
	script.atexit:atexit(function()
		loaded_scripts[name] = nil
	end)
	script.loaded = atexit_scripts:atexit(function(log)
		local log = (log or log_manager):sub("unloading script %s", script.name)
		script.atexit:exit(log)
	end)
	return true
end

function unload_script(log, script)
	assert(script)
	script.loaded:exit_now(log)
end

local uninitialize_script

local function initialize_script(log, script)
	assert(script and not script.initialized)
	local log = log:sub("initializing script %s", script.name)
	for dependency in pairs(script.info.dependencies) do
		if not loaded_scripts[dependency] then
			log:err("failed to initialize script: dependency %s has not been loaded")
			return
		end
	end
	for dependency in pairs(script.info.dependencies) do
		loaded_scripts[dependency].initialized_dependents[script.name] = true
	end
	script.initialized = script.atexit:atexit(function(log)
		local log = (log or log_manager):sub("uninitializing script %s", script.name)
		util.foreach_clean(script.initialized_dependents, function(dependent)
			loaded_scripts[dependent].initialized:exit_now(log)
		end)
		for dependency in pairs(script.info.dependencies) do
			loaded_scripts[dependency].initialized_dependents[script.name] = nil
		end
		script.initialized = nil
	end)
	if script.info.make_sandbox then
		local chunks_with_deps = {}
		util.clone_table(script.info.chunks, chunks_with_deps)
		for dependency in pairs(script.info.dependencies) do
			util.clone_table(loaded_scripts[dependency].info.chunks, chunks_with_deps)
		end
		local sandbox = script.info.make_sandbox(chunks_with_deps)
		script.atexit:atexit(function(log)
			sandbox.exit(log)
		end)
		local err_outer
		local ok = true
		environment.xpcall_wrap(sandbox.entrypoint, function(err, full)
			ok = false
			err_outer = err
			log:err("error in sandbox entrypoint: %s", full)
		end)()
		if not ok then
			log:err("failed to initialize script: %s", tostring(err_outer))
			uninitialize_script(log, script)
			return
		end
	end
	return true
end

function uninitialize_script(log, script)
	assert(script and script.initialized)
	script.initialized:exit_now(log)
end

local function autoload_scripts(log)
	local log = log:sub("autoloading scripts")
	local prune = {}
	for name, info in pairs(config.dynamic.scripts) do
		if not loaded_scripts[name] and info.provider then
			local ok, action = load_script(log, name, info.provider)
			if not ok then
				if action == "prune" then
					prune[name] = true
				end
			end
		end
	end
	do
		local to_visit = {}
		local name_to_dependencies = {}
		local name_to_dependents = {}
		for name, script in pairs(loaded_scripts) do
			local dependencies = util.clone_table(script.info.dependencies)
			name_to_dependencies[name] = dependencies
			name_to_dependents[name] = {}
			if not next(dependencies) then
				to_visit[name] = true
			end
		end
		for name, dependencies in pairs(name_to_dependencies) do
			for dependency in pairs(dependencies) do
				name_to_dependents[dependency][name] = true
			end
		end
		while next(to_visit) do
			local next_to_visit = {}
			for name in pairs(to_visit) do
				local script = loaded_scripts[name]
				if script.initialized or initialize_script(log, script) then
					for dependent in pairs(name_to_dependents[name]) do
						local dependencies = name_to_dependencies[dependent]
						dependencies[name] = nil
						if not next(dependencies) then
							next_to_visit[dependent] = true
						end
					end
				end
				name_to_dependencies[name] = nil
			end
			to_visit = next_to_visit
		end
		for name in pairs(name_to_dependencies) do
			log:inf("skipping script %s due to uninitialized dependencies", name)
		end
	end
	if next(prune) then
		local log = log:sub("pruning invalid script info from manager config")
		for name in pairs(prune) do
			log:inf("pruning script %s", name)
			config.dynamic.scripts[name] = nil
			config.defer_save()
		end
	end
	-- TODO: optionally disable scripts that aren't .initialized at this point
end

do
	local log = log:sub("loading manager")
	if not fs.isDirectory(config.manager_dir) then
		assert(fs.makeDirectory(config.manager_dir), "failed to create manager directory")
	end
	if not fs.isDirectory(config.scripts_dir) then
		assert(fs.makeDirectory(config.scripts_dir), "failed to create scripts directory")
	end
	init_atexit_scripts()
	config.load_now(log)
	if type(config.dynamic) ~= "table" then
		config.dynamic = {}
		config.defer_save()
	end
	index_scripts(log)
	if type(config.dynamic.scripts) ~= "table" then
		config.dynamic.scripts = {}
		config.defer_save()
	end
	autoload_scripts(log)
end

function manager.reload_scripts()
	local log = log:sub("reloading scripts")
	atexit_scripts_entry:exit_now(log)
	init_atexit_scripts()
	autoload_scripts(log)
end

function manager.load_script(name, provider_name)
	if loaded_scripts[name] then
		error("script already loaded", 2)
	end
	load_script(log, name, provider_name)
end

function manager.unload_script(name)
	if not loaded_scripts[name] then
		error("script not loaded", 2)
	end
	unload_script(log, loaded_scripts[name])
end

function manager.initialize_script(name)
	if not loaded_scripts[name] then
		error("script not loaded", 2)
	end
	if loaded_scripts[name].initialized then
		error("script already initialized", 2)
	end
	initialize_script(log, loaded_scripts[name])
end

function manager.uninitialize_script(name)
	if not loaded_scripts[name] then
		error("script not loaded", 2)
	end
	if not loaded_scripts[name].initialized then
		error("script not initialized", 2)
	end
	uninitialize_script(log, loaded_scripts[name])
end
