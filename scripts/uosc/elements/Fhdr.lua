-- Fhdr.lua (2026-10-16) — uosc FHDR 文字按钮 + 峰值滑块浮层
-- 按钮:「FHDR」字母, 开=橙色, 关=灰色; 点击 script-message sdrboost-toggle
-- 悬停且开启时: 按钮上方弹出滑块, 拖动/滚轮调整 100-2000nit, 写 user-data/sdrboost/peak
-- 由 sdrboost.lua 监听 user-data 并应用到 mpv (inverse-tone-mapping + target-*)
-- Controls.lua 中以 kind == 'fhdr' 挂载

local Element = require('elements/Element')

local COLOR_ON  = 'ffb13f' -- 橙(开启)
local COLOR_OFF = '8a8a8a' -- 灰(关闭)
local COLOR_HDR = '7fe3ff' -- 青(HDR源发光)
local PEAK_MIN, PEAK_MAX = 100, 2000

-- RGB(如'ffb13f') → ASS 的 BGR('3fb1ff')
local function rgb_to_bgr(rgb)
	return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

-- 发光文字：外层 \blur6 同色光晕 + 内层实体字
local function glow_txt(ass, x, y, size, text, color, border_color)
	local bgr = rgb_to_bgr(color)
	-- 光晕层：字本体透明，只留 blurred 色边
	ass:new_event()
	ass.text = ass.text .. string.format(
		'{\\pos(%d,%d)\\an5\\blur7\\bord4\\fs%d\\b1\\fn%s\\1c&H000000&\\3c&H%s&\\1a&HFF&\\3a&H99&\\4a&HFF&}%s',
		x, y, size, config.font, bgr, text)
	-- 实体字层
	ass:new_event()
	ass.text = ass.text .. string.format(
		'{\\pos(%d,%d)\\an5\\blur0\\bord1.5\\fs%d\\b1\\fn%s\\1c&H%s&\\3c&H%s&\\4a&HFF&}%s',
		x, y, size, config.font, bgr, rgb_to_bgr(border_color or '000000'), text)
end

-- ==================== 浮层滑块 ====================

---@class FhdrSlider : Element
local FhdrSlider = class(Element)

function FhdrSlider:new(id, props) return Class.new(self, id, props) --[[@as FhdrSlider]] end

function FhdrSlider:init(id, props)
	self.value = mp.get_property_native('user-data/sdrboost/peak') or 1600
	self.dragging = nil
	self.margin = 14
	self.enabled_flag = false    -- 由 FhdrButton 每帧驱动
	self.render_order = 5000     -- 画在其他元素之上
	Element.init(self, id, props)
	-- 外部改值（如脚本/未来其他UI）时同步显示
	mp.observe_property('user-data/sdrboost/peak', 'native', function(_, v)
		if v and not self.dragging then self.value = v; request_render() end
	end)
end

function FhdrSlider:place(ax, ay, bx, by)
	self.ax, self.ay, self.bx, self.by = ax, ay, bx, by
	self.height, self.width = by - ay, bx - ax
	self.font_size = round(self.height * 0.42)
end

function FhdrSlider:set_value(v, osd_notify)
	v = clamp(PEAK_MIN, round(v / 25) * 25, PEAK_MAX)
	if v ~= self.value then
		self.value = v
		-- sdrboost.lua 监听此属性并应用/保存
		mp.set_property_native('user-data/sdrboost/peak', v)
	end
end

-- Elements:proximity_trigger('mouse_move') 全局派发，拖动中持续生效
function FhdrSlider:on_global_mouse_move()
	if not self.dragging then return end
	local track_ax, track_bx = self.ax + self.margin, self.bx - self.margin
	local frac = clamp(0, 1, (cursor.x - track_ax) / math.max(1, track_bx - track_ax))
	self:set_value(PEAK_MIN + frac * (PEAK_MAX - PEAK_MIN))
	request_render()
end

