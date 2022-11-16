local config     = require("lapis.config").get()
local lunajson   = require("lunajson")
local lapis_util = require("lapis.util")
local encoding   = require("lapis.util.encoding")
local basexx     = require("basexx")
local http       = require("lapis.nginx.http")
local util       = require("util")

local function token_payload(token)
	local payload = token:match("^[^%.]+%.([^%.]+)%.[^%.]+$")
	if not payload then
		return nil, "no payload"
	end
	local unb64 = basexx.from_url64(payload)
	if not unb64 then
		return nil, "bad base64"
	end
	local ok, json = pcall(lunajson.decode, unb64)
	if not ok then
		return nil, "bad json: " .. json
	end
	if type(json) ~= "table" then
		return nil, "bad payload"
	end
	if type(json.sub) ~= "string" or json.sub:find("[^0-9]") then
		return nil, "bad subject"
	end
	if json.aud ~= config.powder_auth.audience then
		return nil, "bad audience"
	end
	return json
end

local function check(powder_token)
	local powder_data, err = token_payload(powder_token)
	if not powder_data then
		ngx.log(ngx.WARN, "malformed powder token: ", err)
		return nil, { status = 400, json = { Status = "BadRequest", Reason = "MalformedToken" } }
	end
	local shared = ngx.shared.tpt_scripts_auth
	if not shared:get(powder_token) then
		local body, code, headers = http.simple({
			url = lapis_util.build_url({
				scheme = config.powder_auth.api_scheme,
				host = config.powder_auth.api_host,
				path = config.powder_auth.api_path,
				query = lapis_util.encode_query_string({
					Action = "Check",
					MaxAge = config.powder_auth.token_max_age,
					Token = powder_token,
				}),
			}),
		})
		if code ~= 200 then
			ngx.log(ngx.WARN, "authentication backend failed with code ", code)
			return nil, { status = 502, json = { Status = "BadGateway", Reason = "BackendFailure" } }
		end
		local ok, json = pcall(lunajson.decode, body)
		if not ok or type(json) ~= "table" then
			ngx.log(ngx.WARN, "authentication backend returned a malformed response: ", body:sub(1, 200))
			return nil, { status = 502, json = { Status = "BadGateway", Reason = "BackendFailure" } }
		end
		if json.Status ~= "OK" then
			ngx.log(ngx.WARN, "bad token: ", json.Status)
			return nil, { status = 400, json = { Status = "BadRequest", Reason = "BadToken", BackendStatus = json.Status } }
		end
		shared:set(powder_token, true, powder_data.iat + config.powder_auth.token_max_age - util.now())
	end
	return tonumber(powder_data.sub), powder_data.name
end

return {
	check = check,
}
