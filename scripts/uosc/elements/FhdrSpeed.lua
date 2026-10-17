local Element = require('elements/Element')

-- FhdrSpeed (2026-10-17): FHDR 峰值滑块，uosc Speed 同款样式（notch 刻度+三角指针+数值）
-- 海涛需求替代原 hover 浮窗方案；常驻控件栏（fhdr-speed kind），拖动/滚轮 ±25nit，范围 100-2000
-- 值经 user-data/sdrboost/peak 由 sdrboost.lua 应用并持久化

local PEAK_MIN, PEAK_MAX, STEP = 100, 2000, 25

---@class FhdrSpeed : Element
local FhdrSpeed = class(Element)

function FhdrSpeed:new(props) return Class.new(self, props) --[[@as FhdrSpeed]] end
function FhdrSpeed:init(props)
	Element.init(self, 'fhdr_speed', props)

	self.width = 0
	self.height = 0
	self.notches = 10
	self.notch_every = 100 -- 每挡100nit；1000nit处大刻度
	---@type number
	self.notch_spacing = nil
	---@type number
	self.font_size = nil
	---@type number|nil
	self.dragging = nil
	self.value = nil
	self.observing = false
end

function FhdrSpeed:get_visibility()
	return Elements:maybe('timeline', 'get_is_hovered') and -1 or Element.get_visibility(self)
end

function FhdrSpeed:observe_peak()
	if not self.observing then
		self.observing = true
		mp.observe_property('user-data/sdrboost/peak', 'native', function(_, v)
			if v then self.value = v; request_render() end
		end)
		self.value = mp.get_property_native('user-data/sdrboost/peak') or 1600
	end
end

function FhdrSpeed:on_coordinates()
	self.height, self.width = self.by - self.ay, self.bx - self.ax
	self.notch_spacing = self.width / (self.notches + 1)
	self.font_size = round(self.height * 0.48 * options.font_scale)
end
function FhdrSpeed:on_options() self:on_coordinates() end

function FhdrSpeed:set(v)
	v = clamp(PEAK_MIN, round(v / STEP) * STEP, PEAK_MAX)
	if v ~= self.value then
		self.value = v
		-- sdrboost.lua 监听此属性并应用/保存
		mp.set_property_native('user-data/sdrboost/peak', v)
	end
end

function FhdrSpeed:handle_cursor_down()
	self:tween_stop()
	self.dragging = {
		start_x = cursor.x,
		start_speed = self.value,
		speed_distance = 0,
	}
end

function FhdrSpeed:on_global_mouse_move()
	if not self.dragging then return end
	self.dragging.speed_distance = (-(cursor.x - self.dragging.start_x) / self.notch_spacing * self.notch_every)
	self:set(self.dragging.start_speed + self.dragging.speed_distance)
end

function FhdrSpeed:handle_cursor_up()
	self.dragging = nil
	request_render()
end

function FhdrSpeed:on_global_mouse_leave()
	self.dragging = nil
	request_render()
end

function FhdrSpeed:handle_wheel_up() self:set(self.value + STEP) end
function FhdrSpeed:handle_wheel_down() self:set(self.value - STEP) end

function FhdrSpeed:render()
	self:observe_peak()
	local visibility = self:get_visibility()
	local opacity = self.dragging and 1 or visibility

	if opacity <= 0 then return end

	cursor:zone('primary_down', self, function()
		self:handle_cursor_down()
		cursor:once('primary_up', function() self:handle_cursor_up() end)
	end)
	cursor:zone('secondary_click', self, function() self:set(1600) end) -- 右键重置默认
	cursor:zone('wheel_down', self, function() self:handle_wheel_down() end)
	cursor:zone('wheel_up', self, function() self:handle_wheel_up() end)

	local ass = assdraw.ass_new()

	-- Background
	ass:rect(self.ax, self.ay, self.bx, self.by, {
		color = bg, radius = state.radius, opacity = opacity * config.opacity.speed,
	})

	-- Coordinates
	local ax, ay = self.ax, self.ay
	local bx, by = self.bx, ay + self.height
	local half_width = (self.width / 2)
	local half_x = ax + half_width

	-- Notches
	local speed_at_center = self.value
	if self.dragging then
		speed_at_center = self.dragging.start_speed + self.dragging.speed_distance
		speed_at_center = clamp(PEAK_MIN, speed_at_center, PEAK_MAX)
	end
	local nearest_notch_speed = round(speed_at_center / self.notch_every) * self.notch_every
	local nearest_notch_x = half_x + (((nearest_notch_speed - speed_at_center) / self.notch_every) * self.notch_spacing)
	local guide_size = math.floor(self.height / 7.5)
	local notch_by = by - guide_size
	local notch_ay_big = ay + round(self.font_size * 1.1)
	local notch_ay_medium = notch_ay_big + ((notch_by - notch_ay_big) * 0.2)
	local notch_ay_small = notch_ay_big + ((notch_by - notch_ay_big) * 0.4)
	local from_to_index = math.floor(self.notches / 2)

	for i = -from_to_index, from_to_index do
		local notch_speed = nearest_notch_speed + (i * self.notch_every)

		if notch_speed >= PEAK_MIN and notch_speed <= PEAK_MAX then
			local notch_x = nearest_notch_x + (i * self.notch_spacing)
			local notch_thickness = 1
			local notch_ay = notch_ay_small
			if (notch_speed % (self.notch_every * 10)) < 0.00000001 then
				notch_ay = notch_ay_big
				notch_thickness = 1.5
			elseif (notch_speed % (self.notch_every * 5)) < 0.00000001 then
				notch_ay = notch_ay_medium
			end

			ass:rect(notch_x - notch_thickness, notch_ay, notch_x + notch_thickness, notch_by, {
				color = fg,
				border = 1,
				border_color = bg,
				opacity = math.min(1.2 - (math.abs((notch_x - ax - half_width) / half_width)), 1) * opacity,
			})
		end
	end

	-- Center guide
	ass:new_event()
	ass:append('{\\rDefault\\an7\\blur0\\bord1\\shad0\\1c&H' .. fg .. '\\3c&H' .. bg .. '}')
	ass:opacity(opacity)
	ass:pos(0, 0)
	ass:draw_start()
	ass:move_to(half_x, by - 2 - guide_size)
	ass:line_to(half_x + guide_size, by - 2)
	ass:line_to(half_x - guide_size, by - 2)
	ass:draw_stop()

	-- Peak value
	local peak_text = tostring(self.value or 1600) .. ' nit'
	ass:txt(half_x, ay + (notch_ay_big - ay) / 2, 5, peak_text, {
		size = self.font_size,
		color = bgt,
		border = options.text_border * state.scale,
		border_color = bg,
		opacity = opacity,
	})

	return ass
end

return FhdrSpeed
