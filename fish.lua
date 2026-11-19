local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Workspace = game:GetService("Workspace")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end
local LP = Players.LocalPlayer
while not LP do task.wait(); LP = Players.LocalPlayer end

if getgenv().AutoFishCleanup then pcall(getgenv().AutoFishCleanup) end
getgenv().AutoFishRunning = true

local function findModule(name, preferredPath, roots, timeout)
    timeout = timeout or 15
    local t0 = os.clock()
    repeat
        local node = roots[1]
        for _, part in ipairs(preferredPath) do
            node = node and node:FindFirstChild(part)
        end
        if node and node:IsA("ModuleScript") then return node end
        for _, root in ipairs(roots) do
            if root then
                for _, d in ipairs(root:GetDescendants()) do
                    if d.Name == name and d:IsA("ModuleScript") then return d end
                end
            end
        end
        task.wait(0.5)
    until os.clock() - t0 > timeout
    return nil
end

local RS_ROOTS = { ReplicatedStorage, ReplicatedFirst }
local RF_ROOTS = { ReplicatedFirst, ReplicatedStorage, LP:WaitForChild("PlayerScripts", 10) }

local modDefs = {
    BridgeNet         = { {"Shared","BridgeNet"},                         RS_ROOTS },
    FishingMinigame   = { {"Shared","FishingMinigame"},                   RS_ROOTS },
    FishingUtil       = { {"Shared","FishingUtil"},                       RS_ROOTS },
    FishingRodClient  = { {"Shared","ClientTools","FishingRodClient"},    RS_ROOTS },
    FishingController = { {"Controllers","Gameplay","FishingController"}, RF_ROOTS },
}

local M, missing = {}, {}
for name, def in pairs(modDefs) do
    local inst = findModule(name, def[1], def[2])
    if not inst then
        table.insert(missing, name)
    else
        local ok, res = pcall(require, inst)
        if ok then M[name] = res
        else table.insert(missing, name.." (require failed: "..tostring(res)..")") end
    end
end
if #missing > 0 then
    getgenv().AutoFishRunning = false
    error("[AutoFish] Could not load: "..table.concat(missing, ", ")
        .." — the game likely updated; check ReplicatedStorage in Dex for the new names.", 0)
end

local BridgeNet         = M.BridgeNet
local FishingMinigame   = M.FishingMinigame
local FishingUtil       = M.FishingUtil
local FishingRodClient  = M.FishingRodClient
local FishingController = M.FishingController
local fishingBridge     = BridgeNet.CreateBridge("Fishing")

local cfg = {
    autoFish            = false,
    autoTP              = false,
    autoReel            = true,
    castCooldown        = 4,
    retryAfterFail      = 3,
}
local S = { casts=0, catches=0, credits=0, lastMsg="—", sessionActive=false, log={} }
getgenv().AutoFishConfig = cfg
getgenv().AutoFishState  = S

local function pushLog(text)
    table.insert(S.log, 1, os.date("%X").." "..text)
    while #S.log > 30 do table.remove(S.log) end
end
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    pushLog(table.concat(parts, " "))
end

local function getRod()
    local char = LP.Character
    if char then
        local eq = char:FindFirstChild("FishingRod") or char:FindFirstChild("GoldFishingRod")
        if eq then return eq, true end
    end
    local bp = LP:FindFirstChildOfClass("Backpack")
    if bp then
        local br = bp:FindFirstChild("FishingRod") or bp:FindFirstChild("GoldFishingRod")
        if br then return br, false end
    end
    return nil, false
end
local function equipRod()
    local rod, eq = getRod()
    if not rod then return nil end
    if eq then return rod end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:EquipTool(rod); task.wait(0.3) end
    return (select(1, getRod()))
end

local rodCooldown = nil
if type(FishingRodClient.SetCatchCooldown) == "function" then
    local ok, v = pcall(debug.getupvalue, FishingRodClient.SetCatchCooldown, 1)
    if ok then rodCooldown = v end
end

