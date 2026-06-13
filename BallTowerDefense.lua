local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local RS = game:GetService("ReplicatedStorage")
local NetserEvent = RS:WaitForChild("NetserEvent")
local Remotes = require(RS.Modules.RemoteEvents)

-- ══════════════════════════════
--     ПАПКА МАКРОСОВ
-- ══════════════════════════════
local FOLDER = "BTD_Macros"
pcall(function()
    if not isfolder(FOLDER) then makefolder(FOLDER) end
end)

-- ══════════════════════════════
--     UUID MAP
-- ══════════════════════════════
local uuidMap = {}
local nameMap = {}

local function loadUUIDs()
    local ok, raw = pcall(readfile, FOLDER.."/uuid_map.json")
    if ok and raw and #raw > 1 then
        pcall(function()
            local parsed = HttpService:JSONDecode(raw)
            for name, uuid in pairs(parsed) do
                uuidMap[name] = uuid
                nameMap[uuid] = name
            end
        end)
    end
end

local function saveUUIDs()
    pcall(writefile, FOLDER.."/uuid_map.json",
        HttpService:JSONEncode(uuidMap))
end

loadUUIDs()
print("[UUID] Загружено башен: "..
    (function() local c=0 for _ in pairs(uuidMap) do c+=1 end return c end)())

