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
settings.peak = math.max(400, math.min(4000, tonumber(settings.peak) or 1600))

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

local function refresh()
    local g = mp.get_property('video-params/gamma')

    if g and g ~= '' and not gamma_is_hdr(g) then
        -- SDR 源
        if settings.enabled then
            if not boosting or mp.get_property('target-peak') ~= tostring(settings.peak) then
                mp.set_property('inverse-tone-mapping', 'yes')
                mp.set_property('target-trc', 'pq')
                mp.set_property('target-peak', tostring(settings.peak))
            end
            boosting = true
        elseif boosting then
            mp.set_property('inverse-tone-mapping', 'no')
            mp.set_property('target-trc', 'auto')
            mp.set_property('target-peak', 'auto')
            boosting = false
        end
    else
        -- 无视频或 HDR 源：HDR 时把 target-* 让给 [HDR-PQ] profile，不撤销不留痕
        if boosting and g and g ~= '' and gamma_is_hdr(g) then
            boosting = false   -- 交权，不 revert（profile 已接管）
        elseif boosting and (not g or g == '') then
            mp.set_property('inverse-tone-mapping', 'no')
            mp.set_property('target-trc', 'auto')
            mp.set_property('target-peak', 'auto')
            boosting = false
        end
        -- 关闭状态或 HDR 时如 user 数据未同步则同步
    end
    sync_user_data()
end

---------------- 对外命令 ----------------

mp.register_script_message('sdrboost-toggle', function()
    settings.enabled = not settings.enabled
    save_state()
    refresh()
    local g = mp.get_property('video-params/gamma')
    if settings.enabled then
        if g and gamma_is_hdr(g) then
            osd('HDR 源，SDR 增强不适用', true)
        else
            osd(string.format('SDR 亮度增强 开（上限 %d nit）', settings.peak), true)
        end
    else
        osd('SDR 亮度增强 关', true)
    end
end)

mp.register_script_message('sdrboost-peak', function(arg)
    local d = tonumber(arg) or 0
    settings.peak = math.max(800, math.min(2100, settings.peak + d))
    save_state()
    refresh()
    osd(string.format('SDR 增强峰值上限：%d nit', settings.peak), true)
end)

---------------- 属性监听 ----------------

-- uosc 的 cycle 按钮直接改 user-data/sdrboost/enabled → 同步进 settings
mp.observe_property('user-data/sdrboost/enabled', 'bool', function(_, v)
    if v == nil or v == settings.enabled then return end
    settings.enabled = v
    save_state()
    refresh()
    local g = mp.get_property('video-params/gamma')
    if settings.enabled and g and gamma_is_hdr(g) then
        osd('HDR 源，SDR 增强不适用', true)
    elseif settings.enabled then
        osd(string.format('SDR 亮度增强 开（上限 %d nit）', settings.peak), true)
    else
        osd('SDR 亮度增强 关', true)
    end
end)

-- 换片/滤镜装卸时重算
mp.observe_property('video-params/gamma', 'string', function() refresh() end)

-- 启动
refresh()
