local db       = require("lapis.db")
local lunajson = require("lunajson")
local lock     = require("resty.lock")
local socket   = require("socket")

local function write_file(path, data)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(data))
	assert(handle:close())
end

local function emit_manifest(before_func, after_func)
	local manifest = {}
	for _, row in ipairs(db.query([[
		select * from manifest;
	]])) do
		table.insert(manifest, {
			Tag           = row.tag,
			Blob          = row.blob,
			CreatedAt     = math.floor(row.created_at),
			UpdatedAt     = math.floor(row.updated_at),
			Module        = row.module,
			Title         = row.title,
			Description   = row.description,
			Dependencies  = row.dependencies,
			Listed        = row.listed,
			Version       = row.version,
			StaffApproved = row.staff_approved,
			Author        = row.author,
			AuthorID      = row.author_id,
		})
	end
	manifest[0] = #manifest
	local manifest_data = lunajson.encode(manifest)
	if before_func then
		before_func()
	end
	write_file("data/manifest.json.new", manifest_data)
	assert(os.rename("data/manifest.json.new", "data/manifest.json"))
	if after_func then
		after_func()
	end
end

local function init_manifest()
	-- Get out of the init_worker_by_lua context and into one where we can interact with the db
	ngx.timer.at(0, function()
		local data_lock = assert(lock:new("tpt_scripts_locks"))
		assert(data_lock:lock("data_lock"))
		local ok, err
		while true do
			ok, err = pcall(function()
				emit_manifest()
			end)
			if ok then
				break
			end
			ngx.log(ngx.ERR, "failed to initialize manifest: " .. tostring(err))
			ngx.log(ngx.INFO, "retrying in a second")
			ngx.sleep(1)
		end
		assert(data_lock:unlock())
		assert(ok, err)
	end)
end

local function now()
	return socket.gettime()
end

return {
	init_manifest = init_manifest,
	emit_manifest = emit_manifest,
	write_file = write_file,
	now = now,
}