-- ══════════════════════════════
--     СЕРИАЛИЗАТОР
-- ══════════════════════════════
local function serialize(wireId, ...)
    local args = {...}
    local data = buffer.create(256)
    local cursor = 0

    local function alloc(n)
        while cursor+n > buffer.len(data) do
            local nb = buffer.create(buffer.len(data)*2)
            buffer.copy(nb, 0, data)
            data = nb
        end
    end

    local function writeValue(v)
        local t = typeof(v)
        if t == "number" then
            alloc(9)
            buffer.writeu8(data, cursor, 1)
            buffer.writef64(data, cursor+1, v)
            cursor += 9
        elseif t == "string" then
            local len = #v
            alloc(len+5)
            buffer.writeu8(data, cursor, 2)
            buffer.writeu32(data, cursor+1, len)
            buffer.writestring(data, cursor+5, v)
            cursor += len+5
        elseif t == "Vector3" then
            alloc(13)
            buffer.writeu8(data, cursor, 3)
            buffer.writef32(data, cursor+1, v.X)
            buffer.writef32(data, cursor+5, v.Y)
            buffer.writef32(data, cursor+9, v.Z)
            cursor += 13
        elseif t == "boolean" then
            alloc(2)
            buffer.writeu8(data, cursor, 12)
            buffer.writeu8(data, cursor+1, v and 1 or 0)
            cursor += 2
        elseif v == nil then
            alloc(1)
            buffer.writeu8(data, cursor, 6)
            cursor += 1
        end
    end

    alloc(3)
    buffer.writeu16(data, cursor, wireId)
    buffer.writeu8(data, cursor+2, #args)
    cursor += 3
    for _, v in ipairs(args) do writeValue(v) end

    local result = buffer.create(cursor)
    buffer.copy(result, 0, data, 0, cursor)
    return result
end

local function sendToServer(wireId, ...)
    local data = serialize(wireId, ...)
    NetserEvent:FireServer({ data=data, references={} })
end

-- ══════════════════════════════
--     СОСТОЯНИЕ
-- ══════════════════════════════
local recording     = false
local playing       = false
local recActions    = {}
local DELAY_PLACE   = 0.8
local DELAY_UPGRADE = 0.4
local DELAY_WAVE    = 0.2
local waveCounter   = 0

-- Маппинг facade_id → entity_id (присваивается сервером)
local facadeToEntity = {}
-- При воспроизведении: порядковый номер → entity_id
local spawnOrderToEntity = {}
local spawnOrderCounter = 0

-- ══════════════════════════════
--     GUI ИГРЫ
-- ══════════════════════════════
local MainGui = PlayerGui:WaitForChild("MainGui")
local Info    = MainGui:WaitForChild("Info")

local NameLabel = nil
for _, v in ipairs(Info:GetDescendants()) do
    if v:IsA("TextLabel") and v.Name == "Label" then
        NameLabel = v break
    end
end

local SkipBtn = MainGui
    :WaitForChild("Clipping")
    :WaitForChild("Main")
    :WaitForChild("checkmark")

-- ══════════════════════════════
--     ИМЯ БАШНИ
-- ══════════════════════════════
local lastTowerName = nil
if NameLabel then
    NameLabel:GetPropertyChangedSignal("Text"):Connect(function()
        local txt = NameLabel.Text
        if txt and txt ~= "" then lastTowerName = txt end
    end)
end

local function getTowerName()
    if NameLabel then
        local txt = NameLabel.Text
        if txt and txt ~= "" then return txt end
    end
    return lastTowerName
end

-- ══════════════════════════════
--     ДЕСЕРИАЛИЗАТОР
-- ══════════════════════════════
local function deserialize(buf, refs)
    local cursor = 0
    local references = refs or {}
    local function readValue()
        if cursor+1 > buffer.len(buf) then return nil end
        local t = buffer.readu8(buf, cursor) cursor+=1
        if t==1 then local v=buffer.readf64(buf,cursor) cursor+=8 return v
        elseif t==2 then local len=buffer.readu32(buf,cursor) cursor+=4 local s=buffer.readstring(buf,cursor,len) cursor+=len return s
        elseif t==3 then local x=buffer.readf32(buf,cursor) local y=buffer.readf32(buf,cursor+4) local z=buffer.readf32(buf,cursor+8) cursor+=12 return Vector3.new(x,y,z)
        elseif t==6 then return nil
        elseif t==10 then local idx=buffer.readu16(buf,cursor) cursor+=2 return references[idx]
        elseif t==12 then local v=buffer.readu8(buf,cursor)==1 cursor+=1 return v end
        return nil
    end
    local results = {}
    while cursor < buffer.len(buf) do
        if cursor+3 > buffer.len(buf) then break end
        local wireId = buffer.readu16(buf,cursor)
        local argCount = buffer.readu8(buf,cursor+2)
        cursor+=3
        local args = {}
        for i=1,argCount do args[i]=readValue() end
        table.insert(results, {wireId=wireId, args=args})
    end
    return results
end

-- ══════════════════════════════
--     ПОДПИСКА НА SendUnbufferedEvent
--     Через callbacks напрямую
-- ══════════════════════════════
local unbufferedCallbacks = Remotes.SendUnbufferedEvent.callbacks
if unbufferedCallbacks then
    table.insert(unbufferedCallbacks, function(data)
        if type(data) ~= "table" then return end

        if data.kind == "add_tower" then
            local entityId   = data.entity_id
            local facadeId   = data.spawn_facade_id
            local towerName  = data.spawn_kind_name
            local uuid       = data.spawn_item_id

            -- Сохраняем facade → entity маппинг
            if facadeId and entityId then
                facadeToEntity[facadeId] = entityId
                print("[S→C] add_tower: "..tostring(towerName)
                    .." entity_id="..tostring(entityId)
                    .." facade="..tostring(facadeId))
            end

            -- Сохраняем UUID ↔ name
            if towerName and uuid and not uuidMap[towerName] then
                uuidMap[towerName] = uuid
                nameMap[uuid] = towerName
                saveUUIDs()
                print("[UUID] Сохранено: "..towerName.." → "..uuid)
            end
        end
    end)
    print("[OK] SendUnbufferedEvent подключён через callbacks!")
else
    warn("[WARN] callbacks не найден в SendUnbufferedEvent!")
end

-- ══════════════════════════════
--     СНИФФЕР (клиент → сервер)
-- ══════════════════════════════
local pendingFacade = nil  -- facade_id последнего спавна

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()

    if method == "FireServer" and self == NetserEvent then
        local packet = select(1, ...)
        if type(packet) == "table" and packet.data then
            local refs = {}
            if packet.references then
                for _, pair in ipairs(packet.references) do
                    refs[pair[1]] = pair[2]
                end
            end
            local ok, results = pcall(deserialize, packet.data, refs)
            if ok and results then
                for _, event in ipairs(results) do

                    -- Спавн башни
                    if event.wireId == 31 and event.args[1] then
                        local uuid     = event.args[1]
                        local pos      = event.args[2]
                        local rotation = event.args[3] or 0
                        local facade   = event.args[4]
                        local name     = getTowerName() or nameMap[uuid] or uuid

                        pendingFacade = facade
                        print("[REC] PLACE pending facade="..tostring(facade))

                        if recording then
                            -- Ждём entity_id от сервера через facadeToEntity
                            task.spawn(function()
                                local entityId = nil
                                local timeout = tick() + 3
                                while tick() < timeout do
                                    entityId = facadeToEntity[facade]
                                    if entityId then break end
                                    task.wait(0.05)
                                end

                                if not entityId then
                                    warn("[REC] entity_id не получен для "..tostring(facade))
                                    return
                                end

                                table.insert(recActions, {
                                    action    = "place",
                                    tower     = name,
                                    uuid      = uuid,
                                    entity_id = entityId,
                                    facade_id = facade,
                                    x = pos.X, y = pos.Y, z = pos.Z,
                                    rotation  = rotation,
                                })
                                print("[REC] PLACE '"..name
                                    .."' entity_id="..entityId)
                            end)
                        end

                    -- Апгрейд
                    elseif event.wireId == 35 and event.args[1] then
                        if recording then
                            local entityId = event.args[1]
                            local tier     = event.args[2]
                            local name     = getTowerName() or "entity_"..entityId
                            table.insert(recActions, {
                                action    = "upgrade",
                                tower     = name,
                                entity_id = entityId,
                                tier      = tier,
                            })
                            print("[REC] UPGRADE entity_id="..entityId.." tier="..tostring(tier))
                        end

                    -- Продажа
                    elseif event.wireId == 17 and event.args[1] then
                        if recording then
                            local entityId = event.args[1]
                            table.insert(recActions, {
                                action    = "sell",
                                entity_id = entityId,
                            })
                            print("[REC] SELL entity_id="..entityId)
                        end
                    end
                end
            end
        end
    end

    return oldNamecall(self, ...)
end)

