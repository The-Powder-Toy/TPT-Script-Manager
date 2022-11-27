local function is_string(thing, what, level)
	level = level + 1
	if type(thing) ~= "string" then
		error(what .. " is not a string", level)
	end
end

return {
	is_string = is_string,
}
