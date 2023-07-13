local lapis       = require("lapis")
local application = require("lapis.application")
local db          = require("lapis.db")
local config      = require("lapis.config").get()
local auth        = require("auth")
local lock        = require("resty.lock")
local util        = require("util")
local date        = require("date")

local app = lapis.Application()

local function data_lock_acquire(self)
	self.data_lock = assert(lock:new("tpt_scripts_locks"))
	assert(self.data_lock:lock("data_lock"))
end

local function data_lock_cleanup(self)
	if self.data_lock then
		assert(self.data_lock:unlock())
		self.data_lock = nil
	end
end

local function record_failure(self, result)
	ngx.log(ngx.WARN, ("[record_failure from %s]"):format(self.peer.ip_address))
	data_lock_cleanup(self)
	return result
end

local function get_peer_address(self)
	if config.ip_address_method == "remote_addr" then
		self.peer.ip_address = ngx.var.remote_addr
	elseif config.ip_address_method == "x_forwarded_for" then
		self.peer.ip_address = assert(self.req.headers["X-Forwarded-For"])
	else
		error("sanity check failure")
	end
end

local function get_peer_user(self)
	if not self.req.headers["X-ExternalAuth"] then
		return nil, { status = 400, json = { Status = "BadRequest", Reason = "NoXExternalAuth" } }
	end
	local powder_id, powder_name_or_err = auth.check(self.req.headers["X-ExternalAuth"])
	if not powder_id then
		return nil, powder_name_or_err
	end
	self.peer.powder_id = powder_id
	self.peer.powder_name = powder_name_or_err
	return true
end

local function enforce_rate_limit(self)
	self.peer.user_id = db.query([[
		select lazy_register_user(?, ?) as user_id;
	]], self.peer.powder_id, self.peer.powder_name)[1].user_id
	local shared = ngx.shared.tpt_scripts_rate_limit
	local count = shared:get(self.peer.user_id) or 0
	local rate_limited = count == config.rate_limit.limit
	if not rate_limited then
		count = count + 1
	end
	local now = util.now()
	local reference = math.floor(now / config.rate_limit.interval) * config.rate_limit.interval
	local reset_in = reference + config.rate_limit.interval - now
	self.res.headers["X-RateLimit-Bucket"] = "per-user"
	self.res.headers["X-RateLimit-Limit"] = tostring(config.rate_limit.limit)
	self.res.headers["X-RateLimit-Interval"] = tostring(config.rate_limit.interval)
	self.res.headers["X-RateLimit-Remaining"] = tostring(config.rate_limit.limit - count)
	self.res.headers["X-RateLimit-ResetIn"] = ("%.3f"):format(reset_in)
	if rate_limited then
		self.res.headers["Retry-After"] = ("%.3f"):format(reset_in)
		return nil, { status = 429, json = { Status = "TooManyRequests" } }
	end
	assert(shared:safe_set(self.peer.user_id, count, reset_in))
	return true
end

local function is_staff(self)
	return config.staff[self.peer.powder_id]
end

local function check_present(params)
	local present = {}
	for _, param in ipairs(params) do
		if not param.value then
			return nil, { status = 400, json = { Status = "BadRequest", Reason = "No" .. param.name } }
		end
		table.insert(present, param.value)
	end
	return present
end

local manage_script_bad_request_reasons = {
	too_many_scripts      = "TooManyScripts",
	too_much_script_data  = "TooMuchScriptData",
	module_too_long       = "ModuleLength",
	bad_module            = "ModuleFormat",
	title_too_long        = "TitleLength",
	description_too_long  = "DescriptionLength",
	dependencies_too_long = "DependenciesLength",
}
app:match("/scripts/:name", function(self)
	self.peer = {}
	get_peer_address(self)
	if self.req.method ~= "PUT" and self.req.method ~= "DELETE" then
		return record_failure(self, { status = 405, json = { Status = "InvalidMethod" } })
	end
	local ok, err = get_peer_user(self)
	if not ok then
		return record_failure(self, err)
	end
	local ok, err = enforce_rate_limit(self)
	if not ok then
		return record_failure(self, err)
	end
	local action = "delete"
	local title = db.NULL
	local description = db.NULL
	local dependencies = db.NULL
	local data = db.NULL
	if self.req.method == "PUT" then
		action = "upsert"
		local present, err = check_present({
			{ value = self.params.Title       , name = "Title"        },
			{ value = self.params.Description , name = "Description"  },
			{ value = self.params.Dependencies, name = "Dependencies" },
			{ value = self.params.Data        , name = "Data"         },
		})
		if not present then
			return record_failure(self, err)
		end
		title, description, dependencies, data = unpack(present)
	end
	local bypass_owner_check = is_staff(self) and self.req.headers["X-BypassOwnerCheck"] or false
	data_lock_acquire(self)
	local result = db.query([[
		select status, new_blob, old_blob
			from manage_script(?, ?, ?, ?, ?, ?, ?, ?);
	]], action, self.peer.user_id, self.params.name, title, description, dependencies, data, bypass_owner_check)[1]
	if manage_script_bad_request_reasons[result.status] then
		return record_failure(self, { status = 400, json = { Status = "BadRequest", Reason = manage_script_bad_request_reasons[result.status] } })
	elseif result.status == "user_locked" then
		return record_failure(self, { status = 403, json = { Status = "Forbidden", Reason = "UserLocked" } })
	elseif result.status == "no_access" then
		return record_failure(self, { status = 403, json = { Status = "Forbidden", Reason = "NoAccess" } })
	elseif result.status == "no_user" then
		-- Whatever. This happens when the relevant user record is removed
		-- after enforce_rate_limit but before the manage_script query.
		self.res.headers["Retry-After"] = tostring(1)
		return record_failure(self, { status = 409, json = { Status = "Conflict", Reason = "NoUser" } })
	else
		assert(result.status == "ok", "sanity check failure")
	end
	local action_taken = "Updated"
	if not result.new_blob then
		action_taken = "Deleted"
	end
	if not result.old_blob then
		action_taken = "Created"
	end
	util.emit_manifest(function()
		if result.new_blob then
			util.write_file("data/" .. result.new_blob, data)
		end
	end, function()
		if result.old_blob then
			os.remove("data/" .. result.old_blob)
		end
	end)
	data_lock_cleanup(self)
	return { status = 200, json = { Status = "OK", ActionTaken = action_taken } }
end)