-- ══════════════════════════════
--     СКИП ВОЛНЫ
-- ══════════════════════════════
SkipBtn.MouseButton1Click:Connect(function()
    if recording then
        waveCounter += 1
        table.insert(recActions, {
            action = "skip",
            wave   = waveCounter,
        })
        print("[REC] SKIP WAVE "..waveCounter)
    end
end)

-- ══════════════════════════════
--     ВОСПРОИЗВЕДЕНИЕ
-- ══════════════════════════════
-- При воспроизведении маппим порядок спавна → новый entity_id
local replayFacadeToEntity = {}
local replaySpawnOrder = {}  -- порядок спавна по entity_id из записи
local replaySpawnCount = 0

-- Подписываемся на add_tower при воспроизведении
if unbufferedCallbacks then
    table.insert(unbufferedCallbacks, function(data)
        if not playing then return end
        if type(data) == "table" and data.kind == "add_tower" then
            local entityId = data.entity_id
            local facade   = data.spawn_facade_id
            if facade and entityId then
                replayFacadeToEntity[facade] = entityId
                print("[REPLAY] Новый entity_id="..entityId.." facade="..facade)
            end
        end
    end)
end

local function resolveUUID(action)
    local uuid = action.uuid
    if uuid and uuid:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
        return uuid
    end
    return uuidMap[action.tower]
end

