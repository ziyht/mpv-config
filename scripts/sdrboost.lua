-- sdrboost.lua (2026-10-16)
-- SDR→HDR 亮度增强：uosc 按钮开关 + 峰值步进，配合 [HDR-PQ] profile 自动分流
-- 状态持久化在 script-opts/sdrboost.conf（enabled / peak），重启自动恢复
-- 用法：
--   uosc 按钮: cycle user-data/sdrboost/enabled（开关）
--   script-message sdrboost-peak +100 / -100（步进峰值）
-- 行为：
--   开 + SDR 源   → inverse-tone-mapping=yes + target-trc=pq + target-peak=<peak>
--   开 + HDR 源   → 不干预（交给 mpv.conf 的 [HDR-PQ] profile），OSD 提示
--   关             → 撤销上述三项为默认

local settings = { enabled = true, peak = 1600, scheme = 1 }   -- 兜底默认
local opts = require 'mp.options'
opts.read_options(settings, 'sdrboost')
settings.peak = math.max(100, math.min(2000, tonumber(settings.peak) or 1600))
settings.scheme = math.max(1, math.min(3, tonumber(settings.scheme) or 1))

-- 2026-10-17 方案矩阵(海涛定稿三方案,"分"已移除——高段与"冲"同内核、低段等价于关FHDR,价值单薄):
-- 1冲=立体冲击(v4默认链:全段拉伸+超白) 2贴=原生贴合(锚530:低段≈原生,高光无超白)
-- 3通=直通对齐(锚2000:全域直通,滑块近无感)
local SCHEMES = {
	{id = 'blast',  label = '冲', osd = '立体冲击 · 全段拉伸+超白 (v4默认链)', anchor = nil},
	{id = 'fit',    label = '贴', osd = '原生贴合 · 锚530nit 低段≈原生/高光无超白', anchor = '530', sub_peak = '530'},
	{id = 'passth', label = '通', osd = '直通对齐 · 锚2000nit 全域直通观感(滑块近无感)', anchor = '2000', sub_peak = '2000'},
}

-- FHDR 开启时应用的完整参数链
-- 2026-10-17 补全：之前只设 target-* 三项，saturation/gamut 等五参数缺失，
-- 因 [HDR-PQ] 的 profile-cond 看的是【源 gamma】，SDR 源被 FHDR 拉亮时仍为 bt.1886 永不命中——
-- 造成"开启 FHDR 后色彩不如之前饱和"（10-16 五参数移入 profile 前的旧观感是全局生效的）
-- 2026-10-17 v2 修正：hdr-reference-white、tone-mapping 两项不可照搬 [HDR-PQ] profile：
--   · hdr-reference-white=SDR参考白在HDR输出的nit值（默认203），inverse场景白位压到35nit全画面变暗
--   · tone-mapping=st2094-10 是 HDR10+ 动态元数据曲线，SDR 源无元数据时在 inverse 管线里成末端压缩，
--     像素矩阵实测压暗 -17%；去掉走 auto 则提亮生效
--   单变量矩阵验证：saturation/gamut-clip/contrast-recovery/target-prim 亮度零影响，保留
-- 2026-10-17 v4: 输出域保持 bt.2020（bt.709+PQ 组合在 macOS 无 HDR surface，EDR 链直接死）；
-- 字幕变淡的真因=字幕平面 RGB 直通 bt.2020 未做 709→2020 坐标转换，同坐标大域激发减半。
-- 解法=mpv.conf 全局 blend-subtitles=yes（字幕混入视频管线，参与完整色管，管线构建期选项须重启）
-- 2026-10-17 v10: 按"直通对齐"模型全域锚定 2000nit(海涛定):
-- SDR 内容全部落于参考白 2000nit 以内 → 无扩张段 → PQ 编码 → EDR 层对齐;
-- 滑块 nit 调整输出峰值,内容分布随 PQ 满量程缩放。v9 的 peak>530 分段条件移除。
local APPLY = {
	{'inverse-tone-mapping', 'yes'},
	{'target-trc',           'pq'},
	{'target-peak',          nil},  -- 动态: settings.peak
	{'target-prim',          'bt.2020'},
	{'saturation',           '8'},
	{'gamut-mapping-mode',   'clip'},
	{'hdr-contrast-recovery', '0.3'},
}
local REVERT = {
	{'inverse-tone-mapping', 'no'},
	{'target-trc',           'auto'},
	{'target-peak',          'auto'},
	{'target-prim',          'auto'},
	{'tone-mapping',         'auto'},
	{'hdr-reference-white',  'auto'},
	{'sub-hdr-peak',         'sdr'},
	{'saturation',           '0'},
	{'gamut-mapping-mode',   'auto'},
	{'hdr-contrast-recovery', '0'},
}

