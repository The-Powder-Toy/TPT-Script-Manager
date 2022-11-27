local this_env, load_with_env, unpack, ipairs
if rawget(_G, "loadstring") then
	this_env = getfenv(1)
	function load_with_env(str, src, env)
		local func, err = loadstring(str, src)
		if not func then
			return nil, err
		end
		return setfenv(func, env)
	end
	unpack = _G.unpack
	ipairs = _G.ipairs
	local real_ipairs = ipairs
	local real_pairs = pairs
	function ipairs(tbl)
		local mt = type(tbl) == "table" and getmetatable(tbl)
		if mt and mt.__ipairs then
			return mt.__ipairs(tbl)
		end
		return real_ipairs(tbl)
	end
	function pairs(tbl)
		local mt = type(tbl) == "table" and getmetatable(tbl)
		if mt and mt.__pairs then
			return mt.__pairs(tbl)
		end
		return real_pairs(tbl)
	end
else
	this_env = _ENV
	function load_with_env(str, src, env)
		return load(str, src, "t", env)
	end
	unpack = table.unpack
	local function inext(tbl, key)
		key = key + 1
		if tbl[key] ~= nil then
			return key, tbl[key]
		end
	end
	function ipairs(tbl)
		local mt = type(tbl) == "table" and getmetatable(tbl)
		if mt and mt.__ipairs then
			return mt.__ipairs(tbl)
		end
		return inext, tbl, 0
	end
end

local function masked_metatable(mt)
	mt.__metatable = false
	return mt
end

local string_meta = getmetatable("")
masked_metatable(string_meta)
assert(not getmetatable(""), "cannot mask metatables")

local function make_strict_env(base)
	return setmetatable({}, { __index = function(_, key)
		local value = rawget(base, key)
		if value ~= nil then
			return value
		end
		error("__index on env: " .. tostring(key), 2)
	end, __newindex = function(_, key)
		error("__newindex on env: " .. tostring(key), 2)
	end })
end
local manager_strict_env = make_strict_env(this_env)

local function packn(...)
	return { [ 0 ] = select("#", ...), ... }
end

local function unpackn(tbl, from, to)
	return unpack(tbl, from or 1, to or tbl[0])
end

local function xpcall_wrap(func, handler)
	return function(...)
		local args_in = packn(...)
		local args_out
		if not xpcall(function()
			args_out = packn(func(unpackn(args_in)))
		end, function(err)
			local full = tostring(err) .. "\n" .. debug.traceback()
			if handler then
				handler(err, full)
			end
		end) then
			return
		end
		return unpackn(args_out)
	end
end

local function make_require(readall, env)
	local loading = {}
	local loaded = {}
	local preload = {}
	return function(modname)
		if not loaded[modname] then
			if loading[modname] then
				error("recursive require", 2)
			end
			local components = {}
			local function push(component)
				if not component:find("^[a-zA-Z_][a-zA-Z_0-9]*$") then
					error("invalid module name", 2)
				end
				table.insert(components, component)
			end
			local func = preload[modname]
			if func == nil then
				local modname_part = modname
				while true do
					local dot_at = modname_part:find("%.")
					if not dot_at then
						push(modname_part)
						break
					end
					push(modname_part:sub(1, dot_at - 1))
					modname_part = modname_part:sub(dot_at + 1)
				end
				local dir = table.concat(components, "/")
				local candidates = {
					dir .. "/init.lua",
					dir .. ".lua",
				}
				local chunk
				for _, candidate in ipairs(candidates) do
					chunk = readall(candidate)
					if chunk then
						break
					end
				end
				if not chunk then
					error(("module %s not found"):format(modname), 2)
				end
				local err
				func, err = load_with_env(chunk, "=[module " .. modname .. "]", env)
				if not func then
					error(err, 0)
				end
			end
			if type(func) ~= "function" then
				error("package has a non-function loader", 0)
			end
			loading[modname] = true
			local ok = true
			xpcall_wrap(function()
				result = func()
			end, function(err, full)
				ok = false
				result = err
				print(("error in module %s: %s"):format(modname, full))
			end)()
			loading[modname] = nil
			if not ok then
				error(result, 0)
			end
			if result == nil then
				result = true
			end
			loaded[modname] = result
		end
		return loaded[modname]
	end, {
		preload = preload,
		loaded = loaded,
	}
end

local manager_require, manager_package
local source = debug.getinfo(1).source
local path_to_self = source:match("^@(.*)$")
if not path_to_self then
	error("source string does not seem like a path: " .. source)
end
local module_root = path_to_self:gsub("\\", "/"):match("^(.*/)[^/]*$")
if not module_root then
	error("cannot find module root in source string: " .. path_to_self)
end
local package
manager_require, manager_package = make_require(function(path)
	path = module_root .. path
	if not fs.exists(path) then
		return
	end
	-- TODO: yield once reading files becomes a request
	local handle = assert(io.open(path, "rb"))
	local data = assert(handle:read("*a"))
	assert(handle:close())
	return data
end, manager_strict_env)

manager_package.loaded["manager.environment"] = {
	xpcall_wrap      = xpcall_wrap,
	make_require     = make_require,
	make_strict_env  = make_strict_env,
	load_with_env    = load_with_env,
	string_meta      = string_meta,
	top_level        = manager_strict_env,
	packn            = packn,
	unpackn          = unpackn,
	masked_metatable = masked_metatable,
}
for key, value in pairs({
	ipairs  = ipairs,
	unpack  = unpack,
	require = manager_require,
	package = manager_package,
}) do
	rawset(manager_strict_env, key, value)
end
xpcall_wrap(function()
	manager_require("manager", manager_strict_env)
end, function(_, full)
	print("top-level error: " .. full)
end)()

xpcall_wrap(function()
	dofile("autorun2.lua")
end, function(_, full)
	print("autorun2.lua error: " .. full)
end)()