local function playMacro(actions, onStatus)
    if playing then return end
    playing = true
    replayFacadeToEntity = {}
    replaySpawnOrder = {}
    replaySpawnCount = 0

    -- Строим маппинг: старый entity_id → порядковый номер спавна
    local oldEntityToOrder = {}
    local spawnIndex = 0
    for _, action in ipairs(actions) do
        if action.action == "place" then
            spawnIndex += 1
            oldEntityToOrder[action.entity_id] = spawnIndex
        end
    end

    -- Маппинг: порядковый номер → новый entity_id (заполняется при воспроизведении)
    local orderToNewEntity = {}
    local pendingFacades = {}  -- порядковый номер → facade_id нового спавна

    task.spawn(function()
        local actionIndex = 0
        for _, action in ipairs(actions) do
            if not playing then break end
            actionIndex += 1
            onStatus(actionIndex.."/"..#actions)

            if action.action == "place" then
                local uuid = resolveUUID(action)
                if not uuid then
                    print("[SKIP] UUID не найден: "..tostring(action.tower))
                else
                    local pos       = Vector3.new(action.x, action.y, action.z)
                    local newFacade = "{"..HttpService:GenerateGUID(false).."}"
                    local order     = oldEntityToOrder[action.entity_id]

                    pendingFacades[order] = newFacade

                    sendToServer(31, uuid, pos, action.rotation or 0, newFacade)

                    -- Ждём новый entity_id от сервера
                    task.spawn(function()
                        local timeout = tick() + 3
                        while tick() < timeout do
                            local newEntityId = replayFacadeToEntity[newFacade]
                            if newEntityId then
                                orderToNewEntity[order] = newEntityId
                                print("[REPLAY] order="..order.." → new entity_id="..newEntityId)
                                break
                            end
                            task.wait(0.05)
                        end
                    end)

                    task.wait(DELAY_PLACE)
                end

            elseif action.action == "upgrade" then
                -- Получаем новый entity_id по порядку спавна
                local order = oldEntityToOrder[action.entity_id]
                local newEntityId = order and orderToNewEntity[order]

                if newEntityId then
                    sendToServer(35, newEntityId, action.tier)
                    print("[REPLAY] UPGRADE new_entity_id="..newEntityId.." tier="..tostring(action.tier))
                else
                    warn("[REPLAY] Нет нового entity_id для order="..tostring(order))
                end
                task.wait(DELAY_UPGRADE)

            elseif action.action == "sell" then
                local order = oldEntityToOrder[action.entity_id]
                local newEntityId = order and orderToNewEntity[order]

                if newEntityId then
                    sendToServer(17, newEntityId)
                    print("[REPLAY] SELL new_entity_id="..newEntityId)
                else
                    warn("[REPLAY] Нет нового entity_id для sell")
                end
                task.wait(DELAY_UPGRADE)

            elseif action.action == "skip" then
                pcall(function()
                    SkipBtn.MouseButton1Click:Fire()
                end)
                task.wait(DELAY_WAVE)
            end
        end

        playing = false
        onStatus("✓ Готово!")
        print("[REPLAY] Завершено!")
    end)
end

-- ══════════════════════════════
--     СПИСОК МАКРОСОВ
-- ══════════════════════════════
local function getMacros()
    local list = {}
    local ok, files = pcall(listfiles, FOLDER)
    if not ok then return list end
    for _, path in ipairs(files) do
        if path:match("%.json$") and not path:match("uuid_map") then
            local name = path:match("([^/\\]+)%.json$") or path
            table.insert(list, {name=name, path=path})
        end
    end
    return list
end

-- ══════════════════════════════
--     GUI
-- ══════════════════════════════
local sg = Instance.new("ScreenGui")
sg.Name = "BTDMacroV8"
sg.ResetOnSpawn = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,300,0,530)
frame.Position = UDim2.new(0,20,0.5,-265)
frame.BackgroundColor3 = Color3.fromRGB(12,12,20)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = sg
Instance.new("UICorner",frame).CornerRadius=UDim.new(0,12)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,38)
title.BackgroundColor3 = Color3.fromRGB(20,18,35)
title.TextColor3 = Color3.fromRGB(190,165,255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Text = "⚔  BTD Macro v8"
title.BorderSizePixel = 0
title.Parent = frame
Instance.new("UICorner",title).CornerRadius=UDim.new(0,12)

local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1,-20,0,20)
statusLbl.Position = UDim2.new(0,10,0,42)
statusLbl.BackgroundTransparency = 1
statusLbl.TextColor3 = Color3.fromRGB(130,130,160)
statusLbl.Font = Enum.Font.Gotham
statusLbl.TextSize = 11
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.Text = "Готов"
statusLbl.Parent = frame

local function setStatus(txt, col)
    statusLbl.Text = txt
    statusLbl.TextColor3 = col or Color3.fromRGB(130,130,160)
end