local function castReadyIn()
    if FishingController:IsFishing() then return nil end
    if type(rodCooldown) ~= "table" or not rodCooldown.GetRemainingTime then return 0 end
    local ok, rem = pcall(rodCooldown.GetRemainingTime, rodCooldown, LP)
    return ok and math.max(tonumber(rem) or 0, 0) or 0
end

local rodObjCache = nil
local function getRodObject(rod)
    if rodObjCache and rawget(rodObjCache, "Instance") == rod then return rodObjCache end
    rodObjCache = nil
    for _, t in ipairs(getgc(true)) do
        if type(t) == "table" and rawget(t, "Instance") == rod and t.GetCastHitPosition then
            rodObjCache = t
            break
        end
    end
    return rodObjCache
end

local CAST_DISTANCE = 20

local function pickAim(fp, hrp)
    local top = fp.CFrame:PointToWorldSpace(Vector3.new(0, fp.Size.Y / 2, 0))
    local flat = (top - hrp.Position) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 1 then
        flat = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
    end
    local p = hrp.Position + flat.Unit * CAST_DISTANCE
    return Vector3.new(p.X, top.Y, p.Z)
end

local function performNativeCast(rod)
    local fp = FishingUtil.getFishingPoint()
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (fp and hrp and rod) then return false end

    if cfg.autoTP then
        hrp.CFrame = CFrame.new(fp.Position + Vector3.new(0, 6, 0))
        task.wait(0.18)
    end

    local aim = pickAim(fp, hrp)

    local obj = getRodObject(rod)
    if not obj then log("WARNING: rod client object not found — cast will follow the cursor") end
    local saved = obj and rawget(obj, "GetMousePosition")
    if obj then rawset(obj, "GetMousePosition", function() return aim end) end

    local ok, err = pcall(function() rod:Activate() end)

    local t0 = os.clock()
    while ok and os.clock() - t0 < 0.5 and not FishingController:IsFishing() do task.wait() end
    if obj then rawset(obj, "GetMousePosition", saved) end

    if not ok then log("cast failed: "..tostring(err)) end
    return ok
end

local sessionId = nil
local nextCastAt = 0

local fishingConn = fishingBridge:Connect(function(msg, ...)
    S.lastMsg = msg
    if msg == "SessionStarted" then
        local id = ...
        if typeof(id) ~= "string" then return end
        sessionId = id
        S.sessionActive = true
        S.progress = 0; S.reelFrames = 0
        log("session started")
    elseif msg == "ProgressUpdate" then
        local p = tonumber((select(1, ...)))
        if p then S.progress = p end
    elseif msg == "Caught" then
        local r, b = ...
        r, b = tonumber(r) or 0, tonumber(b) or 0
        S.catches += 1; S.credits += r
        log(("CAUGHT $%d (+$%d bonus)"):format(r, b))
        sessionId = nil; S.sessionActive = false
    elseif msg == "CastFailed" then
        local reason = ...
        log(reason ~= nil and ("CastFailed: "..tostring(reason)) or "CastFailed")
        sessionId = nil; S.sessionActive = false
        nextCastAt = tick() + cfg.retryAfterFail
    elseif msg == "SessionCancelled" or msg == "CancelFishing" or msg == "LeaveArea" then
        log("end: "..msg)
        sessionId = nil; S.sessionActive = false
    elseif msg == "Cooldown" then
        local w = tonumber((select(1, ...))) or 3
        nextCastAt = math.max(nextCastAt, tick() + w + 0.5)
        log("cooldown "..w.."s")
    end
end)

local UPV_REELING = 6
local UPV_SIM     = 8
local UPV_CTRL    = 9

local function findBeginMinigame()
    for _, f in ipairs(getgc(false)) do
        if type(f) == "function" then
            local ok, src = pcall(debug.info, f, "s")
            if ok and type(src) == "string" and src:find("FishingController", 1, true)
                and debug.info(f, "n") == "beginMinigame" then
                return f
            end
        end
    end
end