function FhdrSlider:render()
	if not self.enabled_flag then return end

	local ass = assdraw.ass_new()
	local height = self.height

	-- 关闭态（hover 按钮但未开/或 HDR 源）：灰调提示，不响应任何输入
	if self.disabled_mode then
		local is_hdr_mode = self.disabled_mode == 'hdr'
		ass:rect(self.ax, self.ay, self.bx, self.by, {
			color = '000000', radius = 6, opacity = 0.95,
			border = 1.5, border_color = is_hdr_mode and COLOR_HDR or '888888',
		})
		ass:txt(self.ax + self.width / 2, self.ay + height / 2, 5,
			is_hdr_mode and 'HDR 源 · 直通输出，FHDR 不适用' or '已关闭 · 点击 FHDR 开启后再调节',
			{
				size = round(height * 0.5),
				color = is_hdr_mode and COLOR_HDR or 'aaaaaa', bold = true,
				border = 2, border_color = '000000',
			})
		return ass
	end

	-- 命中区
	cursor:zone('primary_down', self, function()
		self.dragging = true
		self:on_global_mouse_move() -- 按下即跳到光标处
		cursor:once('primary_up', function()
			self.dragging = nil
			request_render()
		end)
	end)
	cursor:zone('wheel_up',   self, function() self:set_value(self.value + 25); request_render() end)
	cursor:zone('wheel_down', self, function() self:set_value(self.value - 25); request_render() end)

	-- 背景：黑底 + 白色描边（uosc 菜单同款视觉，暗场景也醒目）
	ass:rect(self.ax, self.ay, self.bx, self.by, {
		color = '000000', radius = 6,
		opacity = 0.95,
		border = 1.5, border_color = 'ffffff',
	})
	-- 内侧微光描边（双重描边保证任何画面上都可分辨）
	ass:rect(self.ax + 1, self.ay + 1, self.bx - 1, self.by - 1, {
		color = '000000', radius = 5,
		opacity = 0.2, border = 1, border_color = 'ffffff',
	})

	-- 轨道 + 填充（加粗到 4px，橙色填充对比强）
	local ring = 14  -- 轨道距左右端
	local track_ax, track_bx = self.ax + ring, self.bx - ring
	local track_cy = self.ay + height * 0.68
	local half_t = 2
	ass:rect(track_ax, track_cy - half_t, track_bx, track_cy + half_t, {color = 'ffffff', opacity = 0.35})
	local frac = (self.value - PEAK_MIN) / (PEAK_MAX - PEAK_MIN)
	local handle_x = track_ax + frac * (track_bx - track_ax)
	ass:rect(track_ax, track_cy - half_t, handle_x, track_cy + half_t, {color = COLOR_ON, opacity = 1})

	-- 把手：双层圆（白心橙边），直径随高度放大
	local h_r = math.max(7, height * 0.18)
	ass:circle(handle_x, track_cy, h_r + 2, {color = '000000', opacity = 1})
	ass:circle(handle_x, track_cy, h_r, {color = COLOR_ON})
	ass:circle(handle_x, track_cy, h_r * 0.45, {color = 'ffffff'})

	-- 数值：大号白字（带黑描边），任何背景下可读
	ass:txt(self.ax + self.width / 2, self.ay + height * 0.16, 5,
		string.format('%d nit', self.value),
		{
			size = round(height * 0.52),
			color = 'ffffff', bold = true,
			border = 2, border_color = '000000',
			opacity = 1,
		})

	return ass
end

-- ==================== FHDR 按钮 ====================

---@class FhdrButton : Element
local FhdrButton = class(Element)

function FhdrButton:new(id, props) return Class.new(self, id, props) --[[@as FhdrButton]] end