local boosting = false          -- 当前是否实际占用着 target-* 属性
local last_message = nil        -- 防止 OSD 抖动的简单去重

local function gamma_is_hdr(g)
    return g == 'pq' or g == 'arib-std-b67'
end

local function save_state()
    local path = mp.command_native({'expand-path', '~~/script-opts/sdrboost.conf'})
    local f = io.open(path, 'w')
    if f then
        f:write(string.format('enabled=%s\npeak=%d\nscheme=%d\n',
            settings.enabled and 'yes' or 'no', settings.peak, settings.scheme))
        f:close()
    end
end

local function osd(msg, force)
    if force or msg ~= last_message then
        mp.osd_message(msg, 2)
        last_message = msg
    end
end

local function sync_user_data()
    -- 供 uosc 按钮/滑块读状态（值变化时 uosc 自动刷新）
    mp.set_property_bool('user-data/sdrboost/enabled', settings.enabled)
    mp.set_property_native('user-data/sdrboost/peak', settings.peak)
    mp.set_property_native('user-data/sdrboost/scheme', settings.scheme)
    -- 2026-10-17: 中文经 user-data 传输会被 mpv0.41 弄脏(实测写入'通'读回'"通"'带引号)
    -- label 改在 uosc 侧由 scheme 数字映射, 不走属性通道
end

local function apply()
    local scheme = SCHEMES[settings.scheme] or SCHEMES[1]
    for _, kv in ipairs(APPLY) do
        mp.set_property(kv[1], kv[2] or tostring(settings.peak))
    end
    -- 方案锚定: 贴=530 / 通=2000 / 冲=auto(libplacebo默认203)
    mp.set_property('hdr-reference-white', scheme.anchor or 'auto')
    -- 2026-10-17: overlay亮度域对齐(修方案2/3下字幕暗+缩略图高光死):
    -- vo-passes实锤—方案1的overlay pass含"spline tone map (203->2000)"(overlay被拉进HDR域,亮);
    -- 方案2/3锚定后overlay无tone map pass,字幕/缩略图白位钉死203nit,相对主画面白(530/2000)只有38%/10%→视觉暗。
    -- sub-hdr-peak=把字幕/overlay的SDR白映射到指定nit,与主画面白对齐。构建期参数,随video-reload生效。
    local sub_peak = scheme.sub_peak or 'auto'
    mp.set_property('sub-hdr-peak', sub_peak)
end

local function revert()
    for _, kv in ipairs(REVERT) do
        mp.set_property(kv[1], kv[2])
    end
end

local function refresh()
    local g = mp.get_property('video-params/gamma')

    if g and g ~= '' and not gamma_is_hdr(g) then
        -- SDR 源
        if settings.enabled then
            apply()
            boosting = true
        elseif boosting then
            revert()
            boosting = false
        end
    else
        -- 无视频或 HDR 源：HDR 时把 target-* 让给 [HDR-PQ] profile，不撤销不留痕
        -- 让位时若 profile 接管（同样参数值），无需 revert；若视频卸载（无视频），还原参数
        if boosting and g and g ~= '' and gamma_is_hdr(g) then
            boosting = false   -- 交权，不 revert（profile 已接管相同参数值）
        elseif boosting and (not g or g == '') then
            revert()
            boosting = false
        end
        -- 关闭状态或 HDR 时如 user 数据未同步则同步
    end
    sync_user_data()
end

---------------- 对外命令 ----------------
-- 2026-10-16 v2 静默→v5 短提示: toggle 时刻显示一次状态,消除奇偶误判("点了没反应/闪一下就关")
-- 2026-10-17 v5: toggle 消息 0.4s 防抖 + OSD 状态提示
-- 2026-10-17 v6: peak 变化后 0.5s 防抖 video-reload——运行时改 target-peak 不触发 tone-map LUT 重建
--   (实测 B 窗 itm/peak 热改后渲染帧不变,滑块拖动无效的根源)
local schedule_visual_refresh -- 前向声明

local last_toggle_t = 0
mp.register_script_message('sdrboost-toggle', function()
    local now = mp.get_time()
    if now - last_toggle_t < 0.4 then return end
    last_toggle_t = now
    settings.enabled = not settings.enabled
    save_state()
    refresh()
    osd(settings.enabled and 'FHDR 开启 · ' .. settings.peak .. 'nit · 方案[' .. SCHEMES[settings.scheme].label .. ']' or 'FHDR 关闭', true)
end)

