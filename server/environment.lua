local ignore_g_write = {
	socket = true,
	lpeg = true,
}
setmetatable(_G, { __newindex = function(tbl, key, value)
	if not ignore_g_write[key] then
		error("attempt to set _G." .. key)
	end
	rawset(tbl, key, value)
end, __index = function(tbl, key)
	error("attempt to get _G." .. key)
end })

local encoding = require("lapis.util.encoding")

function encoding.encode_with_secret(thing)
	error("why are you using these D:")
end

function encoding.decode_with_secret(token)
	error("why are you using these D:")
end