local beginMinigame = findBeginMinigame()
if beginMinigame then
    local okC, ctrl = pcall(debug.getupvalue, beginMinigame, UPV_CTRL)
    local okR, reeling = pcall(debug.getupvalue, beginMinigame, UPV_REELING)
    if not okC or not okR or type(ctrl) ~= "table" or ctrl.ConfirmCast == nil
        or type(reeling) ~= "boolean" then
        beginMinigame = nil
    end
end

local GRAVITY        = FishingMinigame.REGION_GRAVITY
local REEL_ACCEL     = FishingMinigame.REGION_REEL_ACCELERATION
local FISH_LOOKAHEAD = 0.08

local function wantReel(sim, now)
    local fishY = FishingMinigame.getFishCenterY(sim, now + FISH_LOOKAHEAD)
    local v = sim.RegionVelocityY
    local err = sim.RegionCenterY - fishY
    local brake = (v < 0) and (v * v) / (2 * GRAVITY) or -(v * v) / (2 * REEL_ACCEL)
    return err > brake
end

local REEL_BIND = "AutoFishReel"
pcall(function() RunService:UnbindFromRenderStep(REEL_BIND) end)
if beginMinigame and GRAVITY and REEL_ACCEL then
    RunService:BindToRenderStep(REEL_BIND, Enum.RenderPriority.Input.Value, function()
        if not cfg.autoReel then return end
        local ctrl = debug.getupvalue(beginMinigame, UPV_CTRL)
        local sim  = debug.getupvalue(beginMinigame, UPV_SIM)
        if not (type(ctrl) == "table" and ctrl.IsActive and type(sim) == "table" and sim.RegionCenterY) then return end
        local reel = wantReel(sim, Workspace:GetServerTimeNow())
        debug.setupvalue(beginMinigame, UPV_REELING, reel)
        sim.IsReeling = reel
        S.reelFrames = (S.reelFrames or 0) + 1
    end)
else
    log("WARNING: couldn't hook FishingController minigame — auto-reel disabled")
end

task.spawn(function()
    while getgenv().AutoFishRunning do
        task.wait(0.4)
        if cfg.autoFish and not sessionId and tick() >= nextCastAt and castReadyIn() == 0 then
            local rod = equipRod()
            if rod then
                S.casts += 1
                log("cast #"..S.casts)
                nextCastAt = tick() + cfg.castCooldown
                if performNativeCast(rod) then
                    local waited = 0
                    while waited < 4 and not sessionId and cfg.autoFish do
                        task.wait(0.1); waited += 0.1
                    end
                    if not sessionId and cfg.autoFish then
                        log("no session after cast")
                    end
                end
            end
        end
    end
end)

local hotkeyConn = UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.H and UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
        cfg.autoFish = not cfg.autoFish
        if cfg.autoFish then nextCastAt = 0 end
        log(cfg.autoFish and "AUTO-FISH ON" or "AUTO-FISH OFF")
    end
end)

local COL_BG        = Color3.fromRGB(20, 22, 28)
local COL_PANEL     = Color3.fromRGB(28, 30, 38)
local COL_ACCENT    = Color3.fromRGB(90, 140, 255)
local COL_ACCENT_D  = Color3.fromRGB(60, 100, 210)
local COL_TEXT      = Color3.fromRGB(230, 232, 240)
local COL_MUTED     = Color3.fromRGB(140, 148, 168)
local COL_OFF       = Color3.fromRGB(50, 54, 66)
local COL_GREEN     = Color3.fromRGB(90, 200, 130)
local COL_RED       = Color3.fromRGB(230, 90, 100)

local function pickParent()
    local ok, hui = pcall(function() return (gethui and gethui()) or nil end)
    if ok and typeof(hui) == "Instance" then return hui end
    return LP:WaitForChild("PlayerGui")
end
local parentGui = pickParent()

local screen = Instance.new("ScreenGui")
screen.Name = "AutoFishUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = true

local okParent = pcall(function() screen.Parent = parentGui end)
if not okParent then
    parentGui = LP:WaitForChild("PlayerGui")
    screen.Parent = parentGui
