local MIN_SIZE_FIT_CHILDREN  = -1
local MAX_SIZE_INFINITE      = -1
local SIZE_LIMIT             = 100000
local HORIZONTAL             = 1
local VERTICAL               = 2
local BEFORE                 = 1
local AFTER                  = 2
local LEFT                   = 0
local CENTER                 = 1
local RIGHT                  = 2
local TOP                    = LEFT
local BOTTOM                 = RIGHT
local INVALID_SLOT           = -1
local NEXT_FREE_ALLOCATED    = -2
local SLOT_META_ROOT_PARENT  = -3
local SLOT_META_STYLE_SOURCE = -4
local SCROLL_SPEED           = 10
local ROOT_SLOT              = 1 -- 0 in C++
local ROOT_NAME              = "root"
local Z_INDEX_DEFAULT        = 0
local Z_INDEX_STUCK          = 100
local Z_INDEX_UNDER_MOUSE    = 1000

local lua51 = loadstring and true or false
local unpack = lua51 and unpack or table.unpack

local function sane_boolean(thing)
	return type(thing) == "boolean"
end

local function sane_number(thing)
	return type(thing) == "number" and math.abs(thing) ~= math.huge and thing == thing -- not nan
end

local function sane_integer(size)
	return sane_number(size) and math.floor(size) == size
end

local function sane_size(size)
	return sane_integer(size) and size >= 0 and size <= SIZE_LIMIT
end

local function sane_space(space)
	return sane_integer(space) and space >= -SIZE_LIMIT and space <= SIZE_LIMIT
end

local function point_in_rect(px, py, rx, ry, rw, rh)
	return px >= rx and py >= ry and px < rx + rw and py < ry + rh
end

local imgui_i = {}
local imgui_m = { __index = imgui_i }

local function control_class(name, info)
	local begin_func = info.begin_func
	local end_func = info.end_func
	imgui_i["begin_" .. name] = begin_func
	imgui_i["end_" .. name] = end_func
	imgui_i[name] = function(self, id, ...)
		begin_func(self, id, ...)
		return end_func(self, id)
	end
end

function imgui_i:alloc_slot_(id, parent_slot)
	local slot = self.first_free_
	if slot == INVALID_SLOT then
		slot = #self.controls_ + 1
	else
		self.first_free_ = self.controls_[slot].next_free
	end
	self.controls_[slot] = {
		next_free = NEXT_FREE_ALLOCATED,
		slot = slot, -- easier in C++
		id = id,
		alive = false,
		old_first_child = INVALID_SLOT,
		old_next_sibling = INVALID_SLOT,
		persistent = {
			min_scroll = 0,
			max_scroll = 0,
			scroll = 0,
		},
	}
	return slot
end

