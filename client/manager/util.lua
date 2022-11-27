local environment = require("manager.environment")

local function version_less(lhs, rhs)
	for i = 1, math.max(#lhs, #rhs) do
		local left = lhs[i] or 0
		local right = rhs[i] or 0
		if left < right then
			return true
		end
		if left > right then
			return false
		end
	end
	return false
end

local function version_equal(lhs, rhs)
	for i = 1, math.max(#lhs, #rhs) do
		local left = lhs[i] or 0
		local right = rhs[i] or 0
		if left ~= right then
			return false
		end
	end
	return true
end

local function ends_with(str, with)
	return str:sub(-#with, -1) == with
end

local function read_file(path)
	local handle, err = io.open(path, "rb")
	if not handle then
		return nil, err
	end
	local data, err = handle:read("*a")
	if not data then
		return nil, err
	end
	local ok, err = handle:close()
	if not ok then
		return nil, err
	end
	return data
end

local function write_file(path, data)
	local handle, err = io.open(path, "wb")
	if not handle then
		return nil, err
	end
	local ok, err = handle:write(data)
	if not ok then
		return nil, err
	end
	local ok, err = handle:close()
	if not ok then
		return nil, err
	end
	return true
end

local function join_paths(lhs, rhs, ...)
	local combined = lhs .. "/" .. rhs
	if not ... then
		return combined
	end
	return join_paths(combined, ...)
end

local function clone_table(tbl, clone)
	clone = clone or {}
	for key, value in pairs(tbl) do
		clone[key] = value
	end
	return clone
end

local function array_to_keys(tbl)
	local keys = {}
	for _, value in ipairs(tbl) do
		keys[value] = true
	end
	return keys
end

local function keys_to_array(tbl)
	local keys = {}
	for key in pairs(tbl) do
		table.insert(keys, key)
	end
	return keys
end

local function pure_array(tbl)
	local length = #tbl
	for key, value in pairs(tbl) do
		if type(key) ~= "number" or key ~= bit.bor(key, 0) or key < 1 or key > length then
			return false, key
		end
	end
	return true
end

local function deep_clone_impl(track, thing)
	if type(thing) == "table" then
		if not track[thing] then
			local clone = {}
			track[thing] = clone
			for key, value in pairs(thing) do
				clone[key] = deep_clone_impl(track, value)
			end
		end
		return track[thing]
	end
	return thing
end

local function deep_clone(thing)
	return deep_clone_impl({}, thing)
end

local function foreach_clean(tbl, func)
	while true do
		local key, value = next(tbl)
		if not key then
			break
		end
		func(key, value)
	end
end

return {
	version_less  = version_less,
	version_equal = version_equal,
	ends_with     = ends_with,
	read_file     = read_file,
	write_file    = write_file,
	join_paths    = join_paths,
	clone_table   = clone_table,
	array_to_keys = array_to_keys,
	keys_to_array = keys_to_array,
	pure_array    = pure_array,
	deep_clone    = deep_clone,
	foreach_clean = foreach_clean,
	packn         = environment.packn,
	unpackn       = environment.unpackn,
}