function FhdrButton:init(id, props)
	self.slider = props.slider
	local on_click = props.on_click
	self._click = function() mp.add_timeout(0.01, on_click) end
	Element.init(self, id, {anchor_id = props.anchor_id, render_order = props.render_order})
	-- 状态变化时驱动重绘（开关 + 片源 SDR/HDR 切换都要刷新外观）
	mp.observe_property('user-data/sdrboost/enabled', 'bool', function() request_render() end)
	mp.observe_property('video-params/gamma', 'string', function() request_render() end)
	-- DEBUG/维护通道：强制弹滑块 4 秒（排查 hover 链用）
	mp.register_script_message('fhdr-force-show', function()
		self.force_show_until = mp.get_time() + 4
		request_render()
	end)
end

function FhdrButton:on_coordinates()
	self.font_size = round((self.by - self.ay) * 0.48)
end

function FhdrButton:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then
		self.slider.enabled_flag = false
		return
	end

	local is_enabled = mp.get_property_bool('user-data/sdrboost/enabled')
	local is_hover = self.proximity_raw == 0
	-- HDR 源检测：按钮变彩色 'HDR' + 发光，忽略 sdrboost 开关（升压对 HDR 无意义）
	local src_gamma = mp.get_property('video-params/gamma')
	local is_hdr_src = src_gamma == 'pq' or src_gamma == 'arib-std-b67'

	cursor:zone('primary_down', self, function() self._click() end)

	-- 悬停 → 滑块贴按钮上方（或 force-show 调试窗口期内强制显示）
	-- 保持条件：按钮 hover、滑块自身 hover、拖动中三者任一成立（鼠标从按钮移到滑块全程无缝）
	local force_show = self.force_show_until and mp.get_time() < self.force_show_until
	local slider_hover = self.slider.proximity_raw == 0
	local slider_keep = self.slider.enabled_flag and (slider_hover or self.slider.dragging)
	if is_hover or force_show or slider_keep then
		local slider_w = math.max(200, round((self.bx - self.ax) * 3))
		local ax = round(self.bx - slider_w)
		-- 底边与按钮顶边重叠 3px：鼠标垂直移动路径无 hover 断点
		local by = self.ay + 3
		self.slider:place(ax, by - 45, ax + slider_w, by)
		self.slider.enabled_flag = true
		self.slider.disabled_mode = is_hdr_src and 'hdr' or (not is_enabled and true or nil)
	elseif not self.slider.dragging then
		self.slider.enabled_flag = false
	end

	local ass = assdraw.ass_new()

	-- 背景（风格对齐其他按钮）
	if is_hover or config.opacity.controls > 0 then
		ass:rect(self.ax, self.ay, self.bx, self.by, {
			color = is_hover and 'ffffff' or '000000',
			radius = state.radius,
			opacity = visibility * (is_hover and 0.15 or config.opacity.controls),
		})
	end

	-- 字母（HDR源='HDR'彩色发光；SDR源='FHDR' 开=橙 关=灰）
	local x, y = round(self.ax + (self.bx - self.ax) / 2), round(self.ay + (self.by - self.ay) / 2)
	if is_hdr_src then
		if config.opacity.controls > 0 or is_hover then
			ass:rect(self.ax + 2, self.ay + 2, self.bx - 2, self.by - 2, {
				color = '000000', radius = state.radius, opacity = 0,
				border = 1.5, border_color = COLOR_HDR,
			})
		end
		glow_txt(ass, x, y, self.font_size, 'HDR', COLOR_HDR)
	elseif is_enabled then
		-- 橙色描边框包住按钮，开启态醒目
		ass:rect(self.ax + 2, self.ay + 2, self.bx - 2, self.by - 2, {
			color = '000000', radius = state.radius,
			opacity = 0,
			border = 1.5, border_color = COLOR_ON,
		})
		glow_txt(ass, x, y, self.font_size, 'FHDR', COLOR_ON)
	else
		ass:txt(x, y, 5, 'FHDR', {
			size = self.font_size,
			color = COLOR_OFF,
			opacity = visibility * 0.8,
			bold = true,
			border = 1,
			border_color = '000000',
		})
	end

	return ass
end
return {Button = FhdrButton, Slider = FhdrSlider}
