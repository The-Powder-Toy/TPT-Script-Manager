local atexit_i = {}
local atexit_m = { __index = atexit_i }

local atexit_entry_i = {}
local atexit_entry_m = { __index = atexit_entry_i }

function atexit_entry_i:exit_now(...)
	self:unlink()
	self.func_(...)
end

function atexit_entry_i:unlink()
	setmetatable(self, nil)
	self.next_.prev_ = self.prev_
	self.prev_.next_ = self.next_
end

function atexit_i:atexit(func)
	local first = self.anchor_.next_
	local entry = setmetatable({
		func_ = func,
		prev_ = self.anchor_,
		next_ = first,
	}, atexit_entry_m)
	self.anchor_.next_ = entry
	first.prev_ = entry
	return entry
end

function atexit_i:exit(...)
	setmetatable(self, nil)
	while self.anchor_.next_ ~= self.anchor_ do
		self.anchor_.next_:exit_now(...)
	end
end

local function make_atexit()
	local atexit = setmetatable({
		anchor_ = {},
	}, atexit_m)
	atexit.anchor_.next_ = atexit.anchor_
	atexit.anchor_.prev_ = atexit.anchor_
	return atexit
end

return {
	make_atexit = make_atexit,
}
