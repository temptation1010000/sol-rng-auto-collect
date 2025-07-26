-- Sol's RNG 自动收集挂机脚本（适用于Xeno执行器）
-- 自动收集所有带有ProximityPrompt且ActionText为"Pick up"的物品
-- 支持一键开始/暂停

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HRP = Character:WaitForChild("HumanoidRootPart")
local PathfindingService = game:GetService("PathfindingService")

-- GUI
local gui = Instance.new("ScreenGui")
local frame = Instance.new("Frame")
local startBtn = Instance.new("TextButton")
local statusLabel = Instance.new("TextLabel")

gui.Name = "SolRNG_AutoCollect_GUI"
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

frame.Parent = gui
frame.Size = UDim2.new(0, 200, 0, 100)
frame.Position = UDim2.new(0, 20, 0, 100)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0

startBtn.Parent = frame
startBtn.Size = UDim2.new(0, 160, 0, 40)
startBtn.Position = UDim2.new(0, 20, 0, 20)
startBtn.Text = "开始挂机"
startBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 255)
startBtn.TextColor3 = Color3.new(1,1,1)
startBtn.Font = Enum.Font.SourceSansBold
startBtn.TextSize = 22

statusLabel.Parent = frame
statusLabel.Size = UDim2.new(1, 0, 0, 30)
statusLabel.Position = UDim2.new(0, 0, 1, -30)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.new(1,1,1)
statusLabel.Font = Enum.Font.SourceSans
statusLabel.TextSize = 18
statusLabel.Text = "状态：已暂停"

local running = false
local collecting = false
local skippedItems = {} -- 已跳过的不可达物品黑名单
local lastCleanTime = tick() -- 上次清理黑名单的时间

local function findAllPickups()
    local pickups = {}
    local function scan(obj)
        for _, child in ipairs(obj:GetChildren()) do
            if child:IsA("ProximityPrompt") and child.ActionText == "Pick up" and child.Enabled then
                table.insert(pickups, child)
            end
            scan(child)
        end
    end
    scan(Workspace)
    return pickups
end

local function smartMoveTo(targetPos)
    if not Character or not Character:FindFirstChild("Humanoid") or not HRP then return false end
    local humanoid = Character:FindFirstChild("Humanoid")
    local path = PathfindingService:CreatePath()
    local waypoints
    local currentWaypointIndex
    local reached = false
    local blocked = false
    local pathBlockedConn, moveToFinishedConn

    local function followPath()
        path:ComputeAsync(HRP.Position, targetPos)
        waypoints = {}
        if path.Status == Enum.PathStatus.Success then
            waypoints = path:GetWaypoints()
            currentWaypointIndex = 1
            humanoid:MoveTo(waypoints[currentWaypointIndex].Position)
        else
            print("路径不可达，跳过本次收集，Status:", path.Status.Name)
            reached = true
        end
    end

    local function onWaypointReached(reachedFlag)
        if not running then return end
        if reachedFlag and currentWaypointIndex < #waypoints then
            currentWaypointIndex = currentWaypointIndex + 1
            if waypoints[currentWaypointIndex].Action == Enum.PathWaypointAction.Jump then
                print("准备跳跃到路径点", currentWaypointIndex, waypoints[currentWaypointIndex].Position)
                local jumpStart = tick()
                while humanoid.FloorMaterial ~= Enum.Material.Air and tick() - jumpStart < 1 do
                    humanoid.Jump = true
                    wait(0.05)
                end
                print("Jump信号已持续发送，当前FloorMaterial:", humanoid.FloorMaterial.Name, "当前State:", humanoid:GetState().Name)
            end
            humanoid:MoveTo(waypoints[currentWaypointIndex].Position)
        else
            reached = true
        end
    end

    local function onPathBlocked(blockedWaypointIndex)
        if blockedWaypointIndex > currentWaypointIndex then
            followPath()
        end
    end

    pathBlockedConn = path.Blocked:Connect(onPathBlocked)
    moveToFinishedConn = humanoid.MoveToFinished:Connect(onWaypointReached)

    followPath()

    local t = 0
    while not reached and t < 15 and running do
        wait(0.2)
        t = t + 0.2
    end

    if pathBlockedConn then pathBlockedConn:Disconnect() end
    if moveToFinishedConn then moveToFinishedConn:Disconnect() end

    -- 返回是否成功（路径可达且未超时）
    return path.Status == Enum.PathStatus.Success and reached
