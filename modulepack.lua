local conf, verb = ...
local conf_file = assert(io.open(conf, "rb"))
local base_path = conf:match("^(.+[\\/])[^\\/]+$") or ""
local parts = {}
local seen = {}
local mod_names = {}
local lineinfo = {}
for mod_name in conf_file:lines() do
	if seen[mod_name] then
		error("duplicate module " .. mod_name)
	end
	seen[mod_name] = true
	table.insert(mod_names, mod_name)
end
conf_file:close()
local function count_lines(str)
	local count = 0
	for _ in str:gmatch("\n") do
		count = count + 1
	end
	return count
end
local first_mod_name = mod_names[1]
local last_line = 2
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
	table.insert(lineinfo, { line = last_line, mod_name = mod_name })
	last_line = last_line + count_lines(mod_content) + 4
	mod_file:close()
	table.insert(parts, [[require("register", "]] .. mod_name .. [[", function()
]])
	table.insert(parts, mod_content)
	table.insert(parts, [[

end)

]])
end
assert(first_mod_name, "no modules specified")
table.insert(parts, [[return require("run", "]] .. first_mod_name .. [[")
]])
local function head()
	local lineinfo_strs = {}
	for _, info in ipairs(lineinfo) do
		table.insert(lineinfo_strs, ([[{ line = %i, mod_name = "%s" }]]):format(info.line, info.mod_name))
	end
	return [[
_G.require = (function()
	local lineinfo = {
]] .. table.concat(lineinfo_strs, ",\n") .. [[

	}

	local unpack = rawget(_G, "unpack") or table.unpack
	local function packn(...)
		return { [ 0 ] = select("#", ...), ... }
	end
	local function unpackn(tbl, from, to)
		return unpack(tbl, from or 1, to or tbl[0])
	end
	local chunkname = debug.getinfo(1, "S").source
	if chunkname:find("^[=@]") then
		chunkname = chunkname:sub(2)
	else
		chunkname = nil
	end
	local function escape_regex(str)
		return (str:gsub("[%$%%%(%)%*%+%-%.%?%]%[%^]", "%%%1"))
	end
	local function demangle(str)
		if chunkname then
			return str:gsub(escape_regex(chunkname) .. ":(%d+)", function(line)
				line = tonumber(line)
				for i = #lineinfo, 1, -1 do
					if lineinfo[i].line <= line then
						return ("%s$%s:%i"):format(chunkname, lineinfo[i].mod_name, line - lineinfo[i].line + 1)
					end
				end
			end)
		end
		return str
	end
	local function traceback(...)
		return demangle(debug.traceback(...))
	end
	local function xpcall_wrap(func, handler)
		return function(...)
			local iargs = packn(...)
			local oargs
			xpcall(function()
				oargs = packn(func(unpackn(iargs)))
			end, function(err)
				if type(err) == "string" then
					err = demangle(err)
				end
				if handler then
					handler(err)
				end
				if type(err) == "string" then
					print(traceback(err, 2))
				end
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

	mod_result["modulepack"] = {
		packn       = packn,
		unpackn     = unpackn,
		xpcall_wrap = xpcall_wrap,
		traceback   = traceback,
	}
	mod_state["modulepack"] = "loaded"

	local function temp_require(verb, reg_mod_name, reg_func)
		if not finalized then
			if verb == "run" then
				finalized = true
				_G.require = real_require
				return xpcall_wrap(temp_require(reg_mod_name).run)()
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
			mod_result[mod_name] = xpcall_wrap(mod_func[mod_name])()
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

]]
end
table.insert(parts, 1, head())
local head_lines = count_lines(parts[1])
for _, info in ipairs(lineinfo) do
	info.line = info.line + head_lines
end
parts[1] = head()
local script = table.concat(parts)
if verb == "run" then
	local func = assert(load(script, "=modulepack-" .. first_mod_name, "t"))
	return func(select(3, ...))
end
io.stdout:write(script)
