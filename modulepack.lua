local conf_list, verb = ...
local parts = {}
local seen = {}
local modinfo = {}
local lineinfo = {}
local function count_lines(str)
	local count = 0
	for _ in str:gmatch("\n") do
		count = count + 1
	end
	return count
end
for conf in conf_list:gmatch("[^:]+") do
	if conf ~= "" then
		local conf_file = assert(io.open(conf, "rb"))
		local base_path = conf:match("^(.+[\\/])[^\\/]+$") or ""
		for mod_name in conf_file:lines() do
			if seen[mod_name] then
				error(("duplicate module %q"):format(mod_name), 0)
			end
			seen[mod_name] = true
			table.insert(modinfo, {
				base_path = base_path,
				mod_name  = mod_name,
			})
		end
		conf_file:close()
	end
end
local first_mod_name = modinfo[1].mod_name
table.sort(modinfo, function(lhs, rhs)
	return lhs.mod_name < rhs.mod_name
end)
table.insert(parts, [[
if rawget(_G, "setfenv") then
	setfenv(1, { _G = _G, modules = {} })
else
	_ENV = { _G = _G, modules = {} }
end

]])
local last_line = count_lines(parts[1]) + 2
for _, info in ipairs(modinfo) do
	local firsterr
	local mod_file
	local as_path = info.mod_name:gsub("%.", "/")
	for _, path_to_try in ipairs({
		("%s%s.lua"     ):format(info.base_path, as_path),
		("%s%s/init.lua"):format(info.base_path, as_path),
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
		error(firsterr, 0)
	end
	local mod_content = assert(mod_file:read("*a"))
	local mod_lines = count_lines(mod_content)
	table.insert(lineinfo, { mod_name = info.mod_name, line = last_line, mod_lines = mod_lines })
	last_line = last_line + mod_lines + 4
	mod_file:close()
	table.insert(parts, ([[modules[%q] = function()
]]):format(info.mod_name))
	table.insert(parts, mod_content)
	table.insert(parts, [[

end

]])
end
table.sort(lineinfo, function(lhs, rhs)
	return lhs.line > rhs.line
end)
local lineinfo_strs = {}
for _, info in ipairs(lineinfo) do
	table.insert(lineinfo_strs, ("{ mod_name = %q, line = %i, mod_lines = %i }"):format(info.mod_name, info.line, info.mod_lines))
end
assert(first_mod_name, "no modules specified")
table.insert(parts, [[

return (function(...)
	local first_mod_name = ]] .. ("%q"):format(first_mod_name) .. [[
	local senv
	local _ENV = _ENV
	if _G.rawget(_G, "setfenv") then
		senv = _G.getfenv(1)
		_G.setfenv(1, _G)
	else
		senv = _ENV
		_ENV = _G
	end
	local modules = senv.modules
	senv.modules = nil

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
]])
local demangle = [[
	local lineinfo = {
		]] .. table.concat(lineinfo_strs, ",\n\t\t") .. [[

	}
	local function escape_regex(str)
		return (str:gsub("[%$%%%(%)%*%+%-%.%?%]%[%^]", "%%%1"))
	end
	local function demangle(str)
		if chunkname then
			return (str:gsub(escape_regex(chunkname) .. ":(%d+)", function(line)
				line = tonumber(line)
				for _, info in ipairs(lineinfo) do
					if info.line <= line then
						local mod_line = line - info.line + 1
						if mod_line <= info.mod_lines then
							return ("%s$%s:%i"):format(chunkname, info.mod_name, mod_line)
						end
					end
				end
			end))
		end
		return str
	end
]]
table.insert(parts, demangle)
table.insert(parts, [[
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

	local mod_state = {}
	local mod_result = {}
	local function modulepack_require(mod_name)
		if mod_state[mod_name] ~= "loaded" then
			local func = modules[mod_name]
			if not func then
				error(("module %q not found"):format(mod_name), 2)
			end
			if mod_state[mod_name] == "loading" then
				error("circular dependency", 2)
			end
			mod_state[mod_name] = "loading"
			local ok = true
			mod_result[mod_name] = xpcall_wrap(func, function()
				ok = false
			end)()
			if not ok then
				mod_state[mod_name] = "failed"
				error("module failed", 2)
			end
			mod_state[mod_name] = "loaded"
		end
		return mod_result[mod_name]
	end

	for key, value in pairs(_G) do
		rawset(senv, key, value)
	end
	rawset(senv, "require", modulepack_require)
	setmetatable(senv, { __index = function(_, key)
		error(("__index on env: %s"):format(tostring(key)), 2)
	end, __newindex = function(_, key)
		error(("__newindex on env: %s"):format(tostring(key)), 2)
	end })

	mod_result["modulepack"] = {
		packn       = packn,
		unpackn     = unpackn,
		xpcall_wrap = xpcall_wrap,
		demangle    = demangle,
		traceback   = traceback,
	}
	mod_state["modulepack"] = "loaded"

	local ok = true
	local ret = packn(xpcall_wrap(function(...)
		modulepack_require(first_mod_name).run(...)
	end, function()
		ok = false
	end)(...))
	if not ok then
		error("entry point failed", 2)
	end
	return unpackn(ret)
end)(...)
]])
local script = table.concat(parts)
do
	local chunkname = "modulepack-" .. first_mod_name
	local func, err = load(script, "=" .. chunkname, "t")
	if not func then
		local demangle = assert(load([[
			local chunkname = ]] .. ("%q"):format(chunkname) .. [[
]] .. demangle .. [[

return demangle
]], "=demangle", "t"))()
		error("load-time error: " .. tostring(demangle(err)), 0)
	end
	if verb == "getfunc" then
		return func
	end
	if verb == "run" then
		return func(select(3, ...))
	end
end
io.stdout:write(script)
