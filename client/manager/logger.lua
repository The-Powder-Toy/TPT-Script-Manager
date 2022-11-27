local logger_i = {}
local logger_m = { __index = logger_i }

local function make_logger_(prefix, level)
	return setmetatable({
		prefix_ = prefix,
		level_ = level,
	}, logger_m)
end

local function make_logger(prefix)
	return make_logger_(prefix, 0)
end

function logger_i:log(severity, ...)
	print(("[%s:%s] %s%s"):format(self.prefix_, severity, ("  "):rep(self.level_), string.format(...))) -- TODO: something better
end

function logger_i:sub(...)
	self:inf(...)
	return make_logger_(self.prefix_, self.level_ + 1)
end

local function register_severity(severity)
	logger_i[severity] = function(self, ...)
		self:log(severity, ...)
	end
end
register_severity("inf")
register_severity("wrn")
register_severity("err")

return {
	make_logger = make_logger,
}
