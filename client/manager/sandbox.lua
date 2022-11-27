local util        = require("manager.util")
local logger      = require("manager.logger")
local environment = require("manager.environment")
local check       = require("manager.check")
local atexit      = require("manager.atexit")

local CALLBACK_PROPERTY = {
	[ "Update"        ] = true,
	[ "Graphics"      ] = true,
	[ "Create"        ] = true,
	[ "CreateAllowed" ] = true,
	[ "ChangeType"    ] = true,
	[ "CtypeDraw"     ] = true,
}
local ELTRANSITION_TO_PROPERTY = {
	[ "presLowValue"  ] = "LowPressure",
	[ "presLowType"   ] = "LowPressureTransition",
	[ "presHighValue" ] = "HighPressure",
	[ "presHighType"  ] = "HighPressureTransition",
	[ "tempLowValue"  ] = "LowTemperature",
	[ "tempLowType"   ] = "LowTemperatureTransition",
	[ "tempHighValue" ] = "HighTemperature",
	[ "tempHighType"  ] = "HighTemperatureTransition",
}
local EL_TO_PROPERTY = {
	[ "menu"     ] = "MenuVisible",
	[ "heat"     ] = "Temperature",
	[ "hconduct" ] = "HeatConduct",
}

local sandboxes = {}
local function broadcast_element_id(identifier, id)
	for _, sandbox in pairs(sandboxes) do
		local ok, err = pcall(function()
			sandbox.script_env.elements[identifier] = id
		end)
		if not ok then
			sandbox.script_log:err("failed to broadcast %s = %s: %s", identifier, tostring(id), tostring(err))
		end
	end
end

local function make_element_resource(identifier)
	return {
		identifier = identifier,
		properties = {},
	}
end
local element_resources = {}
for i = 1, sim.PT_NUM - 1 do
	if elem.exists(i) then
		element_resources[i] = make_element_resource(elem.property(i, "Identifier"))
		element_resources[i].default = true
		element_resources[i].el_name = elem.property(i, "Name"):lower()
	end
end

local event_handler_wrappers = {}
local native_event_types = {}