mp.register_script_message('sdrboost-peak', function(arg)
    local d = tonumber(arg) or 0
    settings.peak = math.max(100, math.min(2000, settings.peak + d))
    save_state()
    refresh()
    schedule_visual_refresh()
end)

-- 方案切换: sdrboost-scheme [1-3|cycle]——UI按钮主入口
mp.register_script_message('sdrboost-scheme', function(arg)
    -- 2026-10-17: 关闭状态下选方案 = 自动开启(海涛需求: F1/F2/F3应能直接启用)
    if not settings.enabled then
        settings.enabled = true
    end
    if arg == 'cycle' or arg == nil or arg == '' then
        -- 以 user-data 为唯一真源(防 settings 在 video-reload 重入窗口内分裂)
        local cur = tonumber(mp.get_property('user-data/sdrboost/scheme')) or settings.scheme or 1
        settings.scheme = (math.floor(cur) % 3) + 1
    else
        settings.scheme = math.max(1, math.min(3, tonumber(arg) or 1))
    end
    save_state()
    sync_user_data()
    refresh()
    local s = SCHEMES[settings.scheme]
    osd('FHDR方案[' .. s.label .. '] ' .. s.osd, true)
    schedule_visual_refresh()
end)

-- 四态推进: 关→冲→贴→通→关 线性链 (海涛定: 左键单击在"关掉和三个模式"间循环)
mp.register_script_message('sdrboost-advance', function()
    if not settings.enabled then
        -- 关 → 开(固定从冲起步,线性链)
        settings.enabled = true
        settings.scheme = 1
        osd('FHDR 开启[冲] · ' .. settings.peak .. 'nit', true)
    elseif settings.scheme < 3 then
        -- 开着: 方案+1
        settings.scheme = settings.scheme + 1
        local s = SCHEMES[settings.scheme]
        osd('FHDR方案[' .. s.label .. '] ' .. s.osd, true)
    else
        -- 通之后 → 关
        settings.enabled = false
        osd('FHDR 关闭', true)
    end
    save_state()
    sync_user_data()
    refresh()
    schedule_visual_refresh()
end)
mp.observe_property('user-data/sdrboost/scheme', 'native', function(_, v)
    local planned = v and math.max(1, math.min(3, math.floor(tonumber(v) or 1))) or nil
    -- 双写通道回声保护: 状态没变就忽略(防 cycle 自身触发的 observe 回环)
    if planned and planned ~= settings.scheme then
        settings.scheme = planned
        save_state()
        refresh()
        schedule_visual_refresh()
    end
end)
-- 2026-10-17: 运行时改 target-peak 不触发 tone-map LUT 重建(实测 B 窗 itm 切换后渲染帧不变)。
-- 拖动结束后 0.5s 防抖,video-reload 重建视频流管线(~0.5s, 播放位置保持)。
local visual_refresh_timer = mp.add_timeout(0.5, function()
    if settings.enabled then
        mp.msg.info('sdrboost: peak 变化, 重载视频流以重建 tone-map LUT')
        mp.command('video-reload')
    end
end)
visual_refresh_timer:kill()
schedule_visual_refresh = function()
    visual_refresh_timer:kill()
    visual_refresh_timer.timeout = 0.5
    visual_refresh_timer:resume()
end

-- FHDR 滑块（uosc 元素 FhdrSpeed）直接改 user-data/sdrboost/peak → 同步应用
mp.observe_property('user-data/sdrboost/peak', 'native', function(_, v)
    if v == nil then return end
    local planned = math.max(100, math.min(2000, math.floor(tonumber(v) or settings.peak)))
    if planned ~= settings.peak then
        settings.peak = planned
        save_state()
        refresh()
        schedule_visual_refresh()  -- 滑块是主路径,peak 变化必须重建 LUT
    end
end)

---------------- 属性监听 ----------------

-- uosc 的 cycle 按钮直接改 user-data/sdrboost/enabled → 同步进 settings
mp.observe_property('user-data/sdrboost/enabled', 'bool', function(_, v)
    if v == nil or v == settings.enabled then return end
    settings.enabled = v
    save_state()
    refresh()
end)

-- 换片/滤镜装卸时重算
mp.observe_property('video-params/gamma', 'string', function() refresh() end)

-- 启动
refresh()