end

local function safeFirePrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        fireproximityprompt(prompt)
    else
        -- 兼容部分执行器
        pcall(function()
            prompt:InputHoldBegin()
            wait(0.2)
            prompt:InputHoldEnd()
        end)
    end
end

local function findNearestPickup()
    local pickups = findAllPickups()
    if #pickups == 0 then return nil end
    local nearestPrompt, nearestDist, nearestPart = nil, math.huge, nil
    for _, prompt in ipairs(pickups) do
        local part = prompt.Parent:IsA("BasePart") and prompt.Parent or (prompt.Parent.PrimaryPart or prompt.Parent:FindFirstChildWhichIsA("BasePart"))
        if part then
            -- 检查是否在黑名单中（使用位置坐标作为唯一标识）
            local pos = part.Position
            local itemKey = string.format("%.1f_%.1f_%.1f", pos.X, pos.Y, pos.Z)
            if not skippedItems[itemKey] then
                local dist = (HRP.Position - part.Position).Magnitude
                if dist < nearestDist then
                    nearestPrompt = prompt
                    nearestDist = dist
                    nearestPart = part
                end
            end
        end
    end
    return nearestPrompt, nearestPart
end

local function collectAll()
    if collecting then return end
    collecting = true
    while running do
        -- 每5分钟清理一次黑名单，防止物品位置变化后重新变得可达
        if tick() - lastCleanTime > 300 then
            skippedItems = {}
            lastCleanTime = tick()
            print("已清理不可达物品黑名单")
        end
        
        local prompt, part = findNearestPickup()
        if not prompt or not part then
            statusLabel.Text = "状态：等待物品生成..."
            wait(1)
        else
            if not running then break end
            statusLabel.Text = "状态：收集中..."
            local moved = smartMoveTo(part.Position)
            if not running then break end
            if not moved then
                -- 将不可达物品加入黑名单（使用位置坐标作为唯一标识）
                local pos = part.Position
                local itemKey = string.format("%.1f_%.1f_%.1f", pos.X, pos.Y, pos.Z)
                skippedItems[itemKey] = true
                print("寻路失败，已将物品加入黑名单:", part.Name or part.Parent.Name, "位置:", itemKey)
                statusLabel.Text = "状态：跳过不可达物品..."
                wait(0.5)
            else
                local success = false
                for i = 1, 6 do -- 1.2秒内尝试6次
                    if not running then break end
                    wait(0.2)
                    if (HRP.Position - part.Position).Magnitude > 10 then
                        smartMoveTo(part.Position)
                    end
                    safeFirePrompt(prompt)
                    if not prompt.Enabled then
                        success = true
                        break
                    end
                end
                wait(0.2)
            end
        end
        wait(0.2)
    end
    statusLabel.Text = "状态：已暂停"
    collecting = false
end

startBtn.MouseButton1Click:Connect(function()
    running = not running
    if running then
        startBtn.Text = "暂停挂机"
        statusLabel.Text = "状态：收集中..."
        collectAll()
    else
        startBtn.Text = "开始挂机"
        statusLabel.Text = "状态：已暂停"
    end
end)

-- 自动处理角色重生
LocalPlayer.CharacterAdded:Connect(function(char)
    Character = char
    HRP = char:WaitForChild("HumanoidRootPart")
end)

-- 关闭按钮
local closeBtn = Instance.new("TextButton")
closeBtn.Parent = frame
closeBtn.Size = UDim2.new(0, 30, 0, 30)
closeBtn.Position = UDim2.new(1, -35, 0, 5)
closeBtn.Text = "X"
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.TextSize = 20
closeBtn.MouseButton1Click:Connect(function()
    gui:Destroy()
    running = false
end)

-- 提示
print("Sol's RNG 自动收集挂机脚本已加载！点击界面按钮开始/暂停挂机。") 