local towerLbl = Instance.new("TextLabel")
towerLbl.Size = UDim2.new(1,-20,0,20)
towerLbl.Position = UDim2.new(0,10,0,64)
towerLbl.BackgroundTransparency = 1
towerLbl.TextColor3 = Color3.fromRGB(100,220,140)
towerLbl.Font = Enum.Font.GothamBold
towerLbl.TextSize = 11
towerLbl.TextXAlignment = Enum.TextXAlignment.Left
towerLbl.Text = "Башня: —"
towerLbl.Parent = frame

task.spawn(function()
    while true do
        task.wait(0.2)
        local n = getTowerName()
        towerLbl.Text = "Башня: "..(n or "—")
        towerLbl.TextColor3 = n
            and Color3.fromRGB(100,220,140)
            or  Color3.fromRGB(130,130,160)
    end
end)

local function sep(y)
    local s=Instance.new("Frame")
    s.Size=UDim2.new(1,-20,0,1)
    s.Position=UDim2.new(0,10,0,y)
    s.BackgroundColor3=Color3.fromRGB(35,30,60)
    s.BorderSizePixel=0
    s.Parent=frame
end

local function makeLbl(txt,y)
    local l=Instance.new("TextLabel")
    l.Size=UDim2.new(1,-20,0,16)
    l.Position=UDim2.new(0,10,0,y)
    l.BackgroundTransparency=1
    l.TextColor3=Color3.fromRGB(120,100,170)
    l.Font=Enum.Font.GothamBold
    l.TextSize=10
    l.TextXAlignment=Enum.TextXAlignment.Left
    l.Text=txt
    l.Parent=frame
end

local function makeCtrl(y,getV,setV,minV,maxV,step)
    local bg=Instance.new("Frame")
    bg.Size=UDim2.new(1,-20,0,24)
    bg.Position=UDim2.new(0,10,0,y)
    bg.BackgroundColor3=Color3.fromRGB(22,20,38)
    bg.BorderSizePixel=0
    bg.Parent=frame
    Instance.new("UICorner",bg).CornerRadius=UDim.new(0,6)
    local vl=Instance.new("TextLabel")
    vl.Size=UDim2.new(1,-100,1,0)
    vl.Position=UDim2.new(0,50,0,0)
    vl.BackgroundTransparency=1
    vl.TextColor3=Color3.fromRGB(200,200,220)
    vl.Font=Enum.Font.GothamBold
    vl.TextSize=11
    vl.Text=string.format("%.1f",getV()).."s"
    vl.Parent=bg
    local bm=Instance.new("TextButton")
    bm.Size=UDim2.new(0,44,1,0)
    bm.BackgroundColor3=Color3.fromRGB(65,25,25)
    bm.TextColor3=Color3.fromRGB(255,120,120)
    bm.Font=Enum.Font.GothamBold
    bm.TextSize=14 bm.Text="−"
    bm.BorderSizePixel=0
    bm.Parent=bg
    Instance.new("UICorner",bm).CornerRadius=UDim.new(0,6)
    local bp=Instance.new("TextButton")
    bp.Size=UDim2.new(0,44,1,0)
    bp.Position=UDim2.new(1,-44,0,0)
    bp.BackgroundColor3=Color3.fromRGB(22,60,28)
    bp.TextColor3=Color3.fromRGB(120,255,140)
    bp.Font=Enum.Font.GothamBold
    bp.TextSize=14 bp.Text="+"
    bp.BorderSizePixel=0
    bp.Parent=bg
    Instance.new("UICorner",bp).CornerRadius=UDim.new(0,6)
    bm.MouseButton1Click:Connect(function()
        setV(math.max(minV,math.round((getV()-step)*10)/10))
        vl.Text=string.format("%.1f",getV()).."s"
    end)
    bp.MouseButton1Click:Connect(function()
        setV(math.min(maxV,math.round((getV()+step)*10)/10))
        vl.Text=string.format("%.1f",getV()).."s"
    end)
end

sep(88)
makeLbl("Задержка постановки:",93)
makeCtrl(111,function() return DELAY_PLACE end,function(v) DELAY_PLACE=v end,0.1,5.0,0.1)
makeLbl("Задержка апгрейда:",140)
makeCtrl(158,function() return DELAY_UPGRADE end,function(v) DELAY_UPGRADE=v end,0.1,3.0,0.1)