end

local function corner(inst, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = inst
    return c
end
local function stroke(inst, col, thick)
    local s = Instance.new("UIStroke"); s.Color = col or Color3.fromRGB(60,64,80); s.Thickness = thick or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = inst
    return s
end
local layoutCounter = 0
local function ordered(inst)
    layoutCounter += 1
    inst.LayoutOrder = layoutCounter
    return inst
end

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(360, 470)
main.Position = UDim2.fromOffset(40, 80)
main.BackgroundColor3 = COL_BG
main.BorderSizePixel = 0
main.Parent = screen
corner(main, 10); stroke(main, Color3.fromRGB(60,64,80), 1)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 36)
header.BackgroundColor3 = COL_PANEL
header.BorderSizePixel = 0
header.Parent = main
corner(header, 10)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 14, 0, 0)
title.Font = Enum.Font.GothamBold
title.Text = "Auto Fish · German Voice"
title.TextSize = 14
title.TextColor3 = COL_TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -10, 0.5, 0)
closeBtn.Size = UDim2.fromOffset(24, 24)
closeBtn.BackgroundColor3 = COL_OFF
closeBtn.Text = "×"; closeBtn.TextColor3 = COL_TEXT
closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 16
closeBtn.BorderSizePixel = 0
closeBtn.Parent = header
corner(closeBtn, 6)

local uiConns = {}

do
    local dragging = false
    local dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    table.insert(uiConns, UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                       startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
end

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -20, 0, 30); tabBar.Position = UDim2.new(0, 10, 0, 44)
tabBar.BackgroundTransparency = 1; tabBar.Parent = main

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Padding = UDim.new(0, 6); tabLayout.Parent = tabBar

local content = Instance.new("Frame")
content.Size = UDim2.new(1, -20, 1, -88); content.Position = UDim2.new(0, 10, 0, 80)
content.BackgroundTransparency = 1; content.Parent = main

local tabs = {}
local function makeTab(name)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(90, 30); btn.BackgroundColor3 = COL_OFF
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamMedium; btn.TextSize = 13; btn.TextColor3 = COL_TEXT
    btn.Text = name; ordered(btn); btn.Parent = tabBar
    corner(btn, 6)

    local body = Instance.new("ScrollingFrame")
    body.Size = UDim2.new(1, 0, 1, 0)
    body.BackgroundTransparency = 1; body.BorderSizePixel = 0
    body.ScrollBarThickness = 3
    body.CanvasSize = UDim2.new(0, 0, 0, 0)
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y
    body.Visible = false; body.Parent = content
    local layout = Instance.new("UIListLayout"); layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder; layout.Parent = body
    local px = Instance.new("UIPadding"); px.PaddingRight = UDim.new(0, 6); px.Parent = body

    tabs[name] = { btn = btn, body = body }
    btn.MouseButton1Click:Connect(function()
        for n, t in pairs(tabs) do
            t.body.Visible = (n == name)
            t.btn.BackgroundColor3 = (n == name) and COL_ACCENT_D or COL_OFF
        end
    end)
    return body
end

local fishBody     = makeTab("Fishing")
local statsBody    = makeTab("Stats")
local settingsBody = makeTab("Settings")
tabs.Fishing.body.Visible = true
tabs.Fishing.btn.BackgroundColor3 = COL_ACCENT_D

local function section(parent, text)
    local sec = Instance.new("TextLabel")
    sec.BackgroundTransparency = 1
    sec.Size = UDim2.new(1, 0, 0, 20)
    sec.Font = Enum.Font.GothamBold; sec.TextSize = 12
    sec.TextColor3 = COL_MUTED; sec.TextXAlignment = Enum.TextXAlignment.Left
    sec.Text = text:upper(); ordered(sec); sec.Parent = parent
end

