local serde  = require("manager.serde")
local util   = require("manager.util")

local config = {
	manager_dir    = "managerv4",
	scripts_dir    = "scripts",
	config_file    = "config",
	module_pattern = "^[a-zA-Z_][a-zA-Z_0-9]*$",
}

assert(not config.manager_dir:find("[\\/]"))
assert(not config.scripts_dir:find("[\\/]"))
assert(not config.config_file:find("[\\/]"))

config.scripts_dir = util.join_paths(config.manager_dir, config.scripts_dir)
local config_path = util.join_paths(config.manager_dir, config.config_file)

local should_save_config = false

function config.defer_save()
	should_save_config = true
end

function config.save_if_needed()
	if should_save_config then
		should_save_config = false
		local ok, err = serde.write_file(config_path, config.dynamic, true)
		if not ok then
			log:err("failed to save config file: %s", tostring(err))
			return
		end
	end
end

function config.load_now(log)
	local log = log:sub("loading config file %s", config_path)
	if not fs.isFile(config_path) then
		log:inf("file not found")
		return
	end
	do
		local ok, new_root = serde.read_file(config_path)
		if not ok then
			log:err("failed to load config file: %s", tostring(new_root))
			return
		end
		config.dynamic = new_root
	end
end

return config
