local config = require("lapis.config")

config({ "development", "production", "test" }, {
	port = 3001,
	num_workers = 4,
	postgres = { -- see docker-compose.yml
		host = "database",
		port = 5432,
		database = "tpt_scripts",
		user = "tpt_scripts",
		password = "bagels",
	},
	powder_auth = {
		api_scheme = "https",
		api_host = "powdertoy.co.uk",
		api_path = "/ExternalAuth.api",
		audience = "Script Manager Testing",
		token_max_age = 600,
	},
	staff = {
		[ 58828 ] = true, -- LBPHacker
	},
	rate_limit = {
		interval = 60,
		limit = 5,
	},
	url_prefix = "",
	ca_certs = "/etc/ssl/certs/ca-certificates.crt",
	resolver = "127.0.0.11", -- docker's embedded dns server
	scripts_max_body_size = 1000000, -- sane upper bound for body size
	ip_address_method = "remote_addr", -- either "remote_addr" or "x_forwarded_for"
})

config({ "test" }, {
})

config({ "production" }, {
	code_cache = "on",
})
