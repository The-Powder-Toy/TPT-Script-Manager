local util        = require("manager.util")
local environment = require("manager.environment")

local function serialize_one(parts, thing, pretty, what, level)
	level = level + 1
	if what == "keys" then
		table.insert(parts, pretty and "[ " or "[")
	end
	local skip_key_rsquare = false
	if type(thing) == "number" then
		if math.abs(thing) == math.huge or thing ~= thing --[[ nan ]] then
			return nil, "cannot serialize infinity or nan " .. what
		end
		if what == "keys" and math.floor(thing) ~= thing then
			return nil, "cannot serialize non-integer " .. what
		end
		table.insert(parts, thing) -- table.concat stringifies numbers
	elseif type(thing) == "boolean" then
		table.insert(parts, thing and "true" or "false")
	elseif type(thing) == "string" then
		if #thing < 100 then
			if what == "keys" and thing:find("^[_A-Za-z][_A-Za-z0-9]*$") then
				parts[#parts] = thing
				skip_key_rsquare = true
			else
				table.insert(parts, ("%q"):format(thing))
			end
		else
			local eqn = 0
			local cursor = 1
			while true do
				local first, last = thing:find("]=*]", cursor)
				if not first then
					break
				end
				eqn = math.max(eqn, last - first - 1)
				cursor = last + 1
			end
			local eqs = ("="):rep(eqn)
			table.insert(parts, "[")
			table.insert(parts, eqs)
			table.insert(parts, "[\n")
			table.insert(parts, thing)
			table.insert(parts, "]")
			table.insert(parts, eqs)
			table.insert(parts, "]")
		end
	else
		return nil, "cannot serialize " .. what .. " of type " .. type(thing)
	end
	if what == "keys" and not skip_key_rsquare then
		table.insert(parts, pretty and " ]" or "]")
	end
	return true
end

local function serialize_impl(track, parts, thing, pretty, level)
	level = level + 1
	if type(thing) == "table" then
		if track[thing] then
			return nil, "cannot serialize recursive structures"
		end
		track[thing] = true
		if getmetatable(thing) then
			return nil, "cannot serialize metatables"
		end
		table.insert(parts, pretty and "{\n" or "{")
		for key, value in pairs(thing) do
			if pretty then
				table.insert(parts, ("\t"):rep(level - 2))
			end
			local ok, err = serialize_one(parts, key, pretty, "keys", level)
			if not ok then
				return nil, err
			end
			table.insert(parts, pretty and " = " or "=")
			local ok, err = serialize_impl(track, parts, value, pretty, level)
			if not ok then
				return nil, err
			end
			table.insert(parts, ",")
			if pretty then
				table.insert(parts, "\n")
			end
		end
		if pretty and next(thing) then
			table.insert(parts, ("\t"):rep(level - 3))
		end
		table.insert(parts, "}")
	else
		return serialize_one(parts, thing, pretty, "values", level)
	end
	return true
end

local function serialize(thing, pretty)
	os.setlocale("C") -- force printing of numbers to use '.' as the decimal point
	local track = {}
	local parts = {}
	local ok, err = serialize_impl(track, parts, thing, pretty, 2)
	if not ok then
		return nil, err
	end
	table.insert(parts, "\n")
	return table.concat(parts)
end

local function deserialize(str, chunk)
	local func, err = environment.load_with_env("return (" .. str .. ")", chunk or "=[serialized data]", environment.make_strict_env({}))
	if not func then
		return nil, "malformed data: " .. err
	end
	local old_smt_index = environment.string_meta.__index
	environment.string_meta.__index = nil
	local ok, thing = pcall(func)
	environment.string_meta.__index = old_smt_index
	if not ok then
		return nil, "malformed data: " .. thing
	end
	return true, thing
end

local function read_file(path)
	local data, err = util.read_file(path)
	if not data then
		return nil, err
	end
	return deserialize(data)
end

local function write_file(path, thing, pretty)
	local data, err = serialize(thing, pretty)
	if not data then
		return nil, err
	end
	return util.write_file(path, data)
end

return {
	serialize   = serialize,
	deserialize = deserialize,
	read_file   = read_file,
	write_file  = write_file,
}
