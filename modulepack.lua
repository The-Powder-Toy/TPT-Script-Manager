local conf, verb = ...
local conf_file = assert(io.open(conf, "rb"))
local base_path = conf:match("^(.+[\\/])[^\\/]+$") or ""
local parts = {}
table.insert(parts, [[
_G.require = (function()
	local unpack = rawget(_G, "unpack") or table.unpack
	local function packn(...)
		return { [ 0 ] = select("#", ...), ... }
	end
	local function unpackn(tbl, from, to)
		return unpack(tbl, from or 1, to or tbl[0])
	end
	local function xpcall_wrap(func, handler)
		return function(...)
			local iargs = packn(...)
			local oargs
			xpcall(function()
				oargs = packn(func(unpackn(iargs)))
			end, function(err)
				if handler then
					handler(err)
				end
				print(debug.traceback(err, 2))
				return err
			end)
			if oargs then
				return unpackn(oargs)
			end
		end
	end

	local real_require = _G.require
	local mod_func = {}
	local mod_state = {}
	local mod_result = {}
	local finalized = false

	local function temp_require(verb, reg_mod_name, reg_func)
		if not finalized then
			if verb == "run" then
				finalized = true
				_G.require = real_require
				xpcall_wrap(function()
					temp_require(reg_mod_name).run()
				end)()
			elseif verb == "getenv" then
				local env = setmetatable({}, { __index = function(_, key)
					error("__index on env: " .. tostring(key), 2)
				end, __newindex = function(_, key)
					error("__newindex on env: " .. tostring(key), 2)
				end })
				for key, value in pairs(_G) do
					rawset(env, key, value)
				end
				rawset(env, "require", temp_require)
				rawset(env, "xpcall_wrap", xpcall_wrap)
				return env
			elseif verb == "register" then
				mod_func[reg_mod_name] = reg_func
			else
				error("bad verb")
			end
			return
		end
		local mod_name = verb
		if mod_state[mod_name] ~= "loaded" then
			if mod_state[mod_name] == "loading" then
				error("circular dependency", 2)
			end
			mod_state[mod_name] = "loading"
			mod_result[mod_name] = mod_func[mod_name]()
			mod_state[mod_name] = "loaded"
		end
		return mod_result[mod_name]
	end
	return temp_require
end)()

if rawget(_G, "setfenv") then
	setfenv(1, require("getenv"))
else
	_ENV = require("getenv")
end

]])
local seen = {}
local mod_names = {}
for mod_name in conf_file:lines() do
	if seen[mod_name] then
		error("duplicate module " .. mod_name)
	end
	seen[mod_name] = true
	table.insert(mod_names, mod_name)
end
conf_file:close()
local first_mod_name = mod_names[1]
table.sort(mod_names)
for _, mod_name in ipairs(mod_names) do
	local firsterr
	local mod_file
	for _, path_to_try in ipairs({
		base_path .. mod_name:gsub("%.", "/") .. ".lua",
		base_path .. mod_name:gsub("%.", "/") .. "/init.lua",
	}) do
		local err
		mod_file, err = io.open(path_to_try, "rb")
		if mod_file then
			break
		else
			if not firsterr then
				firsterr = err
			end
		end
	end
	if not mod_file then
		error(firsterr)
	end
	local mod_content = assert(mod_file:read("*a"))
	mod_file:close()
	table.insert(parts, [[require("register", "]])
	table.insert(parts, mod_name)
	table.insert(parts, [[", function()
]])
	table.insert(parts, mod_content)
	table.insert(parts, [[end)

]])
end
assert(first_mod_name, "no modules specified")
table.insert(parts, [[require("run", "]])
table.insert(parts, first_mod_name)
table.insert(parts, [[")
]])
local script = table.concat(parts)
if verb == "run" then
	local func = assert(load(script, first_mod_name, "t"))
	func()
	return
end
io.stdout:write(script)