sep(188)
makeLbl("ЗАПИСЬ МАКРОСА:",194)

local nameBox=Instance.new("TextBox")
nameBox.Size=UDim2.new(0.58,-5,0,26)
nameBox.Position=UDim2.new(0,10,0,212)
nameBox.BackgroundColor3=Color3.fromRGB(20,18,36)
nameBox.TextColor3=Color3.fromRGB(200,200,220)
nameBox.Font=Enum.Font.Gotham
nameBox.TextSize=11
nameBox.PlaceholderText="Название макроса"
nameBox.PlaceholderColor3=Color3.fromRGB(70,65,100)
nameBox.Text=""
nameBox.BorderSizePixel=0
nameBox.Parent=frame
Instance.new("UICorner",nameBox).CornerRadius=UDim.new(0,6)
Instance.new("UIPadding",nameBox).PaddingLeft=UDim.new(0,6)

local recBtn=Instance.new("TextButton")
recBtn.Size=UDim2.new(0.42,-5,0,26)
recBtn.Position=UDim2.new(0.58,0,0,212)
recBtn.BackgroundColor3=Color3.fromRGB(100,22,22)
recBtn.TextColor3=Color3.fromRGB(255,100,100)
recBtn.Font=Enum.Font.GothamBold
recBtn.TextSize=11
recBtn.Text="⏺ ЗАПИСЬ"
recBtn.BorderSizePixel=0
recBtn.Parent=frame
Instance.new("UICorner",recBtn).CornerRadius=UDim.new(0,6)

sep(244)
makeLbl("МАКРОСЫ:",250)

local scroll=Instance.new("ScrollingFrame")
scroll.Size=UDim2.new(1,-20,0,180)
scroll.Position=UDim2.new(0,10,0,268)
scroll.BackgroundColor3=Color3.fromRGB(16,14,28)
scroll.BorderSizePixel=0
scroll.ScrollBarThickness=3
scroll.ScrollBarImageColor3=Color3.fromRGB(90,70,160)
scroll.Parent=frame
Instance.new("UICorner",scroll).CornerRadius=UDim.new(0,8)
local layout=Instance.new("UIListLayout")
layout.Padding=UDim.new(0,4)
layout.Parent=scroll
Instance.new("UIPadding",scroll).PaddingTop=UDim.new(0,4)