function imgui_i:free_slot_(slot)
	assert(slot >= 1 and slot <= #self.controls_ and self.controls_[slot].next_free == NEXT_FREE_ALLOCATED)
	self.controls_[slot].next_free = self.first_free_
	self.first_free_ = slot
end

function imgui_i:control_old_children_(control, func)
	local slot = control.old_first_child
	while slot ~= INVALID_SLOT do
		local child = self.controls_[slot]
		func(child)
		slot = child.old_next_sibling
	end
end

function imgui_i:control_children_(control, func)
	local slot = control.first_child
	while slot ~= INVALID_SLOT do
		local child = self.controls_[slot]
		func(child)
		slot = child.next_sibling
	end
end

local function traverse_controls(traverse_children)
	return function(self, down, up)
		local function visit(control, parent, prev_sibling)
			if down then
				down(control, parent, prev_sibling)
			end
			local prev_child
			traverse_children(self, control, function(child)
				visit(child, control, prev_child)
				prev_child = child
			end)
			if up then
				up(control, parent, prev_sibling)
			end
		end
		visit(self.controls_[ROOT_SLOT])
	end
end

local function deep_copy(source)
	local result = {}
	for key, value in pairs(source) do
		if type(value) == "table" then
			value = deep_copy(value)
		end
		result[key] = value
	end
	return result
end

imgui_i.traverse_controls_ = traverse_controls(imgui_i.control_children_)
imgui_i.traverse_old_controls_ = traverse_controls(imgui_i.control_old_children_)

function imgui_i:current_control_slot_()
	return self.context_stack_ and self.context_stack_.control_slot or INVALID_SLOT
end

function imgui_i:current_control_()
	return self.context_stack_ and self.controls_[self.context_stack_.slot] or nil
end

function imgui_i:current_control_style_source_()
	return self.context_stack_ and self.controls_[self.context_stack_.prev_style_slot] or nil
end

function imgui_i:find_control_slot_(id, hint)
	local parent_slot = self:current_control_slot_()
	if parent_slot ~= INVALID_SLOT then
		local check_first = hint
		local check_next = check_first
		while true do
			if check_next == INVALID_SLOT then
				-- wrap around to first child (or start from there if hint was INVALID_SLOT)
				check_next = self.controls_[parent_slot].old_first_child -- .first_child for user code find
			end
			if check_next ~= INVALID_SLOT then -- check_next can be INVALID_SLOT if hint was invalid and self.controls_[parent_slot] doesn't have children
				if self.controls_[check_next].id == id then
					return check_next
				end
				check_next = self.controls_[check_next].old_next_sibling -- .next_sibling for user code find
			end
			self.debug_find_control_iterations_ = self.debug_find_control_iterations_ + 1
			if check_next == check_first then
				-- back where we started, give up
				break
			end
		end
	end
	return INVALID_SLOT
end

local control_c = {}
function control_c:begin_func(id)
	assert(type(id) == "string" or sane_number(id))
	local parent_slot = self:current_control_slot_()
	local slot
	if parent_slot == INVALID_SLOT then
		slot = ROOT_SLOT
	else
		slot = self:find_control_slot_(id, self.begin_control_hint_)
		if slot == INVALID_SLOT then
			slot = self:alloc_slot_(id, parent_slot)
		end
		if not self.controls_[slot].alive then
			if self.link_as_next_sibling_to_ == INVALID_SLOT then
				self.controls_[parent_slot].first_child = slot
			else
				self.controls_[self.link_as_next_sibling_to_].next_sibling = slot
			end
		end
	end
	local control = self.controls_[slot]
	self.context_stack_ = {
		type = "control",
		slot = slot,
		control_slot = slot,
		id = control.id,
		prev = self.context_stack_,
		prev_style_slot = self.context_stack_ and self.context_stack_.slot or SLOT_META_ROOT_PARENT,
	}
	control.alive = true
	control.transient = {}
	control.transient.min_content_size = { 0, 0 }
	control.first_child = INVALID_SLOT
	control.next_sibling = INVALID_SLOT
	control.configured = deep_copy(self.controls_[SLOT_META_STYLE_SOURCE].configured)
	self.begin_control_hint_ = control.old_first_child -- just began a control, the next control to be begun will probably be its old first child
	self.find_after_end_hint_ = INVALID_SLOT
	self.link_as_next_sibling_to_ = INVALID_SLOT -- just began a control, the next control to be begun is to be linked as a first child to it, not as a next sibling
end
function control_c:end_func(id)
	assert(type(id) == "string" or sane_number(id))
	assert(self.context_stack_ and self.context_stack_.type == "control" and self.context_stack_.id == id) -- TODO: this shouldn't be a hard error
	local slot = self:current_control_slot_()
	local control = self.controls_[slot]
	self.begin_control_hint_ = control.old_next_sibling -- just ended a control, the next control to be begun will probably be its old next sibling
	self.find_after_end_hint_ = slot
	self.link_as_next_sibling_to_ = slot -- just ended a control, the next control to be begun is to be linked as a next sibling to it
	self.context_stack_ = self.context_stack_.prev
end
control_class("control", control_c)

local style_c = {}
function style_c:begin_func(id)
	assert(type(id) == "string" or sane_number(id))
	assert(self.in_frame_)
	self.context_stack_ = {
		type = "style",
		slot = SLOT_META_STYLE_SOURCE,
		control_slot = self.context_stack_ and self.context_stack_.control_slot or INVALID_SLOT,
		id = id,
		prev = self.context_stack_,
		prev_style_slot = self.context_stack_ and self.context_stack_.slot or SLOT_META_ROOT_PARENT,
		prev_style = self.controls_[SLOT_META_STYLE_SOURCE],
	}
	self.controls_[SLOT_META_STYLE_SOURCE] = {
		configured = deep_copy(self.controls_[SLOT_META_STYLE_SOURCE].configured),
	}
end
function style_c:end_func(id)
	assert(type(id) == "string" or sane_number(id))
	assert(self.context_stack_ and self.context_stack_.type == "style" and self.context_stack_.id == id) -- TODO: this shouldn't be a hard error
	self.controls_[SLOT_META_STYLE_SOURCE] = self.context_stack_.prev_style
	self.context_stack_ = self.context_stack_.prev
end
control_class("style", style_c)

local text_c = {}
function text_c:begin_func(id, text)
	assert(type(text) == "string")
	control_c.begin_func(self, id)
	local control = self:current_control_()
	control.configured.text = text
end
text_c.end_func = control_c.end_func
control_class("text", text_c)

local button_c = {}
function button_c:begin_func(id, text, stuck)
	assert(type(text) == "string")
	control_c.begin_func(self, id)
	local control = self:current_control_()
	self:stuck(stuck)
	control.configured.border = true
	control.configured.background = true
	control.configured.clickable = true
	control.configured.text = text
	control.configured.raise_under_mouse = true
end
function button_c:end_func(id)
	local control = self:current_control_()
	local result = not control.configured.disabled and self.click_on_ == control and self.click_with_ == ui.SDL_BUTTON_LEFT
	control_c.end_func(self, id)
	return result
end
control_class("button", button_c)

local dragger_c = {}
function dragger_c:begin_func(id)
	control_c.begin_func(self, id)
	local control = self:current_control_()
	control.configured.border = true
end
function dragger_c:end_func(id)
	local control = self:current_control_()
	local result
	if not control.configured.disabled and self.mouse_down_on_ == control and self.mouse_down_with_ == ui.SDL_BUTTON_LEFT then
		result = {
			diff_x = self.mouse_x_ - self.mouse_down_at_x_,
			diff_y = self.mouse_y_ - self.mouse_down_at_y_,
		}
		if not control.persistent.dragging then
			result.first = true
			control.persistent.dragging = true
		end
	else
		if control.persistent.dragging then
			result = {
				last = true,
			}
			control.persistent.dragging = nil
		end
	end
	control_c.end_func(self, id)
	return result
end
control_class("dragger", dragger_c)

local horiz_panel_c = {}
function horiz_panel_c:begin_func(id, border)
	control_c.begin_func(self, id)
	self:primary_dimension(HORIZONTAL)
	local control = self:current_control_()
	control.configured.border = border
end
horiz_panel_c.end_func = control_c.end_func
control_class("horiz_panel", horiz_panel_c)

local vert_panel_c = {}
function vert_panel_c:begin_func(id, border)
	control_c.begin_func(self, id)
	self:primary_dimension(VERTICAL)
	local control = self:current_control_()
	control.configured.border = border
end
vert_panel_c.end_func = control_c.end_func
control_class("vert_panel", vert_panel_c)

local function both_dimensions(dim)
	return dim, 3 - dim -- VERTICAL -> HORIZONTAL, HORIZONTAL -> VERTICAL
end

function imgui_i:begin_frame(root_x, root_y)
	assert(not self.in_frame_)
	self.in_frame_ = true
	self.debug_find_control_iterations_ = 0
	self.root_x_ = root_x
	self.root_y_ = root_y
	self.controls_[SLOT_META_ROOT_PARENT] = {
		configured = {
			min_size = { MIN_SIZE_FIT_CHILDREN, MIN_SIZE_FIT_CHILDREN },
			max_size = { MAX_SIZE_INFINITE, MAX_SIZE_INFINITE },
			text_nudge = { 0, 0 },
			text_alignment = { CENTER, CENTER },
			alignment = LEFT,
			content_alignment = TOP,
			primary_dimension = HORIZONTAL,
			space_before = 1,
			padding = { { 0, 0 }, { 0, 0 } }, -- primary (before, after), secondary (before, after)
			space_fill_ratio = { 1, 1 },
			z_index = Z_INDEX_DEFAULT,
			raise_under_mouse = false,
		},
	}
	self.controls_[SLOT_META_STYLE_SOURCE] = self.controls_[SLOT_META_ROOT_PARENT]
	self:begin_control(ROOT_NAME)
end

local function control_rect(control)
	return control.transient.position[HORIZONTAL],
	       control.transient.position[VERTICAL],
	       control.transient.effective_size[HORIZONTAL],
	       control.transient.effective_size[VERTICAL]
end

local function control_visible_rect(control)
	return control.transient.cvrx,
	       control.transient.cvry,
	       control.transient.cvrw,
	       control.transient.cvrh
end

local function intersect_rect(rx1, ry1, rw1, rh1, rx2, ry2, rw2, rh2)
	local tlx = math.max(rx1      , rx2      )
	local tly = math.max(ry1      , ry2      )
	local brx = math.min(rx1 + rw1, rx2 + rw2)
	local bry = math.min(ry1 + rh1, ry2 + rh2)
	return tlx, tly, math.max(brx - tlx, 0), math.max(bry - tly, 0)
end

function imgui_i:restrict_clip_rect_(x, y, w, h)
	return self:set_clip_rect_(intersect_rect(self.crx_, self.cry_, self.crw_, self.crh_, x, y, w, h))
end

function imgui_i:set_clip_rect_(x, y, w, h)
	local px, py, pw, ph = self.crx_, self.cry_, self.crw_, self.crh_
	if x then
		self.crx_, self.cry_, self.crw_, self.crh_ = x, y, w, h
		gfx.setClipRect(intersect_rect(self.ocrx_, self.ocry_, self.ocrw_, self.ocrh_, x, y, w, h))
	end
	return px, py, pw, ph
end

local colours = {
	inactive = {
		background = {   0,   0,   0 },
		text       = { 255, 255, 255 },
		border     = { 200, 200, 200 },
	},
	hover = {
		background = {  20,  20,  20 },
		text       = { 255, 255, 255 },
		border     = { 255, 255, 255 },
	},
	active = {
		background = { 255, 255, 255 },
		text       = {   0,   0,   0 },
		border     = { 235, 235, 235 },
	},
	disabled = {
		background = {  10,  10,  10 },
		text       = { 100, 100, 100 },
		border     = { 100, 100, 100 },
	},
}
function imgui_i:draw_control_(control)
	local x, y, w, h = control_rect(control)
	local state = "inactive"
	if control.configured.clickable then
		if self.under_mouse_ == control then
			if self.mouse_down_on_ == control and self.mouse_down_with_ == ui.SDL_BUTTON_LEFT then
				state = "active"
			else
				state = "hover"
			end
		end
	end
	if control.configured.stuck then
		state = "active"
	end
	if control.configured.disabled then
		state = "disabled"
	end
	local state_colours = colours[state]
	if control.configured.background then
		gfx.fillRect(x, y, w, h, unpack(state_colours.background))
	end
	local text = control.configured.text
	if text then
		local tw, th = gfx.textSize(text)
		local crx, cry, crw, crh = self:restrict_clip_rect_(x + 1, y + 1, w - 2, h - 2)
		local hb = control.configured.padding[HORIZONTAL][BEFORE]
		local ha = control.configured.padding[HORIZONTAL][AFTER]
		local vb = control.configured.padding[VERTICAL][BEFORE]
		local va = control.configured.padding[VERTICAL][AFTER]
		local tx = x + hb + math.ceil((w - tw - hb - ha) * control.configured.text_alignment[HORIZONTAL] / 2) + control.configured.text_nudge[HORIZONTAL]
		local ty = y + vb + math.ceil((h - th - vb - va) * control.configured.text_alignment[VERTICAL  ] / 2) + control.configured.text_nudge[VERTICAL  ] + 1
		gfx.drawText(tx, ty, text, unpack(state_colours.text))
		self:set_clip_rect_(crx, cry, crw, crh)
	end
	if control.configured.border then
		gfx.drawRect(x, y, w, h, unpack(state_colours.border))
	end
	if control.configured.grooves then
		for i = 1, 3 do
			gfx.drawLine(x + i * 3 + 1, y + 3, x + 3, y + i * 3 + 1, unpack(state_colours.border))
		end
	end
end

function imgui_i:end_frame()
	assert(self.in_frame_)
	self:end_control(ROOT_NAME)
	assert(not self.context_stack_) -- TODO: this shouldn't be a hard error
	self:traverse_controls_(nil, function(control, parent, prev_sibling)
		local dim_1, dim_2 = both_dimensions(control.configured.primary_dimension)
		local min_size = control.configured.min_size
		local max_size = control.configured.max_size
		local min_content_size = control.transient.min_content_size -- children will have stretched min_content_size to its final value by this point
		for dim = HORIZONTAL, VERTICAL do
			min_content_size[dim] = math.max(0, min_content_size[dim])
		end
		local min_padded_size = {}
		control.transient.min_padded_size = min_padded_size
		local padding_overhead = {}
		control.transient.padding_overhead = padding_overhead
		for dim = HORIZONTAL, VERTICAL do
			local min_size_dim = min_size[dim] == MIN_SIZE_FIT_CHILDREN and min_content_size[dim] or min_size[dim]
			local before = control.configured.padding[dim][BEFORE]
			local after = control.configured.padding[dim][AFTER]
			padding_overhead[dim] = before + after
			min_padded_size[dim] = min_size_dim + padding_overhead[dim]
			local max_size_dim = max_size[dim]
			if max_size_dim ~= MAX_SIZE_INFINITE then
				min_padded_size[dim] = math.min(min_padded_size[dim], max_size_dim)
			end
		end
		if parent then -- TODO: make it a parent loop on children
			local dim_1_p, dim_2_p = both_dimensions(parent.configured.primary_dimension)
			local primary = parent.transient.min_content_size[dim_1_p]
			local secondary = parent.transient.min_content_size[dim_2_p]
			local primary_space_usage = min_padded_size[dim_1_p]
			if prev_sibling then
				primary_space_usage = primary_space_usage + control.configured.space_before
			end
			primary = primary + primary_space_usage
			control.transient.primary_space_usage = primary_space_usage
			secondary = math.max(secondary, min_padded_size[dim_2_p])
			parent.transient.min_content_size[dim_1_p] = primary
			parent.transient.min_content_size[dim_2_p] = secondary
		end
		control.transient.effective_size = { min_padded_size[HORIZONTAL], min_padded_size[VERTICAL] }
		control.transient.position = { 0, 0 }
	end)
	self.controls_[ROOT_SLOT].transient.position = { self.root_x_, self.root_y_ }
	self:traverse_controls_(function(control, parent)
		local dim_1, dim_2 = both_dimensions(control.configured.primary_dimension)
		local min_padded_size = control.transient.min_padded_size
		local effective_size = control.transient.effective_size
		local padding_overhead = control.transient.padding_overhead
		local child_space = {}
		for dim = HORIZONTAL, VERTICAL do
			child_space[dim] = effective_size[dim] - padding_overhead[dim]
		end
		local space_usage = 0
		local fill_space = 0
		if control.first_child ~= INVALID_SLOT then
			-- fill along primary dimension
			local ratio_sum = 0
			self:control_children_(control, function(child)
				local ratio = child.configured.space_fill_ratio[dim_1]
				space_usage = space_usage + child.transient.primary_space_usage
				if ratio == 0 then
					child.transient.fill_satisfied = true
				end
				ratio_sum = ratio_sum + ratio
			end)
			fill_space = math.max(0, child_space[dim_1] - space_usage)
			local last_round = false
			while true do
				local round_limited_by_max_size = false
				local fill_space_used = 0
				local ratio_sum_used = 0
				local partial_ratio_sum = 0
				self:control_children_(control, function(child)
					if not child.transient.fill_satisfied then
						local ratio = child.configured.space_fill_ratio[dim_1]
						local prev_partial_ratio_sum = partial_ratio_sum
						partial_ratio_sum = partial_ratio_sum + ratio
						local effective_size_c = child.transient.effective_size
						local max_size = child.configured.max_size[dim_1]
						local grow_lower = math.floor(fill_space * prev_partial_ratio_sum / ratio_sum)
						local grow_upper = math.floor(fill_space * partial_ratio_sum / ratio_sum)
						local should_grow = grow_upper - grow_lower
						local limited_by_max_size = false
						if max_size ~= MAX_SIZE_INFINITE then
							local can_grow = max_size - effective_size_c[dim_1]
							if can_grow < should_grow then
								round_limited_by_max_size = true
								limited_by_max_size = true
								should_grow = can_grow
							end
						end
						if last_round or limited_by_max_size then
							effective_size_c[dim_1] = effective_size_c[dim_1] + should_grow
							fill_space_used = fill_space_used + should_grow
							ratio_sum_used = ratio_sum_used + ratio
							child.transient.fill_satisfied = true
						end
					end
				end)
				fill_space = fill_space - fill_space_used
				ratio_sum = ratio_sum - ratio_sum_used
				if last_round or fill_space == 0 then
					break
				end
				if not round_limited_by_max_size then
					last_round = true
				end
			end
		end
		local max_scroll = 0
		local min_scroll = math.min(max_scroll, child_space[dim_1] - space_usage)
		local effective_scroll = math.min(max_scroll, math.max(min_scroll, control.persistent.scroll))
		control.persistent.min_scroll = min_scroll
		control.persistent.max_scroll = max_scroll
		control.persistent.scroll = effective_scroll
		effective_scroll = effective_scroll + math.floor(fill_space * control.configured.content_alignment / 2) -- alignment is 0, 1, or 2
		self:control_children_(control, function(child)
			-- fill along secondary dimension
			local effective_size_c = child.transient.effective_size
			local max_size_c = child.configured.max_size
			if child.configured.space_fill_ratio[dim_2] > 0 then
				effective_size_c[dim_2] = math.max(child_space[dim_2], effective_size_c[dim_2])
				if max_size_c[dim_2] ~= MAX_SIZE_INFINITE then
					effective_size_c[dim_2] = math.min(effective_size_c[dim_2], max_size_c[dim_2])
				end
			end
			local position_c = child.transient.position
			local align_space = child_space[dim_2] - effective_size_c[dim_2]
			position_c[dim_1] = position_c[dim_1] + effective_scroll
			position_c[dim_2] = position_c[dim_2] + math.floor(align_space * child.configured.alignment / 2) -- alignment is 0, 1, or 2
		end)
	end, nil)
	self.under_mouse_ = nil -- root's parent
	self:traverse_controls_(function(control, parent, prev_sibling)
		local position = control.transient.position
		local effective_size = control.transient.effective_size
		if parent then
			local dim_1 = parent.configured.primary_dimension
			local child_position_p = parent.transient.child_position
			if prev_sibling then
				child_position_p[dim_1] = child_position_p[dim_1] + control.configured.space_before
			end
			for dim = HORIZONTAL, VERTICAL do
				position[dim] = position[dim] + child_position_p[dim]
			end
			child_position_p[dim_1] = child_position_p[dim_1] + effective_size[dim_1]
		end
		local padding = control.configured.padding
		control.transient.child_position = {
			position[HORIZONTAL] + padding[HORIZONTAL][BEFORE],
			position[VERTICAL] + padding[VERTICAL][BEFORE],
		}
		local cvrx, cvry, cvrw, cvrh = control_rect(control)
		if parent then
			cvrx, cvry, cvrw, cvrh = intersect_rect(cvrx, cvry, cvrw, cvrh, control_visible_rect(parent))
		end
		control.transient.cvrx, control.transient.cvry, control.transient.cvrw, control.transient.cvrh = cvrx, cvry, cvrw, cvrh
		if self.mouse_x_ and self.under_mouse_ == parent and point_in_rect(self.mouse_x_, self.mouse_y_, cvrx, cvry, cvrw, cvrh) then
			if control.configured.raise_under_mouse and control.configured.z_index < Z_INDEX_UNDER_MOUSE then
				control.configured.z_index = Z_INDEX_UNDER_MOUSE
			end
			self.under_mouse_ = control
		end
	end)
	-- self:debug_()
	self.ocrx_, self.ocry_, self.ocrw_, self.ocrh_ = gfx.setClipRect()
	self:set_clip_rect_(self.ocrx_, self.ocry_, self.ocrw_, self.ocrh_)
	local handle_scroll_with = self.under_mouse_
	local wheel_offset_left = (self.wheel_offset_ or 0) * SCROLL_SPEED
	self:traverse_old_controls_(nil, function(control)
		if not control.alive then
			self:free_slot_(control.slot)
		end
	end)
	self:draw_control_(self.controls_[ROOT_SLOT])
	self:traverse_controls_(function(control, parent)
		if control.first_child ~= INVALID_SLOT then
			local cvrx, cvry, cvrw, cvrh = control_visible_rect(control)
			local function draw_child(child)
				self:set_clip_rect_(cvrx, cvry, cvrw, cvrh)
				self:draw_control_(child)
			end
			local prev_z_index = -math.huge
			while true do
				local min_z_index = math.huge
				self:control_children_(control, function(child)
					local z_index = child.configured.z_index
					if z_index > prev_z_index and min_z_index > z_index then
						min_z_index = z_index
					end
				end)
				if min_z_index == math.huge then
					break
				end
				prev_z_index = min_z_index
				self:control_children_(control, function(child)
					if child.configured.z_index == min_z_index then
						draw_child(child)
					end
				end)
			end
		end
	end, function(control, parent)
		if handle_scroll_with == control then
			-- TODO: smooth scrolling
			-- TODO: maybe do this where scrolling is applied so the min-max code doesn't have to be duplicated
			local scroll = control.persistent.scroll + wheel_offset_left
			scroll = math.min(control.persistent.max_scroll, math.max(control.persistent.min_scroll, scroll))
			wheel_offset_left = wheel_offset_left - (scroll - control.persistent.scroll)
			control.persistent.scroll = scroll
			handle_scroll_with = parent
		end
		control.alive = false
		control.old_first_child = control.first_child
		control.old_next_sibling = control.next_sibling
		control.transient = nil
		control.configured = nil
	end)
	gfx.setClipRect(self.ocrx_, self.ocry_, self.ocrw_, self.ocrh_)
	self.ocrx_, self.ocry_, self.ocrw_, self.ocrh_ = nil, nil, nil, nil
	self.click_on_ = nil
	self.click_with_ = nil
	self.wheel_offset_ = nil
	self.debug_find_control_iterations_ = nil
	self.in_frame_ = false
	if self.cancel_mouse_ then
		self.cancel_mouse_ = nil
		self.mouse_down_on_ = nil
		self.mouse_down_with_ = nil
		self.mouse_down_at_x_ = nil
		self.mouse_down_at_y_ = nil
	end
end

function imgui_i:debug_print_find_control_iterations_(text)
	table.insert(text, "- find-control iterations: " .. self.debug_find_control_iterations_ .. "\n")
end

function imgui_i:debug_print_tree_(text)
	table.insert(text, "- tree\n")
	local depth = {}
	self:traverse_controls_(function(control, parent)
		depth[control] = (parent and depth[parent] or 0) + 1
		for i = 1, depth[control] do
			table.insert(text, " ")
		end
		table.insert(text, "- ")
		table.insert(text, control.id)
		table.insert(text, " (" .. table.concat({ control_rect(control) }, "; ") .. ")")
		table.insert(text, " " .. control.configured.primary_dimension)
		table.insert(text, "\n")
	end)
end

function imgui_i:debug_()
	local text = {}
	self:debug_print_find_control_iterations_(text)
	self:debug_print_tree_(text)
	gfx.drawText(30, 30, table.concat(text))
end

function imgui_i:border(border)
	local control = self:current_control_()
	control.configured.border = border
end

function imgui_i:background(background)
	local control = self:current_control_()
	control.configured.background = background
end

function imgui_i:disabled(disabled)
	local control = self:current_control_()
	control.configured.disabled = disabled
end

function imgui_i:grooves(grooves)
	local control = self:current_control_()
	control.configured.grooves = grooves
end

function imgui_i:stuck(stuck)
	local control = self:current_control_()
	control.configured.stuck = stuck
	control.configured.z_index = stuck and Z_INDEX_STUCK or Z_INDEX_DEFAULT
end

function imgui_i:text(text)
	assert(type(text) == "string")
	local control = self:current_control_()
	control.configured.text = text
end

function imgui_i:min_size(arg_1, arg_2)
	local style = self:current_control_style_source_()
	local control = self:current_control_()
	local dim_1, dim_2 = both_dimensions(style.configured.primary_dimension)
	if arg_1 then
		assert(arg_1 == MIN_SIZE_FIT_CHILDREN or sane_size(arg_1))
		control.configured.min_size[dim_1] = arg_1
	end
	if arg_2 then
		assert(arg_2 == MIN_SIZE_FIT_CHILDREN or sane_size(arg_2))
		control.configured.min_size[dim_2] = arg_2
	end
end

function imgui_i:size(arg_1, arg_2)
	self:min_size(arg_1, arg_2)
	self:space_fill_ratio(0)
end

function imgui_i:fill_parent(space_fill_ratio) -- read: don't fit children
	self:min_size(0)
	self:space_fill_ratio(space_fill_ratio)
end

function imgui_i:text_nudge(arg_1, arg_2) -- exception: parameters are x, y
	local control = self:current_control_()
	if arg_1 then
		assert(sane_integer(arg_1))
		control.configured.text_nudge[HORIZONTAL] = arg_1
	end
	if arg_2 then
		assert(sane_integer(arg_2))
		control.configured.text_nudge[VERTICAL] = arg_2
	end
end

function imgui_i:text_alignment(arg_1, arg_2) -- exception: parameters are x, y -- TODO: maybe unify with content_alignment
	local control = self:current_control_()
	assert(arg_1 == LEFT or arg_1 == CENTER or arg_1 == RIGHT)
	control.configured.text_alignment[HORIZONTAL] = arg_1
	if arg_2 then
		assert(arg_2 == TOP or arg_2 == CENTER or arg_2 == BOTTOM)
		control.configured.text_alignment[VERTICAL] = arg_2
	end
end

function imgui_i:max_size(arg_1, arg_2)
	local style = self:current_control_style_source_()
	local control = self:current_control_()
	local dim_1, dim_2 = both_dimensions(style.configured.primary_dimension)
	if arg_1 then
		assert(sane_size(arg_1) or arg_1 == MAX_SIZE_INFINITE)
		control.configured.max_size[dim_1] = arg_1
	end
	if arg_2 then
		assert(sane_size(arg_2) or arg_2 == MAX_SIZE_INFINITE)
		control.configured.max_size[dim_2] = arg_2
	end
end

function imgui_i:alignment(alignment)
	local control = self:current_control_()
	assert(alignment == LEFT or alignment == CENTER or alignment == RIGHT)
	control.configured.alignment = alignment
end

function imgui_i:content_alignment(content_alignment)
	local control = self:current_control_()
	assert(content_alignment == LEFT or content_alignment == CENTER or content_alignment == RIGHT)
	control.configured.content_alignment = content_alignment
end

function imgui_i:primary_dimension(dim)
	local control = self:current_control_()
	assert(control.first_child == INVALID_SLOT)
	assert(dim == HORIZONTAL or dim == VERTICAL)
	control.configured.primary_dimension = dim
end

function imgui_i:space_before(space)
	local control = self:current_control_()
	assert(sane_space(space))
	control.configured.space_before = space
end

function imgui_i:padding(arg_1, arg_2, arg_3, arg_4)
	local style = self:current_control_style_source_()
	local control = self:current_control_()
	local dim_1, dim_2 = both_dimensions(style.configured.primary_dimension)
	local function padding(primary_before, primary_after, secondary_before, secondary_after)
		if primary_before then
			assert(sane_size(primary_before))
			control.configured.padding[dim_1][BEFORE] = primary_before
		end
		if primary_after then
			assert(sane_size(primary_after))
			control.configured.padding[dim_1][AFTER] = primary_after
		end
		if secondary_before then
			assert(sane_size(secondary_before))
			control.configured.padding[dim_2][BEFORE] = secondary_before
		end
		if secondary_after then
			assert(sane_size(secondary_after))
			control.configured.padding[dim_2][AFTER] = secondary_after
		end
	end
	if not arg_2 and not arg_3 and not arg_4 then
		padding(arg_1, arg_1, arg_1, arg_1)
	elseif not arg_3 and not arg_4 then
		padding(arg_1, arg_1, arg_2, arg_2)
	elseif not arg_4 then
		padding(arg_1, arg_2, arg_3, arg_3)
	else
		padding(arg_1, arg_2, arg_3, arg_4)
	end
end

function imgui_i:space_fill_ratio(arg_1, arg_2)
	local style = self:current_control_style_source_()
	local control = self:current_control_()
	local dim_1, dim_2 = both_dimensions(style.configured.primary_dimension)
	if arg_1 then
		assert(sane_size(arg_1)) -- it's going to be an integer in C++ anyway
		control.configured.space_fill_ratio[dim_1] = arg_1
	end
	if arg_2 then
		assert(sane_size(arg_2)) -- it's going to be an integer in C++ anyway
		control.configured.space_fill_ratio[dim_2] = arg_2
	end
end

function imgui_i:z_index(z_index)
	local control = self:current_control_()
	assert(sane_number(z_index))
	control.configured.z_index = z_index
end

function imgui_i:raise_under_mouse(raise_under_mouse)
	local control = self:current_control_()
	assert(sane_boolean(raise_under_mouse))
	control.configured.raise_under_mouse = raise_under_mouse
end

function imgui_i:mousedown_handler(button)
	assert(not self.in_frame_)
	if self.under_mouse_ then
		self.mouse_down_on_ = self.under_mouse_
		self.mouse_down_with_ = button
		self.mouse_down_at_x_ = self.mouse_x_
		self.mouse_down_at_y_ = self.mouse_y_
		return false
	end
	return true
end

function imgui_i:mouseup_handler(button, reason)
	assert(not self.in_frame_)
	if reason ~= ui.MOUSE_UP_NORMAL and
	   reason ~= ui.MOUSE_UP_BLUR then
		return true
	end
	if self.mouse_down_with_ == button then
		if self.under_mouse_ == self.mouse_down_on_ then
			self.click_on_ = self.mouse_down_on_
			self.click_with_ = self.mouse_down_with_
		end
		self.cancel_mouse_ = true
		return false
	end
	return true
end

function imgui_i:mousewheel_handler(offset)
	assert(not self.in_frame_)
	if self.under_mouse_ then
		self.wheel_offset_ = offset
		return false
	end
	return true
end

function imgui_i:mousemove_handler(x, y)
	assert(not self.in_frame_)
	self.mouse_x_ = x
	self.mouse_y_ = y
end

function imgui_i:blur_handler()
	assert(not self.in_frame_)
	self.mouse_x_ = nil
	self.mouse_y_ = nil
	self.cancel_mouse_ = true
end

local function make_imgui()
	local new_imgui = setmetatable({
		in_frame_ = false,
		controls_ = {},
		first_free_ = INVALID_SLOT,
		begin_control_hint_ = INVALID_SLOT,
		link_as_next_sibling_to_ = INVALID_SLOT,
		find_after_end_hint_ = INVALID_SLOT,
	}, imgui_m)
	assert(new_imgui:alloc_slot_(ROOT_NAME, INVALID_SLOT) == ROOT_SLOT)
	new_imgui.controls_[SLOT_META_ROOT_PARENT] = {}
	return new_imgui
end

return {
	make_imgui            = make_imgui,
	MIN_SIZE_FIT_CHILDREN = MIN_SIZE_FIT_CHILDREN,
	MAX_SIZE_INFINITE     = MAX_SIZE_INFINITE,
	HORIZONTAL            = HORIZONTAL,
	VERTICAL              = VERTICAL,
	TOP                   = TOP,
	LEFT                  = LEFT,
	CENTER                = CENTER,
	BOTTOM                = BOTTOM,
	RIGHT                 = RIGHT,
	Z_INDEX_DEFAULT       = Z_INDEX_DEFAULT,
	Z_INDEX_STUCK         = Z_INDEX_STUCK,
	Z_INDEX_UNDER_MOUSE   = Z_INDEX_UNDER_MOUSE,
}