local function toggle(parent, text, initial, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 34); row.BackgroundColor3 = COL_PANEL
    row.BorderSizePixel = 0; ordered(row); row.Parent = parent
    corner(row, 6)
    local lab = Instance.new("TextLabel")
    lab.BackgroundTransparency = 1; lab.Size = UDim2.new(1, -60, 1, 0)
    lab.Position = UDim2.new(0, 10, 0, 0); lab.Font = Enum.Font.Gotham; lab.TextSize = 13
    lab.TextColor3 = COL_TEXT; lab.TextXAlignment = Enum.TextXAlignment.Left
    lab.Text = text; lab.Parent = row
    local sw = Instance.new("TextButton")
    sw.AnchorPoint = Vector2.new(1, 0.5); sw.Position = UDim2.new(1, -10, 0.5, 0)
    sw.Size = UDim2.fromOffset(40, 20); sw.BorderSizePixel = 0
    sw.Text = ""; sw.AutoButtonColor = false; sw.Parent = row
    corner(sw, 10)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(16, 16); knob.BorderSizePixel = 0
    knob.BackgroundColor3 = Color3.fromRGB(240,240,240); knob.Parent = sw
    corner(knob, 8)
    local state = not not initial
    local function render()
        sw.BackgroundColor3 = state and COL_ACCENT or COL_OFF
        knob.Position = state and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
    end
    sw.MouseButton1Click:Connect(function() state = not state; render(); cb(state) end)
    render(); cb(state)
    return function(v) state = not not v; render(); cb(state) end
end

local function slider(parent, text, minV, maxV, step, initial, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 48); row.BackgroundColor3 = COL_PANEL
    row.BorderSizePixel = 0; ordered(row); row.Parent = parent
    corner(row, 6)
    local lab = Instance.new("TextLabel")
    lab.BackgroundTransparency = 1; lab.Size = UDim2.new(1, -60, 0, 20)
    lab.Position = UDim2.new(0, 10, 0, 4); lab.Font = Enum.Font.Gotham; lab.TextSize = 13
    lab.TextColor3 = COL_TEXT; lab.TextXAlignment = Enum.TextXAlignment.Left
    lab.Text = text; lab.Parent = row
    local val = Instance.new("TextLabel")
    val.BackgroundTransparency = 1; val.AnchorPoint = Vector2.new(1, 0)
    val.Position = UDim2.new(1, -10, 0, 4); val.Size = UDim2.fromOffset(48, 20)
    val.Font = Enum.Font.GothamBold; val.TextSize = 13; val.TextColor3 = COL_ACCENT
    val.TextXAlignment = Enum.TextXAlignment.Right; val.Text = tostring(initial); val.Parent = row
    local bar = Instance.new("Frame")
    bar.AnchorPoint = Vector2.new(0, 1); bar.Position = UDim2.new(0, 10, 1, -10)
    bar.Size = UDim2.new(1, -20, 0, 6); bar.BackgroundColor3 = COL_OFF
    bar.BorderSizePixel = 0; bar.Parent = row
    corner(bar, 3)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0); fill.BackgroundColor3 = COL_ACCENT
    fill.BorderSizePixel = 0; fill.Parent = bar
    corner(fill, 3)

    local function apply(v)
        v = math.clamp(v, minV, maxV)
        if step then v = math.floor((v - minV) / step + 0.5) * step + minV end
        val.Text = tostring(math.floor(v * 100) / 100)
        fill.Size = UDim2.new((v - minV) / (maxV - minV), 0, 1, 0)
        cb(v)
    end
    apply(initial)

    local dragging = false
    local function ptToVal(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        return minV + rel * (maxV - minV)
    end
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; apply(ptToVal(i.Position.X))
        end
    end)
    table.insert(uiConns, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    table.insert(uiConns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            apply(ptToVal(i.Position.X))
        end
    end))
    return apply
end

local function button(parent, text, cb)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 32); b.BackgroundColor3 = COL_ACCENT_D
    b.Font = Enum.Font.GothamMedium; b.TextSize = 13; b.TextColor3 = COL_TEXT
    b.Text = text; b.BorderSizePixel = 0; ordered(b); b.Parent = parent
    corner(b, 6)
    b.MouseButton1Click:Connect(cb)
    return b
