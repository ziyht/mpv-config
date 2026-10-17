-- Fhdr.lua (2026-10-17 v3)
-- FHDR 开关按钮（SDR 强制 HDR 亮度增强）
--   开启 → 橙色发光 'FHDR'   关闭 → 灰色 'FHDR'
--   HDR 源（PQ/HLG）→ 彩色波浪发光 'HDR'（源指示，与开关无关）
-- 峰值调节已移至 FhdrSpeed 元素（Speed 同款样式，kind 'fhdr-speed'）
-- Controls.lua 中以 kind == 'fhdr' 挂载

local Element = require('elements/Element')
-- Elements/cursor/config/state 等为 uosc 注入的全局（Element.lua 同款用法）

local COLOR_ON  = 'ffb13f' -- 橙(开启)
local COLOR_OFF = '8a8a8a' -- 灰(关闭)
local COLOR_HDR = '7fe3ff' -- 青(HDR源发光)

-- RGB(如'ffb13f') → ASS 的 BGR('3fb1ff')
local function rgb_to_bgr(rgb)
	return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

-- 色相(0-1) → RGB hex，彩虹用
local function hue_to_rgb(h)
	h = h % 1
	local r, g, b
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local q = 1 - f
	if i == 0 then r, g, b = 1, f, 0
	elseif i == 1 then r, g, b = q, 1, 0
	elseif i == 2 then r, g, b = 0, 1, f
	elseif i == 3 then r, g, b = 0, q, 1
	elseif i == 4 then r, g, b = f, 0, 1
	else r, g, b = 1, 0, q end
	return string.format('%02x%02x%02x', round(r * 255), round(g * 255), round(b * 255))
end

-- 发光文字（三层，intensity 驱动光晕呼吸）：外层大模糊半透明字本体 = 光晕 blob
local function glow_txt(ass, x, y, size, text, color, intensity)
	intensity = intensity or 1
	local bgr = rgb_to_bgr(color)
	-- 光晕透明度随 intensity 调制（1=最亮 &H20，低=变暗）
	local outer_a = 0x20 + math.floor((1 - intensity) * 0x80)
	local mid_a = 0x28 + math.floor((1 - intensity) * 0x50)
	-- 光晕外层：大范围软光（半透明彩色字整体模糊）
	ass:new_event()
	ass.text = ass.text .. string.format(
		'{\\pos(%d,%d)\\an5\\blur9\\bord0.5\\fs%d\\b1\\fn%s\\1c&H%s&\\3c&H%s&\\1a&H%02X&\\3a&H%02X&\\4a&HFF&}%s',
		x, y, size, config.font, bgr, bgr, outer_a, outer_a, text)
	-- 光晕中层：紧贴实体的加浓
	ass:new_event()
	ass.text = ass.text .. string.format(
		'{\\pos(%d,%d)\\an5\\blur3\\bord1\\fs%d\\b1\\fn%s\\1c&H%s&\\3c&H%s&\\1a&H%02X&\\3a&H%02X&\\4a&HFF&}%s',
		x, y, size, config.font, bgr, bgr, mid_a, mid_a + 0x10, text)
	-- 实体字层
	ass:new_event()
	ass.text = ass.text .. string.format(
		'{\\pos(%d,%d)\\an5\\blur0\\bord1.5\\fs%d\\b1\\fn%s\\1c&H%s&\\3c&H%s&\\4a&HFF&}%s',
		x, y, size, config.font, bgr, rgb_to_bgr('000000'), text)
end

-- ==================== FHDR 按钮 ====================

local FhdrButton = class(Element)

function FhdrButton:new(id, props) return Class.new(self, id, props) --[[@as FhdrButton]] end

function FhdrButton:init(id, props)
	local on_click = props.on_click
	self._click = function() mp.add_timeout(0.01, on_click) end
	Element.init(self, id, props)
	-- 状态变化时驱动重绘（开关 + 片源 SDR/HDR 切换都要刷新外观）
	mp.observe_property('user-data/sdrboost/enabled', 'bool', function() request_render() end)
	mp.observe_property('video-params/gamma', 'string', function(_, g)
		request_render()
		-- HDR 态启动彩虹流动定时器（20fps 重绘），离开 HDR 停（不空烧 CPU）
		local hdr = g == 'pq' or g == 'arib-std-b67'
		if hdr and not self.rainbow_timer then
			self.rainbow_timer = mp.add_periodic_timer(0.05, function() request_render() end)
		elseif not hdr and self.rainbow_timer then
			self.rainbow_timer:kill()
			self.rainbow_timer = nil
		end
	end)
end

function FhdrButton:on_coordinates()
	self.font_size = round((self.by - self.ay) * 0.48)
end

function FhdrButton:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end

	local is_enabled = mp.get_property_bool('user-data/sdrboost/enabled')
	local is_hover = self.proximity_raw == 0
	-- HDR 源检测：按钮变彩色 'HDR' + 发光，忽略 sdrboost 开关（升压对 HDR 无意义）
	local src_gamma = mp.get_property('video-params/gamma')
	local is_hdr_src = src_gamma == 'pq' or src_gamma == 'arib-std-b67'

	cursor:zone('primary_down', self, function() self._click() end)

	local ass = assdraw.ass_new()

	-- 背景（风格对齐其他按钮）
	if is_hover or config.opacity.controls > 0 then
		ass:rect(self.ax, self.ay, self.bx, self.by, {
			color = is_hover and 'ffffff' or '000000',
			radius = state.radius,
			opacity = visibility * (is_hover and 0.15 or config.opacity.controls),
		})
	end

	-- 字母（HDR源='HDR'彩虹波浪发光；SDR源='FHDR' 开=橙 关=灰）
	local x, y = round(self.ax + (self.bx - self.ax) / 2), round(self.ay + (self.by - self.ay) / 2)
	if is_hdr_src then
		if config.opacity.controls > 0 or is_hover then
			ass:rect(self.ax + 2, self.ay + 2, self.bx - 2, self.by - 2, {
				color = '000000', radius = state.radius, opacity = 0,
				border = 1.5, border_color = COLOR_HDR,
			})
		end
		-- 彩虹波浪：邻近色小相位差渐变（不割裂）+ 亮度脉冲波错峰传播（单独变但联动）
		local t = mp.get_time()
		local letters = {'H', 'D', 'R'}
		local spacing = self.font_size * 0.64
		local x0 = x - spacing  -- 三字母居中: x - sp, x, x + sp
		for i, letter in ipairs(letters) do
			-- 色相：整体缓慢旋转，字母间小偏移(0.11≈40°)形成渐进波浪带
			local hue = (t * 0.10 - (i - 1) * 0.11) % 1
			-- 亮度：sin 波沿字母序错峰传播（0.7Hz，相位步进 ~60°）
			local wave = 0.5 + 0.5 * math.sin(t * math.pi * 2 * 0.7 - (i - 1) * 1.05)
			local intensity = 0.35 + 0.65 * wave  -- ∈ [0.35, 1]
			glow_txt(ass, x0 + (i - 1) * spacing, y, self.font_size, letter, hue_to_rgb(hue), intensity)
		end
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

return {Button = FhdrButton}