local function staff_endpoint(self)
	self.peer = {}
	local ok, err = get_peer_address(self)
	if not ok then
		return nil, err
	end
	local ok, err = get_peer_user(self)
	if not ok then
		return nil, err
	end
	if not is_staff(self) then
		return nil, { status = 403, json = { Status = "Forbidden", Reason = "NotStaff" } }
	end
	return true
end

local function parse_integer(str, min, max, name)
	local value = tonumber(str)
	if not value then
		return nil, { status = 400, json = { Status = "BadRequest", Reason = "No" .. name } }
	end
	if math.floor(value) ~= value or value < 0 or value > 10000000 then
		return nil, { status = 400, json = { Status = "BadRequest", Reason = "Bad" .. name } }
	end
	return value
end

local function script_property(property)
	return function(self)
		local ok, err = staff_endpoint(self)
		if not ok then
			return record_failure(self, err)
		end
		if self.req.method ~= "PUT" then
			return { status = 405, json = { Status = "InvalidMethod" } }
		end
		if property == "staff_approved" then
			local present, err = check_present({
				{ value = self.params.Approved, name = "Approved" },
			})
			if not present then
				return record_failure(self, err)
			end
			local approved = unpack(present) == "true"
			local version = db.NULL
			if approved then
				local err
				version, err = parse_integer(self.params.Version, 0, 10000000, "Version")
				if not version then
					return err
				end
			end
			data_lock_acquire(self)
			local result = db.query([[
				select staff_approve_script(?, ?, ?);
			]], self.params.name, version, approved)[1]
			if result == "ok" then
				util.emit_manifest()
			end
			data_lock_cleanup(self)
		end
		if result == "no_script_version" then
			return { status = 404, json = { Status = "NotFound" } }
		end
		assert(result == "ok", "sanity check failure")
		return { status = 200, json = { Status = "OK" } }
	end
end

app:match("/staff/scripts/:name/Approved", script_property("staff_approved"))

local function user_property(property)
	return function(self)
		local ok, err = staff_endpoint(self)
		if not ok then
			return record_failure(self, err)
		end
		if self.req.method ~= "PUT" then
			return { status = 405, json = { Status = "InvalidMethod" } }
		end
		local powder_id, err = parse_integer(self.params.powder_id, 1, 10000000, "PowderID")
		if not powder_id then
			return err
		end
		local result
		if property == "max_scripts" then
			local max_scripts, err = parse_integer(self.params.MaxScripts, 0, 1000, "MaxScripts")
			if not max_scripts then
				return err
			end
			result = db.query([[
				select staff_user_max_scripts(?, ?) as status;
			]], powder_id, max_scripts)[1].status
			if result == "too_many_scripts" then
				return { status = 409, { Status = "Conflict", Reason = "TooManyScripts" } }
			end
		elseif property == "max_script_bytes" then
			local max_script_bytes, err = parse_integer(self.params.MaxScriptBytes, 0, 100000000, "MaxScriptBytes")
			if not max_script_bytes then
				return err
			end
			result = db.query([[
				select staff_user_max_script_bytes(?, ?) as status;
			]], powder_id, max_script_bytes)[1].status
			if result == "too_much_script_data" then
				return { status = 409, { Status = "Conflict", Reason = "TooMuchScriptData" } }
			end
		elseif property == "locked" then
			local present, err = check_present({
				{ value = self.params.Locked, name = "Locked" },
			})
			if not present then
				return record_failure(self, err)
			end
			local locked = unpack(present) == "true"
			result = db.query([[
				select staff_user_locked(?, ?) as status;
			]], powder_id, locked)[1].status
		end
		if result == "no_user" then
			return { status = 404, json = { Status = "NotFound" } }
		end
		assert(result == "ok", "sanity check failure")
		return { status = 200, json = { Status = "OK" } }
	end
end

app:match("/staff/users/:powder_id/MaxScripts", user_property("max_scripts"))
app:match("/staff/users/:powder_id/MaxScriptBytes", user_property("max_script_bytes"))
app:match("/staff/users/:powder_id/Locked", user_property("locked"))

function app:default_route()
	self.peer = {}
	get_peer_address(self)
	return record_failure(self, { status = 404, json = { Status = "NotFound" } })
end

function app:handle_error(err, trace)
	data_lock_cleanup(self.original_request)
	ngx.log(ngx.ERR, err)
	ngx.log(ngx.ERR, trace)
	return { status = 500, json = { Status = "Error" } }
end

return app