end

local function label(parent, text)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1; l.Size = UDim2.new(1, 0, 0, 22)
    l.Font = Enum.Font.Gotham; l.TextSize = 13
    l.TextColor3 = COL_TEXT; l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text; ordered(l); l.Parent = parent
    return l
end

local function keybind(parent, text, initial, cb)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 34); row.BackgroundColor3 = COL_PANEL
    row.BorderSizePixel = 0; ordered(row); row.Parent = parent
    corner(row, 6)
    local lab = Instance.new("TextLabel")
    lab.BackgroundTransparency = 1; lab.Size = UDim2.new(1, -140, 1, 0)
    lab.Position = UDim2.new(0, 10, 0, 0); lab.Font = Enum.Font.Gotham; lab.TextSize = 13
    lab.TextColor3 = COL_TEXT; lab.TextXAlignment = Enum.TextXAlignment.Left
    lab.Text = text; lab.Parent = row
    local btn = Instance.new("TextButton")
    btn.AnchorPoint = Vector2.new(1, 0.5); btn.Position = UDim2.new(1, -8, 0.5, 0)
    btn.Size = UDim2.fromOffset(120, 24); btn.BorderSizePixel = 0; btn.AutoButtonColor = false
    btn.Font = Enum.Font.GothamMedium; btn.TextSize = 12; btn.TextColor3 = COL_TEXT
    btn.Parent = row
    corner(btn, 6)
    local key, listening = initial, false
    local function render()
        btn.Text = listening and "Press a key..." or (key and key.Name or "None")
        btn.BackgroundColor3 = listening and COL_ACCENT_D or COL_OFF
    end
    btn.MouseButton1Click:Connect(function() listening = not listening; render() end)
    render()
    return function(input)
        if not listening or input.UserInputType ~= Enum.UserInputType.Keyboard then return false end
        listening = false
        if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
            key = nil
        elseif input.KeyCode ~= Enum.KeyCode.Escape then
            key = input.KeyCode
        end
        render(); cb(key)
        return true
    end
end

section(fishBody, "Main")
toggle(fishBody, "Auto Fish", false, function(v)
    cfg.autoFish = v
    if v then nextCastAt = 0 end
    log(v and "AUTO-FISH ON" or "AUTO-FISH OFF")
end)
toggle(fishBody, "Teleport onto pool before each cast", false, function(v) cfg.autoTP = v end)
toggle(fishBody, "Auto reel minigame",                  true,  function(v) cfg.autoReel = v end)

section(fishBody, "Tuning")
slider(fishBody, "Retry after no bite (s)", 2, 20, 1, cfg.castCooldown, function(v) cfg.castCooldown = v end)

section(fishBody, "Manual")
button(fishBody, "Cast once now", function()
    task.spawn(function()
        local readyIn = castReadyIn()
        if sessionId or not readyIn then log("already fishing"); return end
        if readyIn > 0 then log(("rod cooldown %.1fs"):format(readyIn)); return end
        local rod = equipRod(); if not rod then log("no rod"); return end
        S.casts += 1; log("manual cast #"..S.casts); nextCastAt = tick() + cfg.castCooldown
        performNativeCast(rod)
    end)
end)
button(fishBody, "Teleport to pool", function()
    local fp = FishingUtil.getFishingPoint()
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if fp and hrp then hrp.CFrame = CFrame.new(fp.Position + Vector3.new(0, 6, 0)) end
end)

section(statsBody, "Live")
local lCasts   = label(statsBody, "Casts: 0")
local lCatches = label(statsBody, "Catches: 0")
local lCred    = label(statsBody, "Credits earned: $0")
local lRate    = label(statsBody, "Catch rate: —")
local lSess    = label(statsBody, "Session: idle")
local lNext    = label(statsBody, "Next cast: —")
local lProg    = label(statsBody, "Progress: 0%")
local lReels   = label(statsBody, "Reel frames driven: 0")
local lLast    = label(statsBody, "Last event: —")

