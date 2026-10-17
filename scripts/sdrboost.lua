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

local settings = { enabled = true, peak = 1600 }   -- 文件不存在时的兜底默认
local opts = require 'mp.options'
opts.read_options(settings, 'sdrboost')
settings.peak = math.max(100, math.min(2000, tonumber(settings.peak) or 1600))

-- FHDR 开启时应用的完整参数链
-- 2026-10-17 补全：之前只设 target-* 三项，saturation/gamut 等五参数缺失，
-- 因 [HDR-PQ] 的 profile-cond 看的是【源 gamma】，SDR 源被 FHDR 拉亮时仍为 bt.1886 永不命中——
-- 造成"开启 FHDR 后色彩不如之前饱和"（10-16 五参数移入 profile 前的旧观感是全局生效的）
-- 2026-10-17 v2 修正：hdr-reference-white、tone-mapping 两项不可照搬 [HDR-PQ] profile：
--   · hdr-reference-white=SDR参考白在HDR输出的nit值（默认203），inverse场景白位压到35nit全画面变暗
--   · tone-mapping=st2094-10 是 HDR10+ 动态元数据曲线，SDR 源无元数据时在 inverse 管线里成末端压缩，
--     像素矩阵实测压暗 -17%；去掉走 auto 则提亮生效
--   单变量矩阵验证：saturation/gamut-clip/contrast-recovery/target-prim 亮度零影响，保留
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
        f:write(string.format('enabled=%s\npeak=%d\n', settings.enabled and 'yes' or 'no', settings.peak))
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
    -- 供 uosc cycle 按钮读状态（值变化时 uosc 自动刷新图标）
    mp.set_property_bool('user-data/sdrboost/enabled', settings.enabled)
    mp.set_property_native('user-data/sdrboost/peak', settings.peak)
end

local function apply()
    for _, kv in ipairs(APPLY) do
        mp.set_property(kv[1], kv[2] or tostring(settings.peak))
    end
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
            if not boosting or mp.get_property('target-peak') ~= tostring(settings.peak) then
                apply()
            end
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
-- 2026-10-16 v2: 全部静默（用户不需要 OSD 提示），UI 状态由 FHDR 按钮颜色自表达
mp.register_script_message('sdrboost-toggle', function()
    settings.enabled = not settings.enabled
    save_state()
    refresh()
end)

mp.register_script_message('sdrboost-peak', function(arg)
    local d = tonumber(arg) or 0
    settings.peak = math.max(100, math.min(2000, settings.peak + d))
    save_state()
    refresh()
end)

-- FHDR 滑块（uosc elements/Fhdr.lua）直接改 user-data/sdrboost/peak → 同步应用
mp.observe_property('user-data/sdrboost/peak', 'native', function(_, v)
    if v == nil then return end
    local planned = math.max(100, math.min(2000, math.floor(tonumber(v) or settings.peak)))
    if planned ~= settings.peak then
        settings.peak = planned
        save_state()
        refresh()
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