local refreshList
refreshList = function()
    for _,c in ipairs(scroll:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end
    local macros=getMacros()
    if #macros==0 then
        local el=Instance.new("TextLabel")
        el.Size=UDim2.new(1,0,0,28)
        el.BackgroundTransparency=1
        el.TextColor3=Color3.fromRGB(70,65,100)
        el.Font=Enum.Font.Gotham
        el.TextSize=11
        el.Text="Нет макросов — запиши первый!"
        el.Parent=scroll
        scroll.CanvasSize=UDim2.new(0,0,0,32)
        return
    end
    for i,macro in ipairs(macros) do
        local row=Instance.new("Frame")
        row.Size=UDim2.new(1,-8,0,34)
        row.BackgroundColor3=Color3.fromRGB(20,18,36)
        row.BorderSizePixel=0
        row.LayoutOrder=i
        row.Parent=scroll
        Instance.new("UICorner",row).CornerRadius=UDim.new(0,7)
        local nl=Instance.new("TextLabel")
        nl.Size=UDim2.new(1,-84,1,0)
        nl.BackgroundTransparency=1
        nl.TextColor3=Color3.fromRGB(195,190,230)
        nl.Font=Enum.Font.Gotham
        nl.TextSize=11
        nl.TextXAlignment=Enum.TextXAlignment.Left
        nl.Text="  📋 "..macro.name
        nl.Parent=row
        local pb=Instance.new("TextButton")
        pb.Size=UDim2.new(0,34,0,24)
        pb.Position=UDim2.new(1,-78,0.5,-12)
        pb.BackgroundColor3=Color3.fromRGB(22,65,28)
        pb.TextColor3=Color3.fromRGB(120,255,140)
        pb.Font=Enum.Font.GothamBold
        pb.TextSize=14 pb.Text="▶"
        pb.BorderSizePixel=0
        pb.Parent=row
        Instance.new("UICorner",pb).CornerRadius=UDim.new(0,6)
        local db=Instance.new("TextButton")
        db.Size=UDim2.new(0,34,0,24)
        db.Position=UDim2.new(1,-40,0.5,-12)
        db.BackgroundColor3=Color3.fromRGB(65,18,18)
        db.TextColor3=Color3.fromRGB(255,100,100)
        db.Font=Enum.Font.GothamBold
        db.TextSize=13 db.Text="🗑"
        db.BorderSizePixel=0
        db.Parent=row
        Instance.new("UICorner",db).CornerRadius=UDim.new(0,6)
        local m=macro
        pb.MouseButton1Click:Connect(function()
            if playing then
                setStatus("⚠ Уже запущено!",Color3.fromRGB(255,200,80))
                return
            end
            local ok,raw=pcall(readfile,m.path)
            if not ok then
                setStatus("✗ Файл не найден",Color3.fromRGB(255,80,80))
                return
            end
            local ok2,acts=pcall(function()
                return HttpService:JSONDecode(raw)
            end)
            if not ok2 then
                setStatus("✗ Ошибка JSON",Color3.fromRGB(255,80,80))
                return
            end
            pb.BackgroundColor3=Color3.fromRGB(40,90,45)
            task.spawn(function()
                playMacro(acts,function(s)
                    setStatus("▶ "..m.name..": "..s,Color3.fromRGB(255,200,80))
                end)
                pb.BackgroundColor3=Color3.fromRGB(22,65,28)
            end)
        end)
        db.MouseButton1Click:Connect(function()
            pcall(delfile,m.path)
            setStatus("🗑 Удалено: "..m.name,Color3.fromRGB(180,100,100))
            refreshList()
        end)
    end
    scroll.CanvasSize=UDim2.new(0,0,0,#macros*38+8)
end

recBtn.MouseButton1Click:Connect(function()
    recording = not recording
    if recording then
        recActions  = {}
        waveCounter = 0
        facadeToEntity = {}
        recBtn.Text="⏹ СТОП"
        recBtn.BackgroundColor3=Color3.fromRGB(25,80,30)
        recBtn.TextColor3=Color3.fromRGB(120,255,140)
        setStatus("⏺ Запись идёт...",Color3.fromRGB(255,80,80))
    else
        local macroName=nameBox.Text~="" and nameBox.Text or "macro_"..os.time()
        local path=FOLDER.."/"..macroName..".json"
        pcall(writefile,path,HttpService:JSONEncode(recActions))
        recBtn.Text="⏺ ЗАПИСЬ"
        recBtn.BackgroundColor3=Color3.fromRGB(100,22,22)
        recBtn.TextColor3=Color3.fromRGB(255,100,100)
        nameBox.Text=""
        setStatus("✓ "..macroName.." ("..#recActions.." действий)",
            Color3.fromRGB(120,255,140))
        refreshList()
    end
end)

local stopBtn=Instance.new("TextButton")
stopBtn.Size=UDim2.new(1,-20,0,26)
stopBtn.Position=UDim2.new(0,10,1,-32)
stopBtn.BackgroundColor3=Color3.fromRGB(75,18,18)
stopBtn.TextColor3=Color3.fromRGB(255,100,100)
stopBtn.Font=Enum.Font.GothamBold
stopBtn.TextSize=12
stopBtn.Text="■  СТОП"
stopBtn.BorderSizePixel=0
stopBtn.Parent=frame
Instance.new("UICorner",stopBtn).CornerRadius=UDim.new(0,7)

stopBtn.MouseButton1Click:Connect(function()
    playing=false
    recording=false
    recBtn.Text="⏺ ЗАПИСЬ"
    recBtn.BackgroundColor3=Color3.fromRGB(100,22,22)
    recBtn.TextColor3=Color3.fromRGB(255,100,100)
    setStatus("■ Остановлено",Color3.fromRGB(255,100,100))
end)

refreshList()
print("[OK] BTD Macro v8 загружен!")
print("[OK] SendUnbufferedEvent: callbacks подключены")
print("[UUID] Ball → "..tostring(uuidMap["Ball"]))