section(statsBody, "Recent log")
local logBox = Instance.new("TextLabel")
logBox.BackgroundColor3 = COL_PANEL; logBox.BorderSizePixel = 0
logBox.Size = UDim2.new(1, 0, 0, 160); logBox.Font = Enum.Font.Code
logBox.TextSize = 12; logBox.TextColor3 = COL_MUTED
logBox.TextXAlignment = Enum.TextXAlignment.Left; logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = true; logBox.Text = "(no events yet)"
ordered(logBox); logBox.Parent = statsBody; corner(logBox, 6)
local logPad = Instance.new("UIPadding"); logPad.PaddingLeft = UDim.new(0, 8); logPad.PaddingTop = UDim.new(0, 6); logPad.Parent = logBox

section(statsBody, "Control")
button(statsBody, "Reset stats", function()
    S.casts, S.catches, S.credits = 0, 0, 0; log("stats reset")
end)

local hideKey = nil
section(settingsBody, "Interface")
local captureHideKey = keybind(settingsBody, "Hide / show UI key", hideKey, function(k)
    hideKey = k
    log("hide UI key: "..(k and k.Name or "none"))
end)
local keyHint = label(settingsBody, "Esc = cancel, Backspace = clear")
keyHint.TextColor3 = COL_MUTED; keyHint.TextSize = 12

section(settingsBody, "Script")
button(settingsBody, "Unload script", function() getgenv().AutoFishCleanup() end)

local uiKeyConn = UIS.InputBegan:Connect(function(input, gpe)
    if captureHideKey(input) then return end
    if gpe or not hideKey then return end
    if input.KeyCode == hideKey then main.Visible = not main.Visible end
end)

local sessionStart = tick()
task.spawn(function()
    while getgenv().AutoFishRunning do
        local elapsed = math.max(tick() - sessionStart, 1)
        local rate = S.catches / (elapsed / 60)
        lCasts.Text   = "Casts: "..S.casts
        lCatches.Text = "Catches: "..S.catches
        lCred.Text    = ("Credits earned: $%d"):format(S.credits)
        lRate.Text    = ("Catch rate: %.1f / min"):format(rate)
        lSess.Text    = S.sessionActive and ("Session: ACTIVE ("..(sessionId or ""):sub(1,8)..")") or "Session: idle"
        local readyIn = castReadyIn()
        if not cfg.autoFish then
            lNext.Text = "Next cast: auto-fish off"
        elseif sessionId or not readyIn then
            lNext.Text = "Next cast: after this fish"
        else
            local wait = math.max(readyIn, nextCastAt - tick(), 0)
            lNext.Text = wait > 0 and ("Next cast: in %.1fs"):format(wait) or "Next cast: now"
        end
        local prog = S.sessionActive and (S.progress or 0) or 0
        lProg.Text    = ("Progress: %d%%"):format(math.floor(prog * 100))
        lReels.Text   = "Reel frames driven: "..(S.reelFrames or 0)
        lLast.Text    = "Last event: "..tostring(S.lastMsg)
        local body = ""
        for i = 1, math.min(#S.log, 12) do body = body .. S.log[i] .. "\n" end
        if body == "" then body = "(no events yet)" end
        logBox.Text = body
        task.wait(0.5)
    end
end)

closeBtn.MouseButton1Click:Connect(function() getgenv().AutoFishCleanup() end)

getgenv().AutoFishCleanup = function()
    getgenv().AutoFishRunning = false
    cfg.autoFish = false
    if fishingConn then pcall(function() fishingConn:Disconnect() end) end
    if hotkeyConn  then pcall(function() hotkeyConn:Disconnect()  end) end
    if uiKeyConn   then pcall(function() uiKeyConn:Disconnect()   end) end
    for _, c in ipairs(uiConns) do pcall(function() c:Disconnect() end) end
    pcall(function() RunService:UnbindFromRenderStep(REEL_BIND) end)
    if beginMinigame then pcall(debug.setupvalue, beginMinigame, UPV_REELING, false) end
    if screen then pcall(function() screen:Destroy() end) end
end