local function factory(script_name)
	return function(chunks_with_deps)
		local sandbox_atexit = atexit.make_atexit()
		assert(not sandboxes[script_name])
		local sandbox_info = {}
		sandboxes[script_name] = sandbox_info
		sandbox_atexit:atexit(function()
			sandboxes[script_name] = nil
		end)
		local script_log = logger.make_logger(script_name)

		local function copy_simple_values(dest, src)
			for key, value in pairs(src) do
				if type(key) == "boolean" or
				   type(key) == "number" or
				   type(key) == "string" then
					dest[key] = value
				end
			end
		end

		local script_env = {}
		sandbox_info.script_env = script_env

		for _, name in ipairs({
			"assert",
			"tostring",
			"tonumber",
			"rawget",
			"ipairs",
			"pcall",
			"rawset",
			"rawequal",
			"_VERSION",
			"next",
			"xpcall",
			"setmetatable",
			"pairs",
			"getmetatable",
			"type",
			"error",
			"newproxy",
			"select",
			"unpack",
			"string",
			"coroutine",
			"bz2",
			"graphics",
			"table",
			"math",
			"bit",
		}) do
			script_env[name] = util.deep_clone(environment.top_level[name])
		end

		script_env._G = script_env
		local mod_require, mod_package = environment.make_require(function(path)
			return chunks_with_deps[path]
		end, script_env)
		script_env.require = mod_require
		script_env.package = mod_package

		script_env.tpt = {
			-- TODO-priv_tpt: menu_enabled
			-- TODO-priv_tpt: set_clipboard
			-- TODO-priv_tpt: setwindowsize
			-- TODO-priv_tpt: num_menus
			-- TODO-priv_tpt: active_menu
			-- TODO-priv_tpt: get_clipboard
			-- TODO-priv_tpt: record
			-- TODO-priv_tpt: screenshot
			-- TODO-priv_tpt: set_pause
			-- TODO-priv_tpt: toggle_pause
			-- TODO-priv_tpt: beginGetScript
			-- TODO-priv_tpt: setfpscap
			-- TODO-priv_tpt: get_name
		}
		for _, name in ipairs({
			"drawpixel",
			"reset_velocity",
			"get_elecmap",
			"set_elecmap",
			"set_pressure",
			"get_property",
			"set_property",
			"hud",
			"textwidth",
			"log",
			"element",
			"display_mode",
			"setdrawcap",
			"fillrect",
			"perfectCircleBrush",
			"getPartIndex",
			"reset_spark",
			"drawline",
			"decorations_enable",
			"create",
			"delete",
			"setfire",
			"drawrect",
			"set_gravity",
			"get_numOfParts",
			"version",
			"next_getPartIndex",
			"set_wallmap",
			"set_console",
			"setdebug",
			"get_wallmap",
			"newtonian_gravity",
			"start_getPartIndex",
			"ambient_heat",
			"reset_gravity_field",
			"heat",
			"drawtext",
			"watertest",
		}) do
			script_env.tpt[name] = util.deep_clone(tpt[name])
		end

		local parts_mt = { __index = function(tbl, key)
			return script_env.sim.partProperty(tbl[1], key)
		end, __newindex = function(tbl, key, value)
			script_env.sim.partProperty(tbl[1], key, value)
		end }
		script_env.tpt.parts = setmetatable({}, { __index = function(_, key)
			return setmetatable({ key }, parts_mt)
		end })

		local el_mt = { __index = function(tbl, key)
			return script_env.elem.property(tbl.id, EL_TO_PROPERTY[key] or key:lower())
		end, __newindex = function(tbl, key, value)
			script_env.elem.property(tbl.id, EL_TO_PROPERTY[key] or key:lower(), value)
		end }
		script_env.tpt.el = {}

		local eltransition_mt = { __index = function(tbl, key)
			return script_env.elem.property(tbl.id, ELTRANSITION_TO_PROPERTY[key] or "invalid")
		end, __newindex = function(tbl, key, value)
			script_env.elem.property(tbl.id, ELTRANSITION_TO_PROPERTY[key] or "invalid", value)
		end }
		script_env.tpt.eltransition = {}

		for i, resource in pairs(element_resources) do
			if resource.default then
				script_env.tpt.el[resource.el_name] = setmetatable({ id = i }, el_mt)
				script_env.tpt.eltransition[resource.el_name] = setmetatable({ id = i }, eltransition_mt)
			end
		end

		script_env.http = {
			getAuthToken = http.getAuthToken,
			-- TODO-priv_http: post
			-- TODO-priv_http: get
		}

		script_env.io = {
			-- TODO-priv_fs: input
			-- TODO-priv_fs: stdin
			-- TODO-priv_fs: tmpfile
			-- TODO-priv_fs: read
			-- TODO-priv_fs: output
			-- TODO-priv_fs: open
			-- TODO-priv_fs: close
			-- TODO-priv_fs: write
			-- TODO-priv_fs: flush
			-- TODO-priv_fs: type
			-- TODO-priv_fs: lines
			-- TODO-priv_fs: stdout
			-- TODO-priv_fs: stderr
		}

		script_env.fileSystem = {
			-- TODO-priv_fs: exists,
			-- TODO-priv_fs: list,
			-- TODO-priv_fs: removeDirectory,
			-- TODO-priv_fs: isFile,
			-- TODO-priv_fs: removeFile,
			-- TODO-priv_fs: move,
			-- TODO-priv_fs: copy,
			-- TODO-priv_fs: makeDirectory,
			-- TODO-priv_fs: isDirectory,
			-- TODO-priv_fs: isLink,
		}

		script_env.platform = {
			ident       = plat.ident,
			releaseType = plat.releaseType,
			platform    = plat.platform,
			-- TODO-priv_platform: exeName,
			-- TODO-priv_platform: clipboardPaste,
			-- TODO-priv_platform: clipboardCopy,
			-- TODO-priv_platform: openLink,
			-- TODO-priv_platform: restart,
		}

		script_env.os = {
			difftime = os.difftime,
			date     = os.date,
			time     = os.time,
			clock    = os.clock,
			-- TODO-priv_fs: rename
			-- TODO-priv_fs: remove
			-- TODO-priv_fs: tmpname
		}

		script_env.elements = {}
		copy_simple_values(script_env.elements, elem)

		function script_env.elements.allocate(group, name)
			check.is_string(group, "group", 2)
			check.is_string(name , "name" , 2)
			name = name:upper()
			group = group:upper()
			if name:find("_") then
				error("name may not contain _", 2)
			end
			if group:find("_") then
				error("group may not contain _", 2)
			end
			if group == "DEFAULT" then
				error("cannot allocate elements in group DEFAULT", 2)
			end
			local identifier = ("%s_PT_%s"):format(group, name)
			if elem[identifier] then
				error("identifier already in use", 2)
			end
			local id = elem.allocate(group, name)
			if id ~= -1 then
				broadcast_element_id(identifier, id)
				element_resources[id] = make_element_resource(identifier)
				element_resources[id].atexit_entry = sandbox_atexit:atexit(function(log, requester_name)
					if requester_name ~= script_name then
						sandboxes[requester_name].script_log:wrn("freeing %s of %s; this may cause issues later", identifier, script_name)
					end
					elem.free(id)
					element_resources[id] = nil
					broadcast_element_id(identifier, nil)
				end)
				element_resources[id].script_name = script_name
			end
			return id
		end

		function script_env.elements.free(id)
			if not element_resources[id] then
				error("invalid element", 2)
			end
			if element_resources[id].default then
				error("cannot free elements in group DEFAULT", 2)
			end
			element_resources[id].atexit_entry:exit_now(script_log, script_name)
		end

		function script_env.elements.loadDefault(id)
			local function reset(id)
				if element_resources[id].default then
					util.foreach_clean(element_resources[id].properties, function(_, resource)
						resource.atexit_entry:exit_now()
					end)
				else
					script_env.elements.free(id)
				end
			end
			if id then
				if not element_resources[id] then
					error("invalid element", 2)
				end
				reset(id)
			else
				for i = 0, sim.PT_NUM - 1 do
					reset(i)
				end
			end
		end

		function script_env.elements.element(id, tbl)
			if not element_resources[id] then
				error("invalid element", 2)
			end
			if tbl then
				for property, value in pairs(tbl) do
					if property ~= "Identifier" then
						script_env.elements.property(id, property, value)
					end
				end
				return
			end
			return elem.element(id)
		end

		local function property_mux(id, property, ...)
			local can_move_into_id = property ~= "Properties" and type(property) == "string" and property:match("^_CanMove_(%d+)$")
			if can_move_into_id then
				return sim.can_move(id, tonumber(can_move_into_id), ...)
			end
			return elem.property(id, property, ...)
		end

		local function property_common(id, property, value, mode)
			local function register_property(reset_to)
				if element_resources[id].properties[property] then
					local other_script_name = element_resources[id].properties[property].script_name
					if script_name ~= other_script_name then
						script_log:wrn("overwriting %s of %s set by %s; this may cause issues later", property, element_resources[id].identifier, other_script_name)
					end
				else
					local resource = {
						script_name = script_name,
					}
					element_resources[id].properties[property] = resource
					if element_resources[id].default then
						resource.atexit_entry = sandbox_atexit:atexit(function()
							property_mux(id, property, reset_to)
							element_resources[id].properties[property] = nil
						end)
					end
				end
			end
			if CALLBACK_PROPERTY[property] then
				property_mux(id, property, value, mode)
				register_property(false)
				return
			end
			local initial_value = property_mux(id, property)
			if value == nil then
				return initial_value
			end
			property_mux(id, property, value)
			register_property(initial_value)
		end

		function script_env.elements.property(id, property, ...)
			if select("#", ...) == 0 then
				return elem.property(id, property)
			end
			if type(property) == "string" and property:sub(1, 1) == "_" then
				error("invalid element property", 2)
			end
			return property_common(id, property, ...)
		end

		function script_env.elements.exists(id)
			return element_resources[id] and true or false
		end

		for id, info in pairs(element_resources) do
			script_env.elements[info.identifier] = id
		end

		-- TODO: Slider
		-- TODO: Textbox
		-- TODO: ProgressBar
		-- TODO: Checkbox
		-- TODO: Window
		-- TODO: Button
		-- TODO: Label
		script_env.interface = {
			-- TODO: grabTextInput
			-- TODO: addComponent
			-- TODO: beginInput
			-- TODO: beginThrowError
			-- TODO: dropTextInput
			-- TODO: textInputRect
			-- TODO: beginMessageBox
			-- TODO: removeComponent
			-- TODO: showWindow
			-- TODO: closeWindow
			-- TODO: beginConfirm
		}
		copy_simple_values(script_env.interface, ui)

		script_env.event = {
			getmodifiers = evt.getmodifiers,
		}
		copy_simple_values(script_env.event, evt)

		local function register_common(etype, func, register_once, reg_func, unreg_func)
			if type(func) ~= "function" then
				error("invalid event handler", 3)
			end
			local registry = event_handler_wrappers[etype]
			if not registry[func] then
				local wrapper = function(...)
					return func(...)
				end
				registry[func] = {
					wrapper        = wrapper,
					atexit_entries = {},
				}
				-- TODO: coroutine-based handlers for ui events
			end
			if not (register_once and next(registry[func].atexit_entries)) then
				reg_func(registry[func].wrapper)
				local atexit_entry
				atexit_entry = sandbox_atexit:atexit(function()
					unreg_func(registry[func].wrapper)
					registry[func].atexit_entries[atexit_entry] = nil
					if not next(registry[func].atexit_entries) then
						registry[func] = nil
					end
				end)
				registry[func].atexit_entries[atexit_entry] = true
			end
			return func
		end

		local function unregister_common(etype, func)
			if type(func) ~= "function" then
				error("invalid event handler", 3)
			end
			local registry = event_handler_wrappers[etype]
			if registry[func] then
				local atexit_entry = next(registry[func].atexit_entries)
				if atexit_entry then
					atexit_entry:exit_now()
				end
			end
		end

		function script_env.event.register(etype, func)
			if not native_event_types[etype] then
				error("invalid event type", 2)
			end
			return register_common(etype, func, false, function(wrapper)
				evt.register(etype, wrapper)
			end, function(wrapper)
				evt.unregister(etype, wrapper)
			end)
		end

		function script_env.event.unregister(etype, func)
			if not native_event_types[etype] then
				error("invalid event type", 2)
			end
			unregister_common(etype, func)
		end

		local function register_once_compat_event(name)
			local etype = "register_once_compat_" .. name
			event_handler_wrappers[etype] = {}
			script_env.tpt["register_" .. name] = function(func)
				register_common(etype, func, true, tpt["register_" .. name], tpt["unregister_" .. name])
			end
			script_env.tpt["unregister_" .. name] = function(func)
				unregister_common(etype, func)
			end
		end
		register_once_compat_event("mouseclick")
		register_once_compat_event("keypress")

		for key, value in pairs(evt) do
			if type(value) == "number" then -- TODO: not ideal, event constants should be possible to discern by key
				event_handler_wrappers[value] = {}
				native_event_types[value] = true
			end
		end

		function script_env.tpt.register_step(func)
			script_env.evt.register(script_env.evt.tick, func)
		end

		function script_env.tpt.unregister_step(func)
			script_env.evt.unregister(script_env.evt.tick, func)
		end

		script_env.tpt.register_keyevent     = script_env.tpt.register_keypress
		script_env.tpt.unregister_keyevent   = script_env.tpt.unregister_keypress
		script_env.tpt.register_mouseevent   = script_env.tpt.register_mouseclick
		script_env.tpt.unregister_mouseevent = script_env.tpt.unregister_mouseclick

		function script_env.tpt.element_func(func, id, mode)
			script_env.elem.property(id, "Update", func or false, mode)
		end

		function script_env.tpt.graphics_func(func, id)
			script_env.elem.property(id, "Graphics", func or false)
		end

		script_env.simulation = {
			-- TODO-sim: gspeed
			-- TODO-sim: updateUpTo
			-- TODO-sim: temperatureScale
			-- TODO-sim: deleteStamp
			-- TODO-sim: listCustomGol
			-- TODO-sim: saveStamp
			-- TODO-sim: reloadSave
			-- TODO-sim: loadSave
			-- TODO-sim: removeCustomGol
			-- TODO-sim: replaceModeFlags
			-- TODO-sim: addCustomGol
			-- TODO-sim: framerender
			-- TODO-sim: getSaveID
			-- TODO-sim: loadStamp
			-- TODO-sim: takeSnapshot
			-- TODO-sim: historyRestore
			-- TODO-sim: historyForward
			-- TODO-sim: signs
		}
		for _, name in ipairs({
			"waterEqualisation",
			"decoBrush",
			"airMode",
			"resetPressure",
			"neighbors",
			"toolBox",
			"partExists",
			"ensureDeterminism",
			"decoColor",
			"toolLine",
			"adjustCoords",
			"partChangeType",
			"partKill",
			"prettyPowders",
			"photons",
			"decoLine",
			"decoBox",
			"partProperty",
			"createBox",
			"createParts",
			"partID",
			"createWalls",
			"partPosition",
			"ambientHeat",
			"pmap",
			"gravMap",
			"elementCount",
			"clearSim",
			"createLine",
			"resetTemp",
			"partNeighbours",
			"edgeMode",
			"floodDeco",
			"createWallBox",
			"gravityMode",
			"floodParts",
			"decoColour",
			"velocityX",
			"floodWalls",
			"toolBrush",
			"gravityGrid",
			"waterEqualization",
			"clearRect",
			"hash",
			"neighbours",
			"pressure",
			"partNeighbors",
			"lastUpdatedID",
			"createWallLine",
			"randomseed",
			"brush",
			"partCreate",
			"ambientAirTemp",
			"customGravity",
			"velocityY",
			"parts",
		}) do
			script_env.simulation[name] = sim[name]
		end
		copy_simple_values(script_env.simulation, sim)

		function script_env.simulation.can_move(moving_id, into_id, value)
			return property_common(moving_id, "_CanMove_" .. into_id, value)
		end

		script_env.renderer = {
			-- TODO-ren: zoomScope
			-- TODO-ren: renderModes
			-- TODO-ren: zoomEnabled
			-- TODO-ren: zoomWindow
			-- TODO-ren: depth3d
			-- TODO-ren: colourMode
			-- TODO-ren: colorMode
			-- TODO-ren: decorations
			-- TODO-ren: displayModes
			-- TODO-ren: showBrush
			-- TODO-ren: debugHUD
			-- TODO-ren: grid
		}
		copy_simple_values(script_env.renderer, ren)

		for short, name in pairs({
			gfx  = "graphics",
			elem = "elements",
			evt  = "event",
			plat = "platform",
			fs   = "fileSystem",
			ren  = "renderer",
			sim  = "simulation",
			ui   = "interface",
		}) do
			script_env[short] = script_env[name]
		end

		sandbox_info.script_log = script_log
		function script_env.print(...)
			local strs = {}
			local args = util.packn(...)
			for i = 1, args[0] do
				table.insert(strs, tostring(args[i]))
			end
			script_log:inf(table.concat(strs, "\t"))
		end

		function script_env.load(str, src, mode, env)
			return load(str, src, mode, env or script_env)
		end

		return {
			entrypoint = function()
				mod_require(script_name)
			end,
			exit = function(log)
				sandbox_atexit:exit(log, script_name)
			end,
		}
	end
end

return {
	factory = factory,
}
