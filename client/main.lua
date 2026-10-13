-- client/main.lua

ESX = nil
CreateThread(function()
    while ESX == nil do
        local ok, obj = pcall(function() return exports["es_extended"]:getSharedObject() end)
        if ok and obj then
            ESX = obj
        else
            TriggerEvent('esx:getSharedObject', function(obj2) ESX = obj2 end)
            Wait(500)
        end
    end
end)

-- Calculate GTA heading (0=N, 90=E, clockwise) from direction vector
local function HeadingFromVector(dx, dy)
    local h = math.deg(math.atan2(dy, dx))
    h = 90.0 - h
    if h < 0.0 then h = h + 360.0 end
    return h
end

local state

local function GetFreePassengerSeat(vehicle)
    if vehicle == 0 then return -1 end
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
    if not maxPassengers or maxPassengers < 0 then return -1 end
    for i = 0, maxPassengers - 1 do
        if IsVehicleSeatFree(vehicle, i) then
            return i
        end
    end
    return -1
end

local function GetPedSeatInVehicle(ped, vehicle)
    if vehicle == 0 then return nil end
    if GetPedInVehicleSeat(vehicle, -1) == ped then
        return -1
    end
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
    if not maxPassengers or maxPassengers < 0 then return nil end
    for i = 0, maxPassengers - 1 do
        if GetPedInVehicleSeat(vehicle, i) == ped then
            return i
        end
    end
    return nil
end

local function ForcePlayerIntoPassengerSeat(player, vehicle, preferredSeat)
    if vehicle == 0 then return false end

    local currentVehicle = GetVehiclePedIsIn(player, false)
    if currentVehicle == vehicle then
        local currentSeat = GetPedSeatInVehicle(player, vehicle)
        if currentSeat and currentSeat >= 0 then
            return true, currentSeat
        end
    end

    local seat = -1
    if preferredSeat ~= nil and preferredSeat >= 0 then
        local occupant = GetPedInVehicleSeat(vehicle, preferredSeat)
        if occupant == 0 or occupant == player then
            seat = preferredSeat
        end
    end
    if seat == -1 then
        seat = GetFreePassengerSeat(vehicle)
    end
    if seat == -1 then
        return false
    end

    SetPedIntoVehicle(player, vehicle, seat)
    return true, seat
end

local function Trim(text)
    if not text then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function StripRoleplay(text)
    if not text then return "" end
    text = string.gsub(text, "```[%w]*", "")
    text = string.gsub(text, "```", "")
    local trimmed = Trim(text)
    if trimmed:sub(1, 1) == "{" then
        local ok, data = pcall(json.decode, trimmed)
        if ok and type(data) == "table" and type(data.speech) == "string" and data.speech ~= "" then
            text = data.speech
        end
    end
    text = string.gsub(text, "%b()", "")
    text = string.gsub(text, "%b**", "")
    text = string.gsub(text, "%s+", " ")
    return Trim(text)
end

local function ShowNpcPrivateChatMessage(text, npcName)
    npcName = npcName or (state and state.currentNpcData and state.currentNpcData.name) or "NPC"
    text = StripRoleplay(text)
    TriggerEvent('chat:addMessage', {
        color = { 120, 200, 255 },
        multiline = true,
        args = { string.format("[PM] %s", npcName), text }
    })
end

local function ShowNpcBubble(npcEntity, text)
    if not DoesEntityExist(npcEntity) then return end
    local coords = GetEntityCoords(npcEntity)
    local _, screenX, screenY = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z + 1.0)
    text = StripRoleplay(text)
    SetTimeout(3000, function()
        SendNUIMessage({ action = 'show_text', text = text, x = screenX * 100, y = screenY * 100 })
        local textDuration = math.max(5000, #text * 60)
        SetTimeout(textDuration, function() SendNUIMessage({ action = 'hide_text' }) end)
    end)
end

local function BuildNpcNameToEntity()
    local map = {}
    if state.currentNpc and DoesEntityExist(state.currentNpc) then
        local mainName = state.currentNpcData and state.currentNpcData.name or ""
        if mainName ~= "" then map[mainName] = state.currentNpc end
    end
    for _, mn in ipairs(state.multiNpcs) do
        if DoesEntityExist(mn) then
            local mnData = state.multiNpcData[mn]
            if mnData and mnData.name then map[mnData.name] = mn end
        end
    end
    return map
end

local animalModelHashes = nil
function IsAnimalPed(npc)
    if not animalModelHashes then
        local animals = {"a_c_chop","a_c_cat_01","a_c_boar","a_c_coyote","a_c_cow","a_c_deer","a_c_hen","a_c_husky","a_c_mtlion","a_c_pig","a_c_poodle","a_c_pug","a_c_rabbit","a_c_rat","a_c_retriever","a_c_rottweiler","a_c_shepherd","a_c_westy","a_c_fish"}
        animalModelHashes = {}
        for _, name in ipairs(animals) do
            animalModelHashes[GetHashKey(name)] = true
        end
    end
    return animalModelHashes[GetEntityModel(npc)] == true
end

state = {
    isInteracting = false,
    isAwaitingAiResponse = false,
    npcIsThinking = false,
    currentNpc = nil,
    currentNpcData = {},
    multiNpcs = {},
    multiNpcData = {},
    conversationHistory = {},
    isFollowing = false,
    explicitFollow = false,
    followNpc = nil,
    isCompanion = false,
    companionVehicle = 0,
    wasInVehicle = false,
    companionCombatTarget = nil,
    pendingContextChange = nil,
    lastContext = {},
    isInVehicle = false,
    isAiSuppressed = false,
    lastInterior = 0,
    isAnimal = false,
    lastHealth = 200,
    lastInteractionTime = 0,
    npcIsDriver = false,
    driverNpc = nil,
    driverPassengerSeat = nil,
    drivingMode = nil,
    drivingSpeed = nil,
    drivingTarget = nil,
    drivingTargetName = nil,
    voiceResponseEnabled = true,
    antiStuckTimer = 0,
    antiStuckReversing = false,
    helpMeOut = false,
    isVoiceListening = false,
    voicePttHeld = false,
    isLeading = false,
    leadDestination = nil,
    lastEngineAction = nil,
    lastEngineTarget = nil,
    lastScenarioType = nil,
    currentRoutine = 'WANDER',
    targetLocation = nil
}

-- Push-to-talk via FiveM key binding system (Esc > Settings > Key Bindings > NPC Voice Chat)
RegisterCommand('+npc_ptt', function()
    print("^3[NPCI DEBUG] +npc_ptt fired | isInteracting: " .. tostring(state.isInteracting) .. " | isAnimal: " .. tostring(state.isAnimal) .. " | isAwaitingAiResponse: " .. tostring(state.isAwaitingAiResponse))
    if state.isInteracting and not state.isAnimal and not state.isAwaitingAiResponse then
        local pData = ESX.GetPlayerData()
        local allowed = false
        if pData and pData.group then
            local g = string.lower(pData.group)
            if g == "admin" or g == "superadmin" or g == "mod" or g == "associate" or g == "elite" then
                allowed = true
            end
        end
        if not allowed then
            ESX.ShowNotification("~r~Voice chat is only available for ~y~Admin~s~, ~y~Associate~s~, and ~y~Elite~s~ roles.", "error")
            return
        end
        state.voicePttHeld = true
        SendNUIMessage({ action = 'ptt_start' })
        print("^3[NPCI DEBUG] Sent ptt_start to NUI^7")
    end
end, false)

RegisterCommand('-npc_ptt', function()
    print("^3[NPCI DEBUG] -npc_ptt fired | voicePttHeld: " .. tostring(state.voicePttHeld))
    if state.voicePttHeld then
        state.voicePttHeld = false
        state.npcIsThinking = true
        SendNUIMessage({ action = 'ptt_stop' })
        print("^3[NPCI DEBUG] Sent ptt_stop to NUI^7")
    end
end, false)

RegisterKeyMapping('+npc_ptt', 'NPC Voice Chat (Push-to-Talk)', 'keyboard', 'n')

-- Active AI Peds tracking table: Tracks all mission-entity AI peds for life loop
ActiveAIPeds = {}
-- Awakened peds from server (re-awakened souls)
AwakenedPeds = {}

-- Mute GTA V native audio for AI-activated peds
function MutePedNativeAudio(ped)
    if not DoesEntityExist(ped) then return end
    SetAmbientVoiceName(ped, "NONE")
    StopPedSpeaking(ped, true)
    DisablePedPainAudio(ped, true)
end

-- Get a ped entity by its state bag ID (iterates ActiveAIPeds)
function GetPedByStateBagId(stateBagId)
    for ped, data in pairs(ActiveAIPeds) do
        if DoesEntityExist(ped) and data.stateBagId == stateBagId then
            return ped
        end
    end
    return nil
end

-- Check if ped has an active task running
function IsPedOnTask(ped)
    if not DoesEntityExist(ped) then return false end
    return not IsPedWalking(ped) and not IsPedRunning(ped) and not IsPedStopped(ped)
end

-- Get coordinates for a named location from Config
function GetLocationCoords(locationName)
    if not Config.LocationCoords or not locationName then return nil end
    local loc = Config.LocationCoords[locationName]
    if loc then
        return vector3(loc.x, loc.y, loc.z), loc.radius or 3.0
    end
    return nil, nil
end

local function LockNpcAsDriver(npc, vehicle, player)
    SetPedCanBeDraggedOut(npc, false)
    SetPedStayInVehicleWhenJacked(npc, true)
    SetDriverAbility(npc, 1.0)
    SetDriverAggressiveness(npc, 0.0)
    local group = GetPedGroupIndex(player)
    if group == 0 or group == 255 then
        group = GetPedGroupIndex(npc)
        if group == 0 or group == 255 then
            group = 0
        end
    end
    SetPedAsGroupMember(npc, group)
    SetPedAsGroupLeader(player, group)
    SetGroupSeparationRange(group, 1.9, 0.8)
    SetPedCanTeleportToGroupLeader(npc, group, false)
end

local function DismissCompanionPed(npcPed)
    if not npcPed or not DoesEntityExist(npcPed) then return end
    RemovePedFromGroup(npcPed)
    SetPedRelationshipGroupHash(npcPed, GetHashKey("CIVMALE"))
    ClearPedTasks(npcPed)
end

local function ResetDriverState()
    if state.driverNpc and DoesEntityExist(state.driverNpc) then
        SetPedCanBeDraggedOut(state.driverNpc, true)
        SetPedStayInVehicleWhenJacked(state.driverNpc, false)
        DismissCompanionPed(state.driverNpc)
    end
    state.npcIsDriver = false
    state.driverNpc = nil
    state.driverPassengerSeat = nil
    state.drivingMode = nil
    state.drivingSpeed = nil
    state.drivingTarget = nil
    state.drivingTargetName = nil
    state.antiStuckTimer = 0
    state.antiStuckReversing = false
end

local function IsCompanionExtrasEnabled()
    return Config and Config.EnableCompanionExtras == true
end

local function IsDrivingExtrasEnabled()
    return IsCompanionExtrasEnabled() and Config and Config.EnableNpcDrivingExtras == true
end

local function IsSubscriptionLockedCommand(cmd)
    -- companion / NPC-driving commands removed in this build
    return false
end

local function IsAdminOrPremium()
    local pData = ESX.GetPlayerData()
    if pData and pData.group then
        local g = string.lower(pData.group)
        if g == "admin" or g == "superadmin" or g == "mod" or g == "premium" then
            return true
        end
    end
    if IsPlayerAceAllowed(PlayerId(), "npci.multi") then
        return true
    end
    return false
end

local function AddMultiNpcToConversation(npc)
    if not state.isInteracting then return false end
    if not DoesEntityExist(npc) or IsPedAPlayer(npc) or IsEntityDead(npc) then return false end
    if npc == state.currentNpc then return false end
    for _, existing in ipairs(state.multiNpcs) do
        if existing == npc then return false end
    end

    if DoesEntityExist(npc) then
        local netId = NetworkGetNetworkIdFromEntity(npc)
        TriggerServerEvent('npci_server:startedInteracting', netId)
    end
    
    -- Take control and mute native audio for multi-NPCs too
    SetEntityAsMissionEntity(npc, true, true)
    MutePedNativeAudio(npc)
    
    SetBlockingOfNonTemporaryEvents(npc, true)
    SetPedFleeAttributes(npc, 0, 0)
    ClearPedTasksImmediately(npc)
    TaskStandStill(npc, -1)
    SetEntityVelocity(npc, 0.0, 0.0, 0.0)
    local pCoords = GetEntityCoords(PlayerPedId())
    local nCoords = GetEntityCoords(npc)
    SetEntityHeading(npc, HeadingFromVector(pCoords.x - nCoords.x, pCoords.y - nCoords.y))
    TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)

    local name = Entity(npc).state.npci_name
    local role = Entity(npc).state.npci_role
    local isNewNpc = false
    if not name or not role then
        isNewNpc = true
        local coords = GetEntityCoords(npc)
        local model = GetEntityModel(npc)
        role = DetectNpcRole(npc)
        local isStationaryRole = (role == "Shop Personal" or role == "Guard" or role == "EMS" or role == "Firefighter" or role == "Inmate" or role == "Police" or role == "Meth Cook" or role == "Valet")
        local stateBagId
        if isStationaryRole then
            stateBagId = string.format("static_%d_%.0f_%.0f_%.0f", model, math.floor(coords.x / 5.0 + 0.5) * 5, math.floor(coords.y / 5.0 + 0.5) * 5, math.floor(coords.z / 5.0 + 0.5) * 5)
        else
            stateBagId = string.format("roaming_%d_%d", model, math.random(100000, 999999))
        end
        local maleNames = {"Trevor","Michael","Franklin","Lamar","Jimmy","Wade","Ron","Brad","Dave","Steve","Devin","Martin","Solomon","Floyd","Simeon","Gerald","Lester","Dom","Tony","Luis","Niko","Roman","Brucie","Yusuf","Johnny","Clay","Terry","Packie","Derrick","Francis","Bernie","Manny","Playboy X","Dwayne","Ray","Phil","Little Jacob","Badman","CJ","Sweet","Ryder","Big Smoke","Cesar","Madd Dogg","OG Loc","The Truth","Zero","Wu Zi Mu","Toreno","Jethro","Dwaine","Maccer","Kent Paul","Ken Rosenberg","Salvatore","Kenji","Donald Love","Ray Machowski","Joey","Toni Cipriani","Claude","Miguel","8-Ball","El Burro","King Courtney","D-Ice"}
        local femaleNames = {"Tracey","Amanda","Molly","Patricia","Tanisha","Tonya","Ashley","Denise","Karen","Paige","Kendl","Catalina","Asuka","Maria","Elizabeta","Mallorie","Kate","Michelle","Lola","Carmen","Kiki","Alex","Grace","Liz","Elena","Misty","Luisa"}
        if IsPedMale(npc) then name = maleNames[math.random(#maleNames)] else name = femaleNames[math.random(#femaleNames)] end
        Entity(npc).state:set('npci_id', stateBagId, true)
        Entity(npc).state:set('npci_role', role, true)
        Entity(npc).state:set('npci_name', name, true)
        Entity(npc).state:set('npci_model_hash', GetEntityModel(npc), true)
    end
    local gender = IsPedMale(npc) and "Male" or "Female"
    local moods = {"rude", "funny", "offensive", "aggressive", "paranoid", "friendly", "stoned", "sarcastic", "anxious", "dismissive"}
    local mood = moods[math.random(#moods)]

    table.insert(state.multiNpcs, npc)
    state.multiNpcData[npc] = { name = name, role = role, gender = gender, mood = mood }
    if isNewNpc then Entity(npc).state:set('npci_mood', mood, true) end

    ESX.ShowNotification(string.format("~g~[Multi]~s~ %s (%s) joined the conversation.", name, role), "success")
    return true
end

local VehicleColors = {
    [0]="Black",[1]="Graphite Black",[2]="Steel Gray",[3]="Silver",[4]="Blue Steel",
    [5]="Dark Blue",[6]="Blue",[7]="Bright Blue",[8]="Lime Green",[9]="Racing Green",
    [10]="Dark Green",[11]="Green",[12]="Forest Green",[13]="Midnight Blue",
    [14]="Midnight Purple",[15]="Dark Purple",[16]="Purple",[17]="Bright Purple",
    [18]="Red",[19]="Dark Red",[20]="Bright Red",[21]="Wine Red",[22]="Orange",
    [23]="Bright Orange",[24]="Yellow",[25]="Bright Yellow",[26]="Gold",
    [27]="Bronze",[28]="Cream",[29]="Ice White",[30]="White",[31]="Frost White",
    [32]="Beige",[33]="Brown",[34]="Dark Brown",[35]="Light Brown",[36]="Pink",
    [37]="Bright Pink",[38]="Salmon",[39]="Titanium",[40]="Light Blue",
    [41]="Dark Steel",[42]="Champagne",[43]="Gray",[44]="Light Gray",[45]="Matte Black",
    [46]="Matte Gray",[47]="Matte Dark Blue",[48]="Matte Red",[49]="Matte Orange",
    [50]="Matte Yellow",[51]="Matte Lime Green",[52]="Olive Army Green",
    [53]="Matte Green",[54]="Matte Forest Green",[55]="Matte Purple",
    [56]="Matte Dark Purple",[57]="Matte Wine Red",[58]="Matte Pink",
    [59]="Matte Brown",[60]="Matte Tan",[61]="Chrome",[62]="Brushed Steel",
    [63]="Brushed Black Steel",[64]="Brushed Aluminum",[65]="Pure Gold",
    [66]="Brushed Gold",[67]="Space Traveler",[68]="Midnight Silver",
    [69]="Midnight Chrome",[70]="Dark Chrome",[71]="Secret Gold",
    [72]="Galaxy Dark Blue",[73]="Galaxy Light Blue",[74]="Galaxy Red",
    [75]="Galaxy Purple",[76]="Anodized Copper",[77]="Anodized Silver",
    [78]="Anodized Gold",[79]="Anodized Blue",[80]="Anodized Red",
    [81]="Anodized Purple",[82]="Anodized Green",[83]="Anodized Lime",
    [84]="Anodized Bronze",[85]="Anodized Black",[86]="Anodized Rose Gold",
    [87]="Anodized Steel",[88]="Anodized Champagne",[89]="Anodized Brown",
    [90]="Hot Pink",[91]="Matte Hot Pink",[92]="Matte Mint Green",
    [93]="Matte Lime",[94]="Matte Sea Foam",[95]="Matte Midnight Blue",
    [96]="Matte Midnight Purple",[97]="Matte Midnight Red",
    [98]="Matte Midnight Green",[99]="Matte Midnight Black",
    [100]="Matte Midnight Gray",[101]="Matte Midnight Silver",
    [102]="Matte Midnight Champagne",[103]="Matte Midnight Brown",
    [110]="Util Bright Orange",[111]="Util Bright Blue",[112]="Util Bright Green",
    [113]="Util Bright Red",[114]="Util Bright Yellow",[115]="Util Bright White",
    [116]="Util Bright Silver",[117]="Util Bright Gray",[118]="Util Bright Black",
    [119]="Util Bright Pink",[120]="Util Bright Purple",[121]="Util Bright Cream"
}

local WeaponNames = {
    [GetHashKey("WEAPON_UNARMED")]="Unarmed",[GetHashKey("WEAPON_KNIFE")]="Knife",
    [GetHashKey("WEAPON_NIGHTSTICK")]="Nightstick",[GetHashKey("WEAPON_HAMMER")]="Hammer",
    [GetHashKey("WEAPON_BAT")]="Baseball Bat",[GetHashKey("WEAPON_CROWBAR")]="Crowbar",
    [GetHashKey("WEAPON_GOLFCLUB")]="Golf Club",[GetHashKey("WEAPON_BOTTLE")]="Broken Bottle",
    [GetHashKey("WEAPON_DAGGER")]="Antique Dagger",[GetHashKey("WEAPON_HATCHET")]="Hatchet",
    [GetHashKey("WEAPON_MACHETE")]="Machete",[GetHashKey("WEAPON_SWITCHBLADE")]="Switchblade",
    [GetHashKey("WEAPON_BATTLEAXE")]="Battle Axe",[GetHashKey("WEAPON_POOLCUE")]="Pool Cue",
    [GetHashKey("WEAPON_WRENCH")]="Wrench",[GetHashKey("WEAPON_PISTOL")]="Pistol",
    [GetHashKey("WEAPON_COMBATPISTOL")]="Combat Pistol",[GetHashKey("WEAPON_APPISTOL")]="AP Pistol",
    [GetHashKey("WEAPON_STUNGUN")]="Stun Gun",[GetHashKey("WEAPON_PISTOL50")]="Pistol .50",
    [GetHashKey("WEAPON_SNSPISTOL")]="SNS Pistol",[GetHashKey("WEAPON_HEAVYPISTOL")]="Heavy Pistol",
    [GetHashKey("WEAPON_VINTAGEPISTOL")]="Vintage Pistol",[GetHashKey("WEAPON_MICROSMG")]="Micro SMG",
    [GetHashKey("WEAPON_SMG")]="SMG",[GetHashKey("WEAPON_ASSAULTSMG")]="Assault SMG",
    [GetHashKey("WEAPON_MG")]="MG",[GetHashKey("WEAPON_COMBATMG")]="Combat MG",
    [GetHashKey("WEAPON_COMBATPDW")]="Combat PDW",[GetHashKey("WEAPON_ASSAULTRIFLE")]="Assault Rifle",
    [GetHashKey("WEAPON_CARBINERIFLE")]="Carbine Rifle",[GetHashKey("WEAPON_ADVANCEDRIFLE")]="Advanced Rifle",
    [GetHashKey("WEAPON_SPECIALCARBINE")]="Special Carbine",[GetHashKey("WEAPON_BULLPUPRIFLE")]="Bullpup Rifle",
    [GetHashKey("WEAPON_COMPACTRIFLE")]="Compact Rifle",[GetHashKey("WEAPON_PUMPSHOTGUN")]="Pump Shotgun",
    [GetHashKey("WEAPON_SAWNOFFSHOTGUN")]="Sawed-Off Shotgun",[GetHashKey("WEAPON_ASSAULTSHOTGUN")]="Assault Shotgun",
    [GetHashKey("WEAPON_BULLPUPSHOTGUN")]="Bullpup Shotgun",[GetHashKey("WEAPON_DBSHOTGUN")]="Double Barrel Shotgun",
    [GetHashKey("WEAPON_SNIPERRIFLE")]="Sniper Rifle",[GetHashKey("WEAPON_HEAVYSNIPER")]="Heavy Sniper",
    [GetHashKey("WEAPON_GRENADELAUNCHER")]="Grenade Launcher",[GetHashKey("WEAPON_RPG")]="RPG",
    [GetHashKey("WEAPON_STINGER")]="Stinger",[GetHashKey("WEAPON_MINIGUN")]="Minigun",
    [GetHashKey("WEAPON_GRENADE")]="Grenade",[GetHashKey("WEAPON_STICKYBOMB")]="Sticky Bomb",
    [GetHashKey("WEAPON_MOLOTOV")]="Molotov",[GetHashKey("WEAPON_PIPEBOMB")]="Pipe Bomb"
}

local WeatherTypes = {"CLEAR","EXTRASUNNY","CLOUDS","SMOG","FOGGY","OVERCAST","RAIN","THUNDER","CLEARING","NEUTRAL","SNOW","BLIZZARD","SNOWLIGHT","XMAS","HALLOWEEN"}

local WeatherHashes = {
    [-1750460733] = "EXTRASUNNY", [916166204] = "CLEAR", [-1530254782] = "CLOUDS",
    [334657083] = "SMOG", [-1075124813] = "FOGGY", [1007683603] = "OVERCAST",
    [1840358669] = "RAIN", [1786574496] = "THUNDER", [82156029] = "CLEARING",
    [-1535403339] = "NEUTRAL", [1776889851] = "SNOW", [-111422566] = "BLIZZARD",
    [1756394836] = "SNOWLIGHT", [-1188354373] = "XMAS", [182091745] = "HALLOWEEN"
}

local RadioStations = {
    [0]="Los Santos Rock Radio",[1]="Non-Stop-Pop FM",[2]="Radio Los Santos",
    [3]="Channel X",[4]="West Coast Talk Radio",[5]="Rebel Radio",
    [6]="Soulwax FM",[7]="East Los FM",[8]="West Coast Classics",
    [9]="Blue Ark",[10]="Worldwide FM",[11]="FlyLo FM",
    [12]="The Lowdown 91.1",[13]="The Lab",[14]="Radio Mirror Park",
    [15]="Space 103.2",[16]="Vinewood Boulevard Radio",[17]="Blonded Los Santos"
}

local zones = {
    AIRP = "Los Santos International Airport",
    ALAMO = "Alamo Sea",
    ALTA = "Alta",
    AMU = "Amethyst",
    BANHAMC = "Banham Canyon",
    BANNING = "Banning",
    BAYTRE = "Baytree Canyon",
    BEACH = "Vespucci Beach",
    BHAMCA = "Banham Canyon Drive",
    BRADP = "Braddock Pass",
    BRADT = "Braddock Tunnel",
    BURTON = "Burton",
    CALAFB = "Calafia Bridge",
    CANNY = "Raton Canyon",
    CCREAK = "Cassidy Creek",
    CHAMH = "Chamberlain Hills",
    CHIL = "Vinewood Hills",
    CHU = "Chumash",
    COSO = "Cove",
    DELBE = "Del Perro Beach",
    DELPE = "Del Perro",
    DELSOL = "La Puerta",
    DOWNT = "Downtown",
    DTVINE = "Downtown Vinewood",
    EAST_V = "East Vinewood",
    EBU = "Elysian Island",
    ELBURR = "El Burro Heights",
    ELYSIAN = "Elysian Island",
    GALCO = "Galileo Park",
    GOLF = "GWC and Golfing Society",
    GRAPES = "Grapeseed",
    GREATC = "Great Chaparral",
    HARMO = "Harmony",
    HAWICK = "Hawick",
    HORS = "Vinewood Racetrack",
    HUMLAB = "Humane Labs and Research",
    JACOB = "Jacob",
    JACOBST = "Jacob Street",
    KOREAT = "Little Seoul",
    LACTR = "Land Act Reservoir",
    LAGO = "Lago Zancudo",
    LDAM = "Land Act Dam",
    LEGSQU = "Legion Square",
    LMESA = "La Mesa",
    LOSPUER = "La Puerta",
    MIRR = "Mirror Park",
    MISTY = "Mount Chiliad",
    MOUNTI = "Mount Gordo",
    MOUPL = "Mount Joseph",
    MURRI = "Murrieta Heights",
    NCHU = "North Chumash",
    NOOSE = "N.O.O.S.E. Headquarters",
    OCEANA = "Pacific Ocean",
    PALCOV = "Paleto Cove",
    PALETO = "Paleto Bay",
    PALFOR = "Paleto Forest",
    PALHIGH = "Palomino Highlands",
    PALMGRP = "Palmer-Taylor Power Station",
    PBLIHP = "Pacific Bluffs",
    PBOX = "Pillbox Hill",
    RANCHO = "Rancho",
    RGLEN = "Richman Glen",
    RICHM = "Richman",
    ROCKF = "Rockford Hills",
    RTONC = "Raton Canyon",
    SANAND = "San Andreas",
    SANCHIA = "San Chianski Mountain Range",
    SANDY = "Sandy Shores",
    SKID = "Mission Row",
    SLAB = "Stab City",
    STAD = "Maze Bank Arena",
    STRAW = "Strawberry",
    TATAMO = "Tataviam Mountains",
    TERMINA = "Terminal",
    TEXTI = "Textile City",
    TONGVAH = "Tongva Hills",
    TONGVAV = "Tongva Valley",
    VCANA = "Vespucci Canals",
    VESP = "Vespucci",
    VINE = "Vinewood",
    WINDF = "Ron Alternates Wind Farm",
    WVINE = "West Vinewood",
    ZANCUDO = "Fort Zancudo",
    ZP_ORT = "Port of South Los Santos",
    ZQ_UAR = "Davis Quartz"
}

function DetectNpcRole(npc)
    local stateRole = Entity(npc).state.npci_role
    if stateRole then return stateRole end

    local model = GetEntityModel(npc)
    
    -- Dynamic chef/linecook/chemist detection (Hotdog Guy near cart, Meth Cook elsewhere)
    if model == GetHashKey("s_m_y_chef_01") or model == GetHashKey("s_m_m_linecook") or model == GetHashKey("ig_chef") then
        local coords = GetEntityCoords(npc)
        local cart = GetClosestObjectOfType(coords.x, coords.y, coords.z, 5.0, GetHashKey("prop_hotdog_01"), false, false, false)
        if cart == 0 then
            cart = GetClosestObjectOfType(coords.x, coords.y, coords.z, 5.0, GetHashKey("prop_hotdog_02"), false, false, false)
        end
        if cart ~= 0 then
            return "Hotdog Guy"
        else
            return "Meth Cook"
        end
    end
    
    -- Club staff / Bahama Mamas specific models
    local clubModelHashes = {
        [GetHashKey("s_f_y_clubbar_01")] = "Bartender",
        [GetHashKey("s_m_y_clubbar_01")] = "Bartender",
        [GetHashKey("u_f_y_dancerave_01")] = "Dancer",
        [GetHashKey("ig_sol")] = "Club DJ",
        [GetHashKey("a_m_y_clubcust_01")] = "Club-goer",
        [GetHashKey("a_m_y_clubcust_02")] = "Club-goer",
        [GetHashKey("a_m_y_clubcust_03")] = "Club-goer",
        [GetHashKey("a_f_y_clubcust_01")] = "Club-goer",
        [GetHashKey("a_f_y_clubcust_02")] = "Club-goer",
        [GetHashKey("a_f_y_clubcust_03")] = "Club-goer",
    }
    local clubRole = clubModelHashes[model]
    if clubRole then
        return clubRole
    end
    
    local modelRoles = {
        -- Police / Sheriffs
        [GetHashKey("s_m_y_cop_01")] = "Police",
        [GetHashKey("s_f_y_cop_01")] = "Police",
        [GetHashKey("s_m_y_hwaycop_01")] = "Police",
        [GetHashKey("s_m_y_sheriff_01")] = "Police",
        [GetHashKey("s_f_y_sheriff_01")] = "Police",
        [GetHashKey("s_m_y_ranger_01")] = "Police",
        [GetHashKey("s_f_y_ranger_01")] = "Police",
        [GetHashKey("s_m_y_swat_01")] = "Police",
        
        -- Guards / Security (Extremely robust list to ensure guard characters never get civilian fallback!)
        [GetHashKey("s_m_m_ciasec_01")] = "Guard",
        [GetHashKey("s_m_m_security_01")] = "Guard",
        [GetHashKey("s_m_m_armoured_01")] = "Guard",
        [GetHashKey("s_m_y_devinsec_01")] = "Guard",
        [GetHashKey("s_m_y_westsec_01")] = "Guard",
        [GetHashKey("s_m_m_prisguard_01")] = "Guard",
        [GetHashKey("s_m_y_prisguard_01")] = "Guard",
        [GetHashKey("s_m_m_highsec_01")] = "Guard",
        [GetHashKey("s_m_m_highsec_02")] = "Guard",
        [GetHashKey("s_m_y_blackops_01")] = "Guard",
        [GetHashKey("s_m_y_blackops_02")] = "Guard",
        [GetHashKey("s_m_y_blackops_03")] = "Guard",
        [GetHashKey("mp_m_securoguard_01")] = "Guard",
        [GetHashKey("u_m_m_jewelsec_01")] = "Guard",
        [GetHashKey("s_m_y_marine_01")] = "Guard",
        [GetHashKey("s_m_y_marine_02")] = "Guard",
        [GetHashKey("s_m_y_marine_03")] = "Guard",
        [GetHashKey("s_m_y_armymech_01")] = "Guard",
        [GetHashKey("g_m_y_mexgoon_02")] = "Guard",
        [GetHashKey("g_m_y_mexgoon_01")] = "Guard",
        [GetHashKey("g_m_y_mexgoon_03")] = "Guard",
        [GetHashKey("s_m_m_bouncer_01")] = "Guard",
        
        -- EMS / Fire
        [GetHashKey("s_m_y_paramedic_01")] = "EMS",
        [GetHashKey("s_f_y_scrubs_01")] = "EMS",
        [GetHashKey("s_m_y_fireman_01")] = "Firefighter",
        
        -- Inmates
        [GetHashKey("s_m_y_prisoner_01")] = "Inmate",
        [GetHashKey("s_m_y_prismuscl_01")] = "Inmate",
        [GetHashKey("u_m_y_prisoner_01")] = "Inmate",
        
        -- Builders / Construction
        [GetHashKey("s_m_y_construct_01")] = "Builder Guy",
        [GetHashKey("s_m_y_construct_02")] = "Builder Guy",
        
        -- Garbage Workers (New Group!)
        [GetHashKey("s_m_y_garbage")] = "Garbage Worker",
        
        -- Dock Workers (New Group!)
        [GetHashKey("s_m_m_dockwork_01")] = "Dock Worker",
        
        -- Drug Dealers (New Group!)
        [GetHashKey("s_m_y_dealer_01")] = "Drug Dealer",
        
        -- Valet / Doormen (New Group!)
        [GetHashKey("s_m_y_valet_01")] = "Valet",
        
        -- Airport Workers & Pilots (New Group!)
        [GetHashKey("s_m_y_airworker")] = "Airport Worker",
        [GetHashKey("s_m_m_pilot_01")] = "Airport Worker",
        [GetHashKey("s_m_y_pilot_01")] = "Airport Worker",
        
        -- Lifeguards (New Group!)
        [GetHashKey("s_m_y_lifegrd_01")] = "Lifeguard",
        [GetHashKey("s_f_y_lifegrd_01")] = "Lifeguard",
        
        -- Hotdog / Food guy / Chefs (Standard mapping for other chef peds)
        [GetHashKey("s_m_m_cntrybar_01")] = "Hotdog Guy",
        
        -- Homeless / Tramps
        [GetHashKey("u_m_y_homeless_01")] = "Homeless Person",
        [GetHashKey("a_m_o_soucent_02")] = "Homeless Person",
        [GetHashKey("a_m_o_soucent_03")] = "Homeless Person",
        [GetHashKey("a_m_m_tramp_01")] = "Homeless Person",
        [GetHashKey("a_m_m_trampbeac_01")] = "Homeless Person",
        
        -- Body Builders / Muscle
        [GetHashKey("a_m_y_musclbeac_01")] = "Body Builder",
        [GetHashKey("a_m_y_musclbeac_02")] = "Body Builder",
        [GetHashKey("u_m_y_baygor")] = "Body Builder",
        
        -- Junkies / Addicts (New Group!)
        [GetHashKey("u_m_y_proldrug_01")] = "Junkie",
        [GetHashKey("a_m_y_methhead_01")] = "Junkie",
        [GetHashKey("u_m_y_party_01")] = "Junkie",
        
        -- Bikers (The Lost MC - New Group!)
        [GetHashKey("g_m_y_lost_01")] = "Biker",
        [GetHashKey("g_m_y_lost_02")] = "Biker",
        [GetHashKey("g_m_y_lost_03")] = "Biker",
        [GetHashKey("g_f_y_lost_01")] = "Biker",
        
        -- Hikers / Outdoorsmen (New Group!)
        [GetHashKey("a_m_y_hiker_01")] = "Hiker",
        [GetHashKey("a_f_y_hiker_01")] = "Hiker",
        
        -- Golfers / Country Club Snobs (New Group!)
        [GetHashKey("a_m_m_golfer_01")] = "Golfer",
        [GetHashKey("a_f_m_golfer_01")] = "Golfer",
        [GetHashKey("a_m_y_golfer_01")] = "Golfer",
        
        -- Gangs - Vagos
        [GetHashKey("g_m_y_mexgang_01")] = "Vagos Gang Member",
        [GetHashKey("g_m_y_mexgoon_01")] = "Vagos Gang Member",
        [GetHashKey("g_m_y_mexgoon_02")] = "Vagos Gang Member",
        [GetHashKey("g_m_y_mexgoon_03")] = "Vagos Gang Member",
        
        -- Gangs - Grove Street (Families)
        [GetHashKey("g_m_y_famca_01")] = "Grove Street Gang Member",
        [GetHashKey("g_m_y_famdn_01")] = "Grove Street Gang Member",
        [GetHashKey("g_m_y_famfo_01")] = "Grove Street Gang Member",
        
        -- Gangs - Ballas
        [GetHashKey("g_m_y_ballaeast_01")] = "Ballas Gang Member",
        [GetHashKey("g_m_y_ballagoons_01")] = "Ballas Gang Member",
        [GetHashKey("g_m_y_ballasout_01")] = "Ballas Gang Member",
        
        -- Gangs - General / Street Punks
        [GetHashKey("g_m_y_strpunk_01")] = "Gang Member",
        [GetHashKey("g_m_y_strpunk_02")] = "Gang Member",
        [GetHashKey("g_m_y_korean_01")] = "Gang Member",
        [GetHashKey("g_m_y_korean_02")] = "Gang Member",
        [GetHashKey("g_m_y_azteca_01")] = "Gang Member",
        
        -- Sexy Peds
        [GetHashKey("s_f_y_stripper_01")] = "Sexy Ped",
        [GetHashKey("s_f_y_stripper_02")] = "Sexy Ped",
        [GetHashKey("a_f_y_beach_01")] = "Sexy Ped",
        [GetHashKey("a_f_y_fitness_01")] = "Sexy Ped",
        [GetHashKey("a_f_y_fitness_02")] = "Sexy Ped",
        [GetHashKey("a_f_y_bevhills_04")] = "Sexy Ped",
        [GetHashKey("a_f_y_bevhills_01")] = "Sexy Ped",
        [GetHashKey("a_f_y_bevhills_02")] = "Sexy Ped",
        
        -- Ugly Peds
        [GetHashKey("a_f_y_scrappy_01")] = "Ugly Ped",
        
        -- Rednecks / Hillbillies (New Group!)
        [GetHashKey("a_m_m_hillbilly_01")] = "Redneck",
        [GetHashKey("a_m_m_hillbilly_02")] = "Redneck",
        [GetHashKey("a_m_y_salton_01")] = "Redneck",
        [GetHashKey("a_m_o_salton_01")] = "Redneck",
        [GetHashKey("a_f_y_salton_01")] = "Redneck",
        
        -- Beachgoers / Surfers (New Group!)
        [GetHashKey("a_m_y_beach_01")] = "Beachgoer",
        [GetHashKey("a_m_y_beach_02")] = "Beachgoer",
        [GetHashKey("a_f_y_beach_02")] = "Beachgoer",
        
        -- Businessmen / Suits (New Group!)
        [GetHashKey("a_m_m_business_01")] = "Businessman",
        [GetHashKey("a_f_m_business_01")] = "Businessman",
        [GetHashKey("a_m_y_business_01")] = "Businessman",
        [GetHashKey("a_m_y_business_02")] = "Businessman",
        
        -- Hipsters (New Group!)
        [GetHashKey("a_m_y_hipster_01")] = "Hipster",
        [GetHashKey("a_m_y_hipster_02")] = "Hipster",
        [GetHashKey("a_f_y_hipster_01")] = "Hipster",
        [GetHashKey("a_f_y_hipster_02")] = "Hipster",
        [GetHashKey("a_f_y_hippie_01")] = "Hipster",
        
        -- Cultists / Altruists (New Group!)
        [GetHashKey("a_m_m_acult_01")] = "Cultist",
        [GetHashKey("a_m_y_acult_01")] = "Cultist",
        
        -- Athletes / Runners (New Group!)
        [GetHashKey("a_m_y_runner_01")] = "Athlete",
        [GetHashKey("a_f_y_runner_01")] = "Athlete",
        [GetHashKey("a_m_y_tennis_01")] = "Athlete",
        [GetHashKey("a_f_y_tennis_01")] = "Athlete",
        
        -- Shop Personal
        [GetHashKey("s_m_y_shopkeep_01")] = "Shop Personal",
        [GetHashKey("s_m_m_hairdress_01")] = "Shop Personal",
        [GetHashKey("s_m_m_ammucity_01")] = "Shop Personal",
        [GetHashKey("s_m_y_barman_01")] = "Shop Personal",
        [GetHashKey("s_f_y_sweatshop_01")] = "Shop Personal",
    }
    
    if modelRoles[model] then
        return modelRoles[model]
    end
    
    return "Civilian"
end

function GetStreetAndZone(coords)
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local streetName = GetStreetNameFromHashKey(streetHash) or "Unknown Street"
    local zoneKey = GetNameOfZone(coords.x, coords.y, coords.z)
    local zoneName = zones[zoneKey] or GetLabelText(zoneKey)
    if zoneName == "NULL" or zoneName == "" then
        zoneName = zoneKey or "Los Santos"
    end
    return string.format("%s, %s", streetName, zoneName)
end

function GetTargetNpc()
    local player = PlayerPedId()
    local _, entity = GetEntityPlayerIsFreeAimingAt(PlayerId())
    if entity and entity ~= 0 and IsEntityAPed(entity) and not IsPedAPlayer(entity) and not IsEntityDead(entity) then
        return entity
    end
    
    local pos = GetEntityCoords(player)
    local forward = GetEntityForwardVector(player)
    local target = pos + (forward * 4.0)
    local ray = StartShapeTestRay(pos.x, pos.y, pos.z, target.x, target.y, target.z, 12, player, 0)
    local _, hit, _, _, hitEntity = GetShapeTestResult(ray)
    if hit and hitEntity and hitEntity ~= 0 and IsEntityAPed(hitEntity) and not IsPedAPlayer(hitEntity) and not IsEntityDead(hitEntity) then
        return hitEntity
    end
    return nil
end

function UrlEncode(str)
    if not str then return "" end
    str = string.gsub(str, "\n", " ")
    return (string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "%%20"))
end

-- Comprehensive voice gender lookup (model_hash → "male"/"female").
-- Uses explicit hash tables for known models, falls back to IsPedMale.
local function GetVoiceGender(modelHash)
    local femaleModels = {
        [GetHashKey("a_f_o_eastsa_01")] = true, [GetHashKey("a_f_o_genstreet_01")] = true,
        [GetHashKey("a_f_o_ktown_01")] = true, [GetHashKey("a_f_o_ktown_02")] = true,
        [GetHashKey("a_f_o_prolhost_01")] = true, [GetHashKey("a_f_o_soucent_01")] = true,
        [GetHashKey("a_f_o_soucent_02")] = true,
        [GetHashKey("a_f_m_beach_01")] = true, [GetHashKey("a_f_m_beach_02")] = true,
        [GetHashKey("a_f_m_bodybuild_01")] = true,
        [GetHashKey("a_f_m_business_02")] = true,
        [GetHashKey("a_f_m_downtown_01")] = true,
        [GetHashKey("a_f_m_eastsa_01")] = true, [GetHashKey("a_f_m_eastsa_02")] = true,
        [GetHashKey("a_f_m_fatbla_01")] = true, [GetHashKey("a_f_m_fatcult_01")] = true,
        [GetHashKey("a_f_m_fatwhite_01")] = true,
        [GetHashKey("a_f_m_ktown_01")] = true, [GetHashKey("a_f_m_ktown_02")] = true,
        [GetHashKey("a_f_m_prolhost_01")] = true,
        [GetHashKey("a_f_m_salton_01")] = true,
        [GetHashKey("a_f_m_skidrow_01")] = true,
        [GetHashKey("a_f_m_soucent_01")] = true, [GetHashKey("a_f_m_soucent_02")] = true,
        [GetHashKey("a_f_m_soucentmc_01")] = true,
        [GetHashKey("a_f_m_tourist_01")] = true,
        [GetHashKey("a_f_m_tramp_01")] = true,
        [GetHashKey("a_f_m_trampbeac_01")] = true,
        [GetHashKey("a_f_y_beach_01")] = true, [GetHashKey("a_f_y_bevhills_01")] = true,
        [GetHashKey("a_f_y_bevhills_02")] = true, [GetHashKey("a_f_y_bevhills_03")] = true,
        [GetHashKey("a_f_y_bevhills_04")] = true,
        [GetHashKey("a_f_y_breath_01")] = true,
        [GetHashKey("a_f_y_business_01")] = true, [GetHashKey("a_f_y_business_02")] = true,
        [GetHashKey("a_f_y_business_03")] = true, [GetHashKey("a_f_y_business_04")] = true,
        [GetHashKey("a_f_y_carclub_01")] = true,
        [GetHashKey("a_f_y_clubcust_01")] = true, [GetHashKey("a_f_y_clubcust_02")] = true,
        [GetHashKey("a_f_y_clubcust_03")] = true,
        [GetHashKey("a_f_y_skater_01")] = true,
        [GetHashKey("a_f_y_soucent_01")] = true, [GetHashKey("a_f_y_soucent_02")] = true,
        [GetHashKey("a_f_y_soucent_03")] = true,
        [GetHashKey("a_f_y_tennis_01")] = true,
        [GetHashKey("a_f_y_topless_01")] = true, [GetHashKey("a_f_y_tourist_01")] = true,
        [GetHashKey("a_f_y_tramp_01")] = true,
        [GetHashKey("a_f_y_vinewood_01")] = true, [GetHashKey("a_f_y_vinewood_02")] = true,
        [GetHashKey("a_f_y_vinewood_03")] = true, [GetHashKey("a_f_y_vinewood_04")] = true,
        [GetHashKey("a_f_y_yoga_01")] = true,
        [GetHashKey("s_f_m_fembarber_01")] = true,
        [GetHashKey("s_f_m_maid_01")] = true,
        [GetHashKey("s_f_m_shop_high_01")] = true, [GetHashKey("s_f_m_shop_low_01")] = true,
        [GetHashKey("s_f_m_shop_mid_01")] = true,
        [GetHashKey("s_f_m_sweatshop_01")] = true,
        [GetHashKey("s_f_y_airhostess_01")] = true,
        [GetHashKey("s_f_y_bartender_01")] = true,
        [GetHashKey("s_f_y_baywatch_01")] = true,
        [GetHashKey("s_f_y_clubbar_01")] = true,
        [GetHashKey("s_f_y_cop_01")] = true,
        [GetHashKey("s_f_y_factory_01")] = true,
        [GetHashKey("s_f_y_hooker_01")] = true, [GetHashKey("s_f_y_hooker_02")] = true,
        [GetHashKey("s_f_y_hooker_03")] = true,
        [GetHashKey("s_f_y_migrant_01")] = true,
        [GetHashKey("s_f_y_movprem_01")] = true,
        [GetHashKey("s_f_y_scrubs_01")] = true,
        [GetHashKey("s_f_y_sheriff_01")] = true,
        [GetHashKey("s_f_y_shop_low_01")] = true,
        [GetHashKey("s_f_y_shop_mid_01")] = true, [GetHashKey("s_f_y_shop_high_01")] = true,
        [GetHashKey("s_f_y_stripper_01")] = true, [GetHashKey("s_f_y_stripper_02")] = true,
        [GetHashKey("s_f_y_sweatshop_01")] = true,
        [GetHashKey("s_f_y_waiter_01")] = true,
        [GetHashKey("u_f_m_corpse_01")] = true,
        [GetHashKey("u_f_m_miranda")] = true,
        [GetHashKey("u_f_m_promourn_01")] = true,
        [GetHashKey("u_f_o_moviestar_01")] = true,
        [GetHashKey("u_f_o_prolhost_01")] = true,
        [GetHashKey("u_f_y_bikerchic_01")] = true,
        [GetHashKey("u_f_y_comjane_01")] = true,
        [GetHashKey("u_f_y_corpse_01")] = true,
        [GetHashKey("u_f_y_dancerave_01")] = true,
        [GetHashKey("u_f_y_hotposh_01")] = true,
        [GetHashKey("u_f_y_roxy_01")] = true,
        [GetHashKey("u_f_y_stripper_01")] = true, [GetHashKey("u_f_y_stripper_02")] = true,
        [GetHashKey("u_f_y_stripper_03")] = true,
        [GetHashKey("u_f_y_suposto_01")] = true,
        [GetHashKey("mp_f_*")] = true, -- placeholder for MP female heads
    }
    -- All models with "f_" in their name are female (first letter after prefix)
    -- Models starting with a_f, s_f, u_f, mp_f, cs_f, ig_f
    local baseGender = IsPedMale(GetPlayerPed(PlayerId())) -- dummy call to verify native exists
    if femaleModels[modelHash] then return "female" end
    -- Fallback: check model name for f_ pattern
    -- IsPedMale returns false for female peds
    return "male"
end

local function DetectPedVoiceAge(modelHash, gender)
    local ELDERLY_FEMALE_HASHES = {
        [GetHashKey("a_f_o_genstreet_01")] = true, [GetHashKey("a_f_o_ktown_01")] = true,
        [GetHashKey("a_f_o_prolhost_01")] = true, [GetHashKey("a_f_o_soucent_01")] = true,
        [GetHashKey("a_f_o_soucent_02")] = true, [GetHashKey("a_f_o_eastsa_01")] = true,
        [GetHashKey("a_f_o_ktown_02")] = true,
    }
    local YOUNG_FEMALE_HASHES = {
        [GetHashKey("a_f_y_beach_01")] = true, [GetHashKey("a_f_y_bevhills_01")] = true,
        [GetHashKey("a_f_y_bevhills_02")] = true, [GetHashKey("a_f_y_bevhills_03")] = true,
        [GetHashKey("a_f_y_bevhills_04")] = true,
        [GetHashKey("a_f_y_clubcust_01")] = true, [GetHashKey("a_f_y_clubcust_02")] = true,
        [GetHashKey("a_f_y_clubcust_03")] = true,
        [GetHashKey("a_f_y_skater_01")] = true,
        [GetHashKey("a_f_y_vinewood_01")] = true, [GetHashKey("a_f_y_vinewood_02")] = true,
        [GetHashKey("a_f_y_vinewood_03")] = true, [GetHashKey("a_f_y_vinewood_04")] = true,
        [GetHashKey("u_f_y_dancerave_01")] = true,
    }
    local ELDERLY_MALE_HASHES = {
        [GetHashKey("a_m_o_beach_01")] = true, [GetHashKey("a_m_o_genstreet_01")] = true,
        [GetHashKey("a_m_o_ktown_01")] = true, [GetHashKey("a_m_o_salton_01")] = true,
        [GetHashKey("a_m_o_soucent_01")] = true, [GetHashKey("a_m_o_soucent_02")] = true,
        [GetHashKey("a_m_o_soucent_03")] = true,
        [GetHashKey("a_m_m_business_01")] = true,
    }
    local YOUNG_MALE_HASHES = {
        [GetHashKey("a_m_y_beach_01")] = true, [GetHashKey("a_m_y_beach_02")] = true,
        [GetHashKey("a_m_y_beach_03")] = true,
        [GetHashKey("a_m_y_bevhills_01")] = true, [GetHashKey("a_m_y_bevhills_02")] = true,
        [GetHashKey("a_m_y_breath_01")] = true,
        [GetHashKey("a_m_y_business_01")] = true, [GetHashKey("a_m_y_business_02")] = true,
        [GetHashKey("a_m_y_business_03")] = true,
        [GetHashKey("a_m_y_clubcust_01")] = true, [GetHashKey("a_m_y_clubcust_02")] = true,
        [GetHashKey("a_m_y_clubcust_03")] = true,
        [GetHashKey("a_m_y_cyclist_01")] = true,
        [GetHashKey("a_m_y_dhill_01")] = true,
        [GetHashKey("a_m_y_downtown_01")] = true,
        [GetHashKey("a_m_y_eastsa_01")] = true,
        [GetHashKey("a_m_y_fitness_01")] = true, [GetHashKey("a_m_y_fitness_02")] = true,
        [GetHashKey("a_m_y_gay_01")] = true, [GetHashKey("a_m_y_gay_02")] = true,
        [GetHashKey("a_m_y_hiker_01")] = true,
        [GetHashKey("a_m_y_hipster_01")] = true, [GetHashKey("a_m_y_hipster_02")] = true,
        [GetHashKey("a_m_y_hipster_03")] = true,
        [GetHashKey("a_m_y_juggalo_01")] = true,
        [GetHashKey("a_m_y_junker_01")] = true,
        [GetHashKey("a_m_y_kpop_01")] = true,
        [GetHashKey("a_m_y_methhead_01")] = true,
        [GetHashKey("a_m_y_mexthug_01")] = true,
        [GetHashKey("a_m_y_motox_01")] = true, [GetHashKey("a_m_y_motox_02")] = true,
        [GetHashKey("a_m_y_musclbeac_01")] = true, [GetHashKey("a_m_y_musclbeac_02")] = true,
        [GetHashKey("a_m_y_polynesian_01")] = true,
        [GetHashKey("a_m_y_roadcyc_01")] = true,
        [GetHashKey("a_m_y_runner_01")] = true,
        [GetHashKey("a_m_y_runner_02")] = true,
        [GetHashKey("a_m_y_skater_01")] = true, [GetHashKey("a_m_y_skater_02")] = true,
        [GetHashKey("a_m_y_soucent_01")] = true, [GetHashKey("a_m_y_soucent_02")] = true,
        [GetHashKey("a_m_y_soucent_03")] = true,
        [GetHashKey("a_m_y_soucent_04")] = true,
        [GetHashKey("a_m_y_stbla_01")] = true, [GetHashKey("a_m_y_stbla_02")] = true,
        [GetHashKey("a_m_y_stlat_01")] = true, [GetHashKey("a_m_y_stwhi_01")] = true,
        [GetHashKey("a_m_y_stwhi_02")] = true,
        [GetHashKey("a_m_y_sunbathe_01")] = true,
        [GetHashKey("a_m_y_surfer_01")] = true,
        [GetHashKey("a_m_y_veteran_01")] = true,
        [GetHashKey("a_m_y_vinewood_01")] = true, [GetHashKey("a_m_y_vinewood_02")] = true,
        [GetHashKey("a_m_y_vinewood_03")] = true, [GetHashKey("a_m_y_vinewood_04")] = true,
        [GetHashKey("a_m_y_yoga_01")] = true,
        [GetHashKey("u_m_y_imporage_01")] = true,
        [GetHashKey("u_m_y_party_01")] = true,
        [GetHashKey("u_m_y_proldrug_01")] = true,
    }
    if gender == "female" then
        if ELDERLY_FEMALE_HASHES[modelHash] then return "elderly" end
        if YOUNG_FEMALE_HASHES[modelHash] then return "young" end
    else
        if ELDERLY_MALE_HASHES[modelHash] then return "elderly" end
        if YOUNG_MALE_HASHES[modelHash] then return "young" end
    end
    return "adult"
end

local function PlayTtsAudio(text, coords, volume, ped)
    if not state.voiceResponseEnabled then
        return
    end
    if not text or text == "" then return end
    volume = volume or 0.5
    ped = ped or (state.currentNpc or nil)
    if not ped or not DoesEntityExist(ped) then return end

    local cleanText = string.gsub(text, "%b()", "")
    cleanText = string.gsub(cleanText, "%*%*", "")
    cleanText = string.gsub(cleanText, "%s+", " ")
    if cleanText == "" or cleanText == " " then
        cleanText = "Uh... well..."
    end

    local isMale = IsPedMale(ped)
    local pedNetId = NetworkGetNetworkIdFromEntity(ped)
    local modelHash = GetEntityModel(ped)
    local voiceAge = DetectPedVoiceAge(modelHash, isMale and "male" or "female")
    TriggerServerEvent('npci_server:requestTtsAudio', cleanText, coords, volume, pedNetId, isMale, voiceAge)
end

RegisterNetEvent('npci_client:playPremiumTts')
AddEventHandler('npci_client:playPremiumTts', function(base64AudioString)
    state.npcIsThinking = false
    SendNUIMessage({ action = "playBase64Audio", audio = base64AudioString })
end)

-- Live world-state snapshot for the NPC: where it physically is, which seat it
-- occupies, and what task it is currently on. Refreshed on EVERY AI request so
-- the model can never claim to be somewhere it isn't (e.g. "standing on the
-- highway" while it is actually seated in a moving car).
function RefreshNpcWorldState(npc)
    local data = state.currentNpcData
    if not data or not npc or not DoesEntityExist(npc) then return end

    local coords = GetEntityCoords(npc)

    -- Fresh location label: street/zone plus the nearest known landmark
    local label = GetStreetAndZone(coords)
    if Config.LocationCoords then
        local nearestKey, nearestDist
        for key, loc in pairs(Config.LocationCoords) do
            local dist = #(coords - vector3(loc.x, loc.y, loc.z))
            if dist <= (loc.radius or 5.0) and (not nearestDist or dist < nearestDist) then
                nearestKey, nearestDist = key, dist
            end
        end
        if nearestKey then
            local pretty = nearestKey:gsub("_", " ")
            label = label .. " (right by " .. pretty .. ")"
        end
    end
    data.location = label

    -- Physical state: on foot / driving / riding as a passenger
    local veh = GetVehiclePedIsIn(npc, false)
    if veh ~= 0 then
        local isDriver = GetPedInVehicleSeat(veh, -1) == npc
        data.inVehicle = true
        data.isDriving = isDriver
        data.seat = isDriver and "driver" or "passenger"
        local dn = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
        data.vehicleName = GetLabelText(dn)
        if data.vehicleName == "NULL" or data.vehicleName == "" then data.vehicleName = "car" end
        data.vehStats = {
            engine = GetVehicleEngineHealth(veh),
            body = GetVehicleBodyHealth(veh),
            dirt = GetVehicleDirtLevel(veh),
            fuel = GetVehicleFuelLevel(veh)
        }
        data.vehicleSpeed = math.floor(GetEntitySpeed(veh) * 2.236936 + 0.5) -- m/s -> mph
        data.playerInVehicle = (GetVehiclePedIsIn(PlayerPedId(), false) == veh)
    else
        data.inVehicle = false
        data.isDriving = false
        data.seat = "none"
        data.vehicleName = "none"
        data.vehStats = nil
        data.vehicleSpeed = 0
        data.playerInVehicle = false
    end

    -- What the NPC's own AI brain currently has it doing
    data.currentAction = state.currentRoutine or "WANDER"
    data.targetLocation = state.targetLocation or "none"

    -- Authoritative who-sits-where + live senses, refreshed every message
    data.seatMap = GetVehicleSeatMap(veh, npc)
    data.perception = BuildNpcPerception(npc, veh)
end

-- ============================================================================
--                 AI PERCEPTION LAYER (feeds the master prompt)
-- ============================================================================

-- Authoritative who-sits-where list for a vehicle. This is the single source of
-- truth the AI trusts for seats - it kills the "I'm the driver but I claim I'm
-- sitting in the passenger seat" hallucination for good.
function GetVehicleSeatMap(veh, selfPed, playerPed)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return "" end
    playerPed = playerPed or PlayerPedId()
    local function label(occupant)
        if not occupant or occupant == 0 or occupant == -1 then return "empty" end
        if occupant == selfPed then return "YOU" end
        if occupant == playerPed then return "the player" end
        return "someone else"
    end
    local parts = { "Driver seat: " .. label(GetPedInVehicleSeat(veh, -1)) }
    local maxPass = GetVehicleMaxNumberOfPassengers(veh)
    for seat = 0, maxPass - 1 do
        local where = (seat == 0) and "Front passenger seat" or ("Rear seat " .. tostring(seat + 1))
        table.insert(parts, where .. ": " .. label(GetPedInVehicleSeat(veh, seat)))
    end
    return table.concat(parts, "; ")
end

-- What this ped's senses pick up right now: crowd, traffic, police, sirens,
-- a gun in its face, its own injuries, the weather on its skin, the hour.
-- Cached briefly - it is scanned on every message, not every frame.
local lastPerception = { t = 0, ped = nil, lines = nil }
function BuildNpcPerception(ped, veh)
    if not ped or not DoesEntityExist(ped) then return {} end
    local now = GetGameTimer()
    if lastPerception.ped == ped and lastPerception.lines and (now - lastPerception.t) < 2500 then
        return lastPerception.lines
    end

    local lines = {}
    local pos = GetEntityCoords(ped)
    local player = PlayerPedId()

    local people, cops, sirens, rolling, parked = 0, 0, 0, 0, 0
    for _, p in ipairs(GetAllPeds()) do
        if p ~= ped and p ~= player and DoesEntityExist(p) and not IsPedDeadOrDying(p, true) then
            if #(pos - GetEntityCoords(p)) < 30.0 then
                people = people + 1
                if IsPedACop(p) then cops = cops + 1 end
            end
        end
    end
    for _, v in ipairs(GetAllVehicles()) do
        if DoesEntityExist(v) then
            local d = #(pos - GetEntityCoords(v))
            if d < 50.0 then
                if GetVehicleClass(v) == 18 then
                    cops = cops + 1
                    if IsVehicleSirenOn(v) then sirens = sirens + 1 end
                elseif GetEntitySpeed(v) > 5.0 then
                    rolling = rolling + 1
                else
                    parked = parked + 1
                end
            end
        end
    end

    if people == 0 then
        table.insert(lines, "The area around you is empty - nobody within earshot.")
    else
        table.insert(lines, string.format("There are about %d people around you, within earshot.", people))
    end
    if rolling > 0 then
        table.insert(lines, string.format("Traffic is flowing near you - about %d cars rolling past.", rolling))
    elseif parked > 0 then
        table.insert(lines, "Cars are parked all around but the road itself is still.")
    else
        table.insert(lines, "The road around you is quiet - almost no traffic.")
    end
    if cops > 0 then
        table.insert(lines, string.format("Police are close - roughly %d of them in sight.", cops))
    end
    if sirens > 0 then
        table.insert(lines, "Sirens are wailing nearby - something is going down.")
    end

    -- Immediate threats beat everything else
    if IsPlayerFreeAimingAtEntity(PlayerId(), ped) then
        table.insert(lines, "THE PLAYER HAS A GUN POINTED RIGHT AT YOU.")
    elseif IsPedArmed(player, 4) then
        table.insert(lines, "The player is carrying a visible weapon.")
    end
    if IsPedInCombat(ped, -1) then
        table.insert(lines, "You are in a fight right now.")
    end
    if GetEntityHealth(ped) < 180 then
        table.insert(lines, "You are hurt - you took a beating and it still throbs.")
    end

    -- Weather and light, felt on the body
    local w = cachedWeather or "CLEAR"
    if w == "RAIN" or w == "THUNDER" or w == "OVERCAST" then
        table.insert(lines, "The sky is heavy and the air feels wet on your skin.")
    elseif w == "EXTRASUNNY" or w == "CLEAR" then
        table.insert(lines, "The sun is out and beats down on the street.")
    elseif w == "SMOG" or w == "FOGGY" then
        table.insert(lines, "The air is thick and hazy today.")
    end
    local hour = GetClockHours()
    if hour >= 21 or hour < 5 then
        table.insert(lines, "It is deep night - streetlights are the only light out here.")
    end

    -- Motion sensations for whoever is inside the vehicle
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local mph = math.floor(GetEntitySpeed(veh) * 2.236936 + 0.5)
        if mph > 10 then
            table.insert(lines, string.format("You feel the car roll at about %d mph - engine drone, wind, the road under you.", mph))
        end
    end

    lastPerception = { t = now, ped = ped, lines = lines }
    return lines
end

-- ============================================================================
--              SCENE ACTIONS (body language the AI can trigger)
-- ============================================================================
-- The AI picks a micro-action in its JSON ("scene_action"): checking the phone,
-- lighting a cigarette, glancing over... this makes its body match its words.
local SCENE_ACTIONS = {
    check_phone = function(ped)
        TaskPlayAnim(ped, "cellphone@", "cellphone_text_read_base", 8.0, -8.0, 4000, 49, 0, false, false, false)
    end,
    light_cigarette = function(ped)
        TaskPlayAnim(ped, "amb@world_human_smoking@male@male_a@base", "base", 8.0, -8.0, 6000, 49, 0, false, false, false)
    end,
    wave = function(ped)
        TaskPlayAnim(ped, "gestures@f@standing@casual", "gesture_hello", 8.0, -8.0, 2500, 49, 0, false, false, false)
    end,
    point = function(ped)
        TaskPlayAnim(ped, "gestures@f@standing@casual", "gesture_point", 8.0, -8.0, 2500, 49, 0, false, false, false)
    end,
    shrug = function(ped)
        TaskPlayAnim(ped, "gestures@f@standing@casual", "gesture_shrug_hard", 8.0, -8.0, 2500, 49, 0, false, false, false)
    end,
    check_watch = function(ped)
        TaskPlayAnim(ped, "misscarsteal2pimp", "check_phone_b", 8.0, -8.0, 2500, 49, 0, false, false, false)
    end,
    arms_crossed = function(ped)
        TaskPlayAnim(ped, "anim@heists@prison_heiststation@cop_reactions", "cop_b", 8.0, -8.0, 3500, 49, 0, false, false, false)
    end,
    glance_back = function(ped)
        TaskLookAtEntity(ped, PlayerPedId(), 3000, 0, 2)
    end,
    adjust_mirror = function(ped)
        TaskLookAtEntity(ped, PlayerPedId(), 2500, 0, 2)
    end,
    nod = function(ped)
        TaskLookAtEntity(ped, PlayerPedId(), 2000, 0, 3)
    end,
    turn_up_radio = function(ped)
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 then SetVehicleRadioLoud(veh, not IsVehicleRadioLoud(veh)) end
    end,
}
function PlaySceneAction(name, ped)
    if type(name) ~= "string" or name == "none" then return end
    if not ped or not DoesEntityExist(ped) then return end
    local fn = SCENE_ACTIONS[name]
    if fn then pcall(fn, ped) end
end

-- Physical-state line for ANY ped (not just the interacted one). Used by ambient
-- NPC-to-NPC chat and muttering so peds never narrate a body position they
-- don't have - e.g. "standing on the highway" while riding in a car.
function DescribeNpcPhysicalState(ped)
    if not ped or not DoesEntityExist(ped) then
        return "You are on foot, out on the street."
    end
    local loc = GetStreetAndZone(GetEntityCoords(ped))

    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        return "You are on foot, physically out on the street at " .. loc .. "."
    end

    local isDriver = GetPedInVehicleSeat(veh, -1) == ped
    local dn = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    local vname = GetLabelText(dn)
    if vname == "NULL" or vname == "" then vname = "car" end

    local line
    if isDriver then
        line = string.format("You are SEATED BEHIND THE WHEEL of a %s, driving it right now - not standing outside.", vname)
    else
        line = string.format("You are riding as a PASSENGER in a %s - somebody else is driving. You are inside the car, not outside it.", vname)
    end
    if GetVehiclePedIsIn(PlayerPedId(), false) == veh then
        line = line .. " The player is in this same vehicle."
    end
    local sm = GetVehicleSeatMap(veh, ped)
    if sm ~= "" then
        line = line .. " SEAT MAP: " .. sm .. "."
    end
    local mph = math.floor(GetEntitySpeed(veh) * 2.236936 + 0.5)
    if mph > 3 then
        line = line .. string.format(" The vehicle is moving, about %d mph.", mph)
    else
        line = line .. " The vehicle is stopped."
    end
    return line .. " You are around " .. loc .. "."
end

-- Context bundle sent with ambient chat / mutter requests
function BuildNpcChatCtx(ped, data)
    data = data or {}
    return {
        state = DescribeNpcPhysicalState(ped),
        routine = data.routine or "WANDER",
        target = data.targetLocation or "none",
        inVehicle = (ped and DoesEntityExist(ped) and GetVehiclePedIsIn(ped, false) ~= 0)
    }
end

function StartInteraction(npc)
    if state.isInteracting then return end
    
    -- Check State Bag lock before starting to prevent multiple player interactions/crashes!
    local lockedBy = Entity(npc).state.npci_lockedBy
    if lockedBy and lockedBy ~= GetPlayerServerId(PlayerId()) then
        ESX.ShowNotification("This NPC is currently busy talking to someone else.", "error")
        return
    end
    
    -- Clear driver state when starting with a DIFFERENT NPC (prevents cross-NPC driver seat corruption)
    local prevNpc = state.currentNpc
    if state.npcIsDriver and prevNpc and prevNpc ~= npc then
        ResetDriverState()
    end
    
    -- Detect NPC's current state before modifying tasks
    local npcVeh = GetVehiclePedIsIn(npc, false)
    local isInVehicle = npcVeh ~= 0
    local isInScenario = IsPedUsingAnyScenario(npc)
    
    -- Save pre-interaction state so we can restore sitting/dancing NPCs
    local preNpcPos = GetEntityCoords(npc)
    local preNpcHeading = GetEntityHeading(npc)
    local preNpcSitting = isInScenario and not isInVehicle and IsPedSittingPose(npc)
    local isDancing = false
    if not isInVehicle and not isInScenario then
        isDancing = IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_01", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_02", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_03", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@mini@dance@dance_solo@", "dance_solo", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@peds@", "amb_world_human_dancing_male_base", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@peds@", "amb_world_human_dancing_female_base", 3)
        or IsEntityPlayingAnim(npc, "mini@strip_club@idles@stripper", "stripper_idle_01", 3)
        or IsEntityPlayingAnim(npc, "mini@strip_club@idles@stripper", "stripper_idle_02", 3)
        or IsEntityPlayingAnim(npc, "mini@strip_club@idles@stripper", "stripper_idle_03", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@sol@", "mi_dance_01", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@sol@", "mi_dance_02", 3)
        or IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@sol@", "mi_dance_03", 3)
    end
    
    SetBlockingOfNonTemporaryEvents(npc, true)
    SetPedFleeAttributes(npc, 0, 0)
    
    if isInVehicle then
        SetEntityAsMissionEntity(npc, true, true)
        SetPedStayInVehicleWhenJacked(npc, true)
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
        MutePedNativeAudio(npc)
    elseif isDancing then
        SetEntityAsMissionEntity(npc, true, true)
        MutePedNativeAudio(npc)
        SetPedKeepTask(npc, true)
        -- Restart dance after mission takeover interrupts it
        CreateThread(function()
            Wait(100)
            if DoesEntityExist(npc) and state.isInteracting then
                if not IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_01", 3)
                and not IsEntityPlayingAnim(npc, "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_03", 3)
                and not IsEntityPlayingAnim(npc, "anim@amb@nightclub@mini@dance@dance_solo@", "dance_solo", 3)
                and not IsEntityPlayingAnim(npc, "anim@amb@nightclub@peds@", "amb_world_human_dancing_male_base", 3)
                and not IsEntityPlayingAnim(npc, "anim@amb@nightclub@peds@", "amb_world_human_dancing_female_base", 3) then
                    local danceAnims = {
                        "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_01",
                        "anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_base_03",
                        "anim@amb@nightclub@mini@dance@dance_solo@", "dance_solo",
                    }
                    local idx = math.random(3)
                    local dict = danceAnims[(idx-1)*2+1]
                    local anim = danceAnims[(idx-1)*2+2]
                    RequestAnimDict(dict)
                    for _ = 1, 30 do
                        if HasAnimDictLoaded(dict) then break end
                        Wait(10)
                    end
                    if HasAnimDictLoaded(dict) then
                        TaskPlayAnim(npc, dict, anim, 8.0, -8.0, -1, 1, 0, 0, 0, 0)
                    end
                end
                TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
            end
        end)
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
    elseif isInScenario then
        SetEntityAsMissionEntity(npc, true, true)
        MutePedNativeAudio(npc)
        SetPedKeepTask(npc, true)
        -- Re-sit NPCs that lose their scenario from mission takeover
        CreateThread(function()
            Wait(100)
            if DoesEntityExist(npc) and state.isInteracting and not IsPedUsingAnyScenario(npc) then
                -- Only re-seat NPCs that were actually sitting AND only at a real seat
                -- nearby. Blind "bench at saved pos" put standing NPCs into a floating
                -- sit animation (no seat under them).
                if preNpcSitting then
                    local seatCoords, seatHeading, seatObj = FindClosestSeatCoordsAt(preNpcPos, 4.0)
                    if seatCoords then
                        TaskStartScenarioAtPosition(npc, SeatScenarioForSeatProp(seatObj), seatCoords.x, seatCoords.y, seatCoords.z, seatHeading, -1, true, false)
                    end
                end
                Wait(200)
                if DoesEntityExist(npc) then
                    TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
                end
            end
        end)
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
    else
        SetEntityAsMissionEntity(npc, true, true)
        MutePedNativeAudio(npc)
        ClearPedTasksImmediately(npc)
        TaskStandStill(npc, -1)
        SetEntityVelocity(npc, 0.0, 0.0, 0.0)
        local pCoords = GetEntityCoords(PlayerPedId())
        local nCoords2 = GetEntityCoords(npc)
        SetEntityHeading(npc, HeadingFromVector(pCoords.x - nCoords2.x, pCoords.y - nCoords2.y))
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
    end
    
    ESX.ShowNotification("Hold ~y~N~s~ to speak (push-to-talk)", "info")
    SendNUIMessage({ action = "unlockAudio" })

    state.isInteracting = true
    state.currentNpc = npc
    state.conversationHistory = {}
    state.isInVehicle = isInVehicle
    if state.followNpc and state.followNpc ~= npc then
        if DoesEntityExist(state.followNpc) then ClearPedTasksImmediately(state.followNpc) end
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
    end
    state.isAiSuppressed = false
    state.isAwaitingAiResponse = false
    state.npcIsThinking = false
    state.lastInteractionTime = GetGameTimer()
    state.isAnimal = IsAnimalPed(npc)
    state.lastEngineAction = nil
    state.lastEngineTarget = nil
    state.lastScenarioType = nil
    state.wasInScenario = isInScenario
    state.wasDancing = isDancing
    state.preNpcSitting = preNpcSitting
    state.preNpcPos = (isInScenario or isDancing) and preNpcPos or nil
    state.preNpcHeading = (isInScenario or isDancing) and preNpcHeading or nil
    
    if DoesEntityExist(npc) then
        local netId = NetworkGetNetworkIdFromEntity(npc)
        TriggerServerEvent('npci_server:startedInteracting', netId)
    end
    
    local coords = GetEntityCoords(npc)
    local model = GetEntityModel(npc)
    
    -- Check state bag for npci_id
    local stateBagId = Entity(npc).state.npci_id
    local role = Entity(npc).state.npci_role
    local mood = Entity(npc).state.npci_mood
    local name = Entity(npc).state.npci_name
    
    if not stateBagId then
        -- Initialize attributes
        role = DetectNpcRole(npc)
        
        -- Stationary roles for location-persistent memory
        local isStationaryRole = (role == "Shop Personal" or role == "Guard" or role == "EMS" or role == "Firefighter" or role == "Inmate" or role == "Police" or role == "Meth Cook" or role == "Valet")
        
        if isStationaryRole then
            stateBagId = string.format("static_%d_%.0f_%.0f_%.0f", model, math.floor(coords.x / 5.0 + 0.5) * 5, math.floor(coords.y / 5.0 + 0.5) * 5, math.floor(coords.z / 5.0 + 0.5) * 5)
        else
            stateBagId = string.format("roaming_%d_%d", model, math.random(100000, 999999))
        end
        
        local maleNames = {
            "Trevor", "Michael", "Franklin", "Lamar", "Jimmy", "Wade", "Ron", "Brad", "Dave", "Steve", 
            "Devin", "Martin", "Solomon", "Floyd", "Simeon", "Gerald", "Lester", "Dom", "Tony", "Luis", 
            "Niko", "Roman", "Brucie", "Yusuf", "Johnny", "Clay", "Terry", "Packie", "Derrick", "Francis", 
            "Bernie", "Manny", "Playboy X", "Dwayne", "Ray", "Phil", "Little Jacob", "Badman", "CJ", 
            "Sweet", "Ryder", "Big Smoke", "Cesar", "Madd Dogg", "OG Loc", "The Truth", "Zero", 
            "Wu Zi Mu", "Toreno", "Jethro", "Dwaine", "Maccer", "Kent Paul", "Ken Rosenberg", "Salvatore", 
            "Kenji", "Donald Love", "Ray Machowski", "Joey", "Toni Cipriani", "Claude", "Miguel", "8-Ball", 
            "El Burro", "King Courtney", "D-Ice"
        }
        
        local femaleNames = {
            "Tracey", "Amanda", "Molly", "Patricia", "Tanisha", "Tonya", "Ashley", "Denise", "Karen", 
            "Paige", "Kendl", "Catalina", "Asuka", "Maria", "Elizabeta", "Mallorie", "Kate", "Michelle", 
            "Lola", "Carmen", "Kiki", "Alex", "Grace", "Liz", "Elena", "Misty", "Luisa"
        }
        
        if IsPedMale(npc) then
            name = maleNames[math.random(#maleNames)]
        else
            name = femaleNames[math.random(#femaleNames)]
        end
        
        Entity(npc).state:set('npci_id', stateBagId, true)
        Entity(npc).state:set('npci_role', role, true)
        Entity(npc).state:set('npci_name', name, true)
        Entity(npc).state:set('npci_model_hash', GetEntityModel(npc), true)
    end
    
    -- Always assign a fresh random mood for every interaction!
    local moods = {"rude", "funny", "offensive", "aggressive", "paranoid", "friendly", "stoned", "sarcastic", "anxious", "dismissive", "hyperactive", "flirtatious", "overly-dramatic", "manic", "optimistic", "exhausted", "apathetic", "depressed", "hungover", "regretful", "condescending", "philosophical", "professional", "poetic", "arrogant", "conspiratorial", "secretive", "impatient", "bitter", "passive-aggressive", "delusional", "absent-minded", "confused", "gullible", "cowardly"}
    mood = moods[math.random(#moods)]
    Entity(npc).state:set('npci_mood', mood, true)
    
    local description = Entity(npc).state.npci_description or DetectNpcDescription(role)
    local modelHash = Entity(npc).state.npci_model_hash or GetEntityModel(npc)

    -- Location-aware label: override generic street/zone for known interiors
    local locationLabel = GetStreetAndZone(coords)
    if coords and Config.LocationCoords and Config.LocationCoords.bahama_mamas then
        local bm = Config.LocationCoords.bahama_mamas
        if #(coords - vector3(bm.x, bm.y, bm.z)) < bm.radius then
            locationLabel = "Bahama Mamas West Nightclub"
        end
    end

    state.currentNpcData = {
        id = stateBagId,
        name = name,
        role = role,
        mood = mood,
        gender = IsPedMale(npc) and "Male" or "Female",
        location = locationLabel,
        model_hash = modelHash,
        description = description,
        context = GetPlayerContext(),
        isDriving = false,
        vehicleName = "none",
        vehStats = nil
    }
    -- Detect initial physical state (seat, vehicle, fresh location, current task)
    RefreshNpcWorldState(npc)
    
    -- Register in ActiveAIPeds
    ActiveAIPeds[npc] = {
        stateBagId = stateBagId,
        role = role,
        mood = mood,
        name = name,
        isInConversation = true,
        isBusy = false,
        lastChatTime = 0,
        routine = state.currentRoutine,
        targetLocation = state.targetLocation
    }
    
    -- Load routine data from database
    TriggerServerEvent('npci_server:loadRoutine', state.currentNpcData.id)
    
    state.lastContext = state.currentNpcData.context
    state.pendingContextChange = nil
    state.helpMeOut = false
    state.isVoiceListening = false
    state.voicePttHeld = false
    TriggerServerEvent('npci_server:getMemory', state.currentNpcData.id)
    TriggerServerEvent('npci_bridge:checkAndAddContact', state.currentNpcData)
    ESX.ShowNotification(string.format("Interacting with %s (%s).", name, role), "success")
end

function TranslateEngineAction(ped, engineAction, targetLocation, scenarioType, roleOverride)
    if not DoesEntityExist(ped) or state.npcIsDriver then return end
    local veh = GetVehiclePedIsIn(ped, false)
    -- On-foot actions must not fight an existing vehicle task, but driving actions still
    -- have to run when the NPC is already behind the wheel (this used to return early and
    -- made the DRIVE_TO_LOCATION / ESCAPE_COPS branches unreachable for seated NPCs).
    local isDrivingAction = engineAction == "DRIVE_TO_LOCATION" or engineAction == "ESCAPE_COPS"
    if veh ~= 0 and not isDrivingAction then return end

    -- Any engine action takes the ped back from a player hold and un-freezes it
    if ActiveAIPeds[ped] then ActiveAIPeds[ped].manualHold = nil end
    FreezeEntityPosition(ped, false)

    local role = roleOverride or (state.currentNpcData and state.currentNpcData.role)
    local isStationaryRole = (role == "Shop Personal" or role == "Guard" or role == "Meth Cook" or role == "Valet" or role == "Police" or role == "EMS" or role == "Firefighter")

    if engineAction == "GO_TO_WORK" and targetLocation and targetLocation ~= "none" then
        local coords, radius = GetLocationCoords(targetLocation)
        if coords then
            TaskGoToCoordAnyMeans(ped, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
        elseif not isStationaryRole then
            TaskWanderStandard(ped, 10.0, 10)
        end

    elseif engineAction == "GO_HOME" and targetLocation and targetLocation ~= "none" then
        local coords, _ = GetLocationCoords(targetLocation)
        if coords then
            TaskGoToCoordAnyMeans(ped, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
        elseif not isStationaryRole then
            TaskWanderStandard(ped, 10.0, 10)
        end

    elseif engineAction == "SCENARIO" and scenarioType and scenarioType ~= "none" then
        TaskStartScenarioInPlace(ped, scenarioType, 0, true)

    elseif engineAction == "STAND_GUARD" then
        TaskStartScenarioInPlace(ped, "WORLD_HUMAN_GUARD_STAND", 0, true)

    elseif engineAction == "PATROL" then
        local pCoords = GetEntityCoords(ped)
        TaskGoToCoordAnyMeans(ped, pCoords.x + math.random(-50, 50), pCoords.y + math.random(-50, 50), pCoords.z, 1.0, 0, 0, 786432, 0xbf800000)

    elseif engineAction == "DRIVE_TO_LOCATION" and targetLocation and targetLocation ~= "none" then
        local dest = Config.LocationCoords[targetLocation]
        if dest then
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                SetDriverAbility(ped, 1.0)
                -- Long-range task for cross-map trips: the short-range task keeps
                -- re-pathing locally and makes the NPC reverse / K-turn in place.
                if #(GetEntityCoords(ped) - vector3(dest.x, dest.y, dest.z)) > 60.0 then
                    TaskVehicleDriveToCoordLongrange(ped, veh, dest.x, dest.y, dest.z, 30.0, 786468, 25.0)
                else
                    TaskVehicleDriveToCoord(ped, veh, dest.x, dest.y, dest.z, 15.0, 0, GetEntityModel(veh), 2883621, 5.0, true)
                end
            else
                TaskGoToCoordAnyMeans(ped, dest.x, dest.y, dest.z, 1.0, 0, 0, 786603, 0xbf800000)
            end
        end

    elseif engineAction == "ESCAPE_COPS" then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            TaskVehicleDriveWander(ped, veh, 50.0, 786468)
            ModifyVehicleTopSpeed(veh, 20.0)
        end

    elseif engineAction == "WANDER" then
        if not isStationaryRole then
            TaskWanderStandard(ped, 10.0, 10)
        end

    elseif engineAction == "ARRIVED" then
        -- NPC arrived at destination, start a scenario
        if scenarioType and scenarioType ~= "none" then
            TaskStartScenarioInPlace(ped, scenarioType, 0, true)
        else
            TaskStartScenarioInPlace(ped, "WORLD_HUMAN_STAND_MOBILE", 0, true)
        end

    else
        if not isStationaryRole then
            TaskWanderStandard(ped, 10.0, 10)
        end
    end
end

function StopInteraction()
    if not state.isInteracting then return end
    local npc = state.currentNpc
    local npcData = state.currentNpcData

    DismissCompanionPed(npc)
    
    -- An explicit "follow me" survives the conversation; the follow thread keeps
    -- re-issuing the task using the persisted followNpc handle.
    state.isFollowing = (state.explicitFollow == true and state.followNpc ~= nil
        and DoesEntityExist(state.followNpc)) or false
    state.isLeading = false
    state.leadDestination = nil
    state.isCompanion = false
    state.helpMeOut = false
    state.npcIsThinking = false
    state.isAwaitingAiResponse = false
    state.isVoiceListening = false
    state.voicePttHeld = false
    state.companionVehicle = 0
    state.companionCombatTarget = nil
    
    local pedCoords = npc and DoesEntityExist(npc) and GetEntityCoords(npc) or nil
    local routineData = nil
    if state.lastEngineAction then
        routineData = {
            engine_action = state.lastEngineAction,
            target_location = state.lastEngineTarget,
            scenario_type = state.lastScenarioType
        }
    end
    local releasedRole = npcData and npcData.role or nil
    local releasedRoutine = routineData or { engine_action = "WANDER", target_location = "none", scenario_type = "none" }

    -- Mood evolution was temporary (one chat): ambient barks/mutters go back to
    -- the fresh roll made when this conversation started.
    if npc and ActiveAIPeds[npc] then
        ActiveAIPeds[npc].mood = Entity(npc).state.npci_mood or ActiveAIPeds[npc].mood
    end

    if npcData and npcData.id then
        TriggerServerEvent('npci_server:saveMemory', npcData.id, state.conversationHistory, routineData, pedCoords and { x = pedCoords.x, y = pedCoords.y, z = pedCoords.z } or nil)
    end

        -- Release main NPC with task translation
        if npc and DoesEntityExist(npc) then
            local heldPed = (ActiveAIPeds[npc] and ActiveAIPeds[npc].manualHold) or false
            local keepFollow = (not heldPed) and state.explicitFollow == true
                and state.followNpc == npc
            SetBlockingOfNonTemporaryEvents(npc, false)
            SetPedFleeAttributes(npc, 1, 0)
            if not heldPed then
                FreezeEntityPosition(npc, false)
            end

            -- Restore dancing/sitting NPCs to their state; otherwise translate engine action
            local midBoarding = GetIsTaskActive(npc, 235)
            local seatRestoreAttempted = false
            if heldPed then
                -- Player hold (wait/guard/pose command): tasks and freeze stay untouched
            elseif keepFollow then
                -- Explicit "follow me" survives the conversation; the follow thread
                -- re-issues the task using the persisted followNpc handle.
            elseif midBoarding then
                -- NPC was told to enter a vehicle: let TaskEnterVehicle finish instead of
                -- cancelling it. The background life loop resumes their routine after.
            elseif state.wasDancing then
                local dict = "anim@amb@nightclub@dancers@podium_dancers@"
                local anim = "hi_dance_base_0" .. math.random(3)
                RequestAnimDict(dict)
                for _ = 1, 30 do
                    if HasAnimDictLoaded(dict) then break end
                    Wait(10)
                end
                if HasAnimDictLoaded(dict) then
                    TaskPlayAnim(npc, dict, anim, 8.0, -8.0, -1, 1, 0, 0, 0, 0)
                end
            elseif state.wasInScenario and state.preNpcPos and state.preNpcSitting
                and GetVehiclePedIsIn(npc, false) == 0 then
                -- Re-seat ONLY NPCs that were actually sitting, and only at a real seat
                -- within 4m. The old blind "bench at saved pos" restore floated standing
                -- NPCs in mid-air (bench scenario ignores ground) and yanked guards out
                -- of vehicles they had just been told to enter.
                local seatCoords, seatHeading, seatObj = FindClosestSeatCoordsAt(state.preNpcPos, 4.0)
                if seatCoords then
                    ClearPedTasksImmediately(npc)
                    TaskStartScenarioAtPosition(npc, SeatScenarioForSeatProp(seatObj), seatCoords.x, seatCoords.y, seatCoords.z, seatHeading, -1, true, false)
                    seatRestoreAttempted = true
                else
                    ClearPedTasksImmediately(npc)
                    TranslateEngineAction(npc, state.lastEngineAction or "WANDER", state.lastEngineTarget, state.lastScenarioType, releasedRole)
                end
            else
                ClearPedTasksImmediately(npc)
                TranslateEngineAction(npc, state.lastEngineAction or "WANDER", state.lastEngineTarget, state.lastScenarioType, releasedRole)
            end

            -- Update ActiveAIPeds with routine
            if ActiveAIPeds[npc] then
                ActiveAIPeds[npc].isInConversation = false
                ActiveAIPeds[npc].routine = state.currentRoutine
                ActiveAIPeds[npc].targetLocation = state.targetLocation
            end

            -- Watchdog: no stale follow task may survive StopInteraction, and a failed
            -- seat-restore must fall back to the NPC's routine instead of leaving them
            -- standing or floating. Runs after all release yields have settled.
            local releaseNpc = npc
            CreateThread(function()
                Wait(1500)
                if state.isInteracting or not DoesEntityExist(releaseNpc) or heldPed or keepFollow then return end
                local staleFollow = GetIsTaskActive(releaseNpc, 222)
                local scenarioLost = seatRestoreAttempted and not IsPedUsingAnyScenario(releaseNpc)
                if staleFollow or scenarioLost then
                    ClearPedTasksImmediately(releaseNpc)
                    local savedNpcData = state.currentNpcData
                    state.currentNpcData = { role = releasedRole }
                    TranslateEngineAction(releaseNpc, releasedRoutine.engine_action or "WANDER", releasedRoutine.target_location, releasedRoutine.scenario_type)
                    state.currentNpcData = savedNpcData
                end
            end)
        end

        -- Release multi-NPCs
        for _, mn in ipairs(state.multiNpcs) do
            if DoesEntityExist(mn) then
                local mnNetId = NetworkGetNetworkIdFromEntity(mn)
                TriggerServerEvent('npci_server:stoppedInteracting', mnNetId)
                local heldMn = (ActiveAIPeds[mn] and ActiveAIPeds[mn].manualHold) or false
                local followMn = state.explicitFollow == true and state.followNpc == mn
                SetBlockingOfNonTemporaryEvents(mn, false)
                SetPedFleeAttributes(mn, 1, 0)
                if not heldMn and not followMn then
                    ClearPedTasksImmediately(mn)
                    FreezeEntityPosition(mn, false)
                    local mnRole = state.multiNpcData[mn] and state.multiNpcData[mn].role or "Civilian"
                    local isStationaryRole = (mnRole == "Shop Personal" or mnRole == "Guard" or mnRole == "Meth Cook" or mnRole == "Valet")
                    if not isStationaryRole then
                        TaskWanderStandard(mn, 10.0, 10)
                    end
                end
            end
        end
    state.multiNpcs = {}
    state.multiNpcData = {}

    SendNUIMessage({ action = 'ptt_stop' })
    
    if npc and DoesEntityExist(npc) then
        local netId = NetworkGetNetworkIdFromEntity(npc)
        TriggerServerEvent('npci_server:stoppedInteracting', netId)
    end
    
    state.isInteracting = false
    state.currentNpc = nil
    state.currentNpcData = {}
    state.lastEngineAction = nil
    state.lastEngineTarget = nil
    state.lastScenarioType = nil
end

function HandleInput(text)
    if not state.isInteracting then return end

    -- Parse and physically execute any matched command triggers
    local matchedCmd = ParseCommandText(text)
    if matchedCmd then
        if matchedCmd == "__feature_locked__" then
            return
        end

        -- Execute command on main NPC
        ExecuteNpcCommand(state.currentNpc, matchedCmd)
        -- Execute command on all multi-NPCs too
        for _, mn in ipairs(state.multiNpcs) do
            if DoesEntityExist(mn) then
                ExecuteNpcCommand(mn, matchedCmd)
            end
        end

        -- Silent commands bypass AI voice response and the isAwaitingAiResponse block!
        local silentCommands = {
            hands_up = true,
            get_on_knees = true,
            lay_on_ground = true,
            sit_down = true,
            get_up = true,
            step_out_vehicle = true,
            get_in_vehicle = true,
            run_away = true,
            pushups = true,
            situps = true,
            dance = true,
            jog = true,
            go_to_point = true,
            taser = true,
            delete = true,
            dismiss = true,
            help_me_out = true,
            wait_here = true,
            crouch = true,
            lean = true,
            smoke = true,
            face_me = true,
            turn_around = true,
            hands_behind_back = true,
            use_phone = true,
            wave = true,
            guard_area = true,
            drink = true,
            salute = true,
            stop = true,
            lap_dance = true,
            beg = true,
            listen_at_door = true,
            take_photo = true,
            stretch = true,
            meditate = true,
            flex = true,
            point = true,
            lay_on_bed = true,
            sexy = true,
            blow_me = true,
            escape_cops = true
        }
        if silentCommands[matchedCmd] then
            return
        end
    end

    -- Animals don't talk
    if state.isAnimal then
        ESX.ShowNotification("The animal doesn't understand you.", "info")
        state.isAwaitingAiResponse = false
        state.npcIsThinking = false
        return
    end

    -- Now block if waiting for AI (silent commands already processed above)
    if state.isAwaitingAiResponse then return end

    state.isAwaitingAiResponse = true
    state.npcIsThinking = true

    -- Refresh context on every message so AI always has current world state
    state.currentNpcData.context = GetPlayerContext()

    -- Refresh live world state (seat/vehicle/location/current task) so the AI
    -- always describes what the NPC is actually doing right now
    local npc = state.currentNpc
    if npc and DoesEntityExist(npc) then
        RefreshNpcWorldState(npc)
    end

    -- If there was a pending unprompted context change, insert it as a system observation before the user message
    if state.pendingContextChange then
        table.insert(state.conversationHistory, { role = 'system', content = state.pendingContextChange })
        state.pendingContextChange = nil
    end

    state.lastInteractionTime = GetGameTimer()
    table.insert(state.conversationHistory, { role = 'user', content = text })
    local npcNetId = state.currentNpc and NetworkGetNetworkIdFromEntity(state.currentNpc) or nil
    TriggerServerEvent('npci_server:getAiResponse', state.currentNpcData, state.conversationHistory, npcNetId)

    -- Safety: never leave the interaction stuck if the server/AI fails to respond
    SetTimeout(45000, function()
        if state.isAwaitingAiResponse then
            state.isAwaitingAiResponse = false
            state.npcIsThinking = false
        end
    end)
end

local function ParseMultiNpcResponse(responseText, nameToEntity)
    local parsed = {}
    local mainName = state.currentNpcData and state.currentNpcData.name or ""
    local lines = {}
    for line in string.gmatch(responseText, "[^\r\n]+") do
        table.insert(lines, line)
    end
    local firstIsUnprefixed = false
    if #lines > 0 then
        local _, firstDialogue = string.match(lines[1], "^%s*%[([^%]]+)%]:%s*(.*)$")
        if not firstDialogue then
            firstIsUnprefixed = string.len(lines[1]) > 0
        end
    end
    if firstIsUnprefixed then
        local dialogue = Trim(lines[1])
        if dialogue ~= "" then
            table.insert(parsed, { entity = state.currentNpc, name = mainName, text = dialogue })
        end
    end
    for i = firstIsUnprefixed and 2 or 1, #lines do
        local npcName, dialogue = string.match(lines[i], "^%s*%[([^%]]+)%]:%s*(.*)$")
        if npcName and dialogue then
            local entity = nameToEntity[npcName] or state.currentNpc
            table.insert(parsed, { entity = entity, name = npcName, text = dialogue })
        end
    end
    return parsed
end

local function ShowMultiResponsesSequentially(responses, delayMs)
    local index = 1

    local function showNext()
        if index > #responses then
            state.isAwaitingAiResponse = false
            state.npcIsThinking = false
            return
        end
        local resp = responses[index]
        ShowNpcPrivateChatMessage(resp.text, resp.name)
        ShowNpcBubble(resp.entity, resp.text)
        if DoesEntityExist(resp.entity) then
            local respCoords = GetEntityCoords(resp.entity)
            PlayTtsAudio(resp.text, respCoords, 0.5)
        end
        index = index + 1
        SetTimeout(delayMs, showNext)
    end

    showNext()
end

RegisterNetEvent('npci_server:receiveAiResponse', function(responseText, parsedData)
    if not state.isInteracting then
        state.isAwaitingAiResponse = false
        state.npcIsThinking = false
        return
    end
    responseText = StripRoleplay(responseText)
    if responseText == "" or responseText == " " then
        responseText = "Uh... well..."
    end

    -- Store engine action from parsed data for task translation on StopInteraction
    if parsedData and type(parsedData) == "table" then
        state.lastEngineAction = parsedData.engine_action or "WANDER"
        state.lastEngineTarget = parsedData.target_location or "none"
        state.lastScenarioType = parsedData.scenario_type or "none"
        state.currentRoutine = state.lastEngineAction
        state.targetLocation = state.lastEngineTarget

        -- Update ActiveAIPeds entry
        local npc = state.currentNpc
        if npc and ActiveAIPeds[npc] then
            ActiveAIPeds[npc].routine = state.currentRoutine
            ActiveAIPeds[npc].targetLocation = state.targetLocation
            ActiveAIPeds[npc].mood = parsedData.internal_mood or ActiveAIPeds[npc].mood

            -- A real AI-issued route (go home/work, drive, escape) takes the ped
            -- back from a player hold/follow; casual WANDER chat answers don't.
            local aiAction = parsedData.engine_action
            local aiTarget = parsedData.target_location
            if aiAction == "ESCAPE_COPS"
                or ((aiAction == "GO_TO_WORK" or aiAction == "GO_HOME" or aiAction == "DRIVE_TO_LOCATION")
                    and aiTarget and aiTarget ~= "none") then
                ActiveAIPeds[npc].manualHold = nil
                FreezeEntityPosition(npc, false)
                state.isFollowing, state.explicitFollow, state.followNpc = false, false, nil
            end
        end

        -- DRIVE_TO_LOCATION: direct driving kickstart + companion thread state
        if parsedData.engine_action == "DRIVE_TO_LOCATION" and parsedData.target_location and parsedData.target_location ~= "none" then
            local destination = Config.LocationCoords[parsedData.target_location]
            if destination then
                local npc = state.currentNpc
                if npc and DoesEntityExist(npc) then
                    local veh = GetVehiclePedIsIn(npc, false)
                    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == npc then
                        local targetVec = vector3(destination.x, destination.y, destination.z)
                        -- Direct kickstart so the NPC starts moving immediately
                        SetDriverAbility(npc, 1.0)
                        state.drivingSpeed = state.drivingSpeed or 30.0
                        TaskVehicleDriveToCoordLongrange(npc, veh, targetVec.x, targetVec.y, targetVec.z, state.drivingSpeed, 786468, 25.0)
                        -- Set companion thread state so it keeps the NPC on track
                        state.drivingMode = "navigate"
                        state.drivingTarget = targetVec
                        state.drivingTargetName = parsedData.target_location
                        ESX.ShowNotification("~g~Driving to ~y~" .. parsedData.target_location, "info")
                    else
                        TaskGoToCoordAnyMeans(npc, destination.x, destination.y, destination.z, 1.0, 0, 0, 786603, 0xbf800000)
                        ESX.ShowNotification("~y~Walking to destination (no vehicle).", "info")
                    end
                end
            end
        end

        -- ESCAPE_COPS: reckless evasion mode
        if parsedData.engine_action == "ESCAPE_COPS" then
            local npc = state.currentNpc
            if npc and DoesEntityExist(npc) then
                local veh = GetVehiclePedIsIn(npc, false)
                if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == npc then
                    TaskVehicleDriveWander(npc, veh, 50.0, 786468)
                    ModifyVehicleTopSpeed(veh, 20.0)
                    state.drivingMode = "escape"
                    ESX.ShowNotification("~r~EVASIVE! Going dark!", "info")
                end
            end
        end

        -- T3-K: the NPC wants to disengage - walk away after the exit line lands
        if parsedData.end_conversation == true and #state.multiNpcs == 0 then
            local exitNpc = state.currentNpc
            local turns = math.floor(#state.conversationHistory / 2)
            local moodNow = string.lower(tostring(parsedData.internal_mood or ""))
            local rudeMood = moodNow:find("rude") or moodNow:find("annoy")
                or moodNow:find("angry") or moodNow:find("aggress")
            local minTurns = (Config.Disengage and Config.Disengage.MinTurns) or 6
            if turns >= minTurns or rudeMood then
                SetTimeout(4500, function()
                    if state.isInteracting and state.currentNpc == exitNpc then
                        StopInteraction()
                    end
                end)
            end
        end
    end

    -- Skip text/TTS for animals
    if state.isAnimal then
        state.isAwaitingAiResponse = false
        state.npcIsThinking = false
        return
    end

    local hasMulti = #state.multiNpcs > 0

    if not hasMulti then
        local npcCoords = GetEntityCoords(state.currentNpc)
        local _, screenX, screenY = GetScreenCoordFromWorldCoord(npcCoords.x, npcCoords.y, npcCoords.z + 1.0)
        SendNUIMessage({ action = 'show_text', text = responseText, x = screenX * 100, y = screenY * 100 })
        ShowNpcPrivateChatMessage(responseText)
        local textDuration = math.max(5000, #responseText * 60)
        SetTimeout(textDuration, function() SendNUIMessage({ action = 'hide_text' }) end)
        PlayTtsAudio(responseText, npcCoords, 0.5)
        table.insert(state.conversationHistory, { role = 'assistant', content = responseText })
        state.isAwaitingAiResponse = false
        state.npcIsThinking = false
        return
    end

    -- Multi-NPC response handling
    local nameToEntity = BuildNpcNameToEntity()
    local responses = ParseMultiNpcResponse(responseText, nameToEntity)

    if #responses == 0 then
        -- No structured format detected; treat as main NPC response
        local npcCoords = GetEntityCoords(state.currentNpc)
        local _, screenX, screenY = GetScreenCoordFromWorldCoord(npcCoords.x, npcCoords.y, npcCoords.z + 1.0)
        SendNUIMessage({ action = 'show_text', text = responseText, x = screenX * 100, y = screenY * 100 })
        ShowNpcPrivateChatMessage(responseText)
        local textDuration = math.max(5000, #responseText * 60)
        SetTimeout(textDuration, function() SendNUIMessage({ action = 'hide_text' }) end)
        PlayTtsAudio(responseText, npcCoords, 0.5)
        state.isAwaitingAiResponse = false
        state.npcIsThinking = false
    else
        ShowMultiResponsesSequentially(responses, 4000)
    end

    table.insert(state.conversationHistory, { role = 'assistant', content = responseText })
end)

RegisterNetEvent('npci_server:receiveMemory', function(history, longTermMemory)
    state.conversationHistory = history
end)

RegisterNetEvent('npci_server:receiveRoutine', function(routineData)
    if routineData then
        state.currentRoutine = routineData.current_routine or 'WANDER'
        state.targetLocation = routineData.target_location or nil
        -- Update ActiveAIPeds if we have one
        local npc = state.currentNpc
        if npc and ActiveAIPeds[npc] then
            ActiveAIPeds[npc].routine = state.currentRoutine
            ActiveAIPeds[npc].targetLocation = state.targetLocation
        end
    end
end)

RegisterNetEvent('npci_server:receiveMutterAudio', function(stateBagId, speechText)
    local ped = GetPedByStateBagId(stateBagId)
    if ped and DoesEntityExist(ped) then
        local pedCoords = GetEntityCoords(ped)
        PlayTtsAudio(speechText, pedCoords, 0.3, ped)
    end
end)



RegisterNetEvent('npci_server:receiveChatInput', function(text)
    if not state.isInteracting then return end
    local cleaned = Trim(text)
    if cleaned ~= "" then
        HandleInput(cleaned)
    end
end)

RegisterNUICallback('voiceStatus', function(data, cb)
    if data and data.listening ~= nil then
        state.isVoiceListening = data.listening == true
    end

    if data and data.error and data.error ~= "" then
        ESX.ShowNotification("Voice input error: " .. tostring(data.error), "error")
    end

    cb('ok')
end)

RegisterNUICallback('processVoiceAudio', function(data, cb)
    local audioLen = data.audio and string.len(data.audio) or 0
    print("^3[NPCI DEBUG] processVoiceAudio callback fired, audio length: " .. tostring(audioLen) .. "^7")
    if data.audio and data.audio ~= "" then
        TriggerServerEvent('npci_server:transcribeVoice', data.audio)
    else
        print("^1[NPCI STT] Client received an empty audio buffer from NUI.^7")
    end
    cb('ok')
end)

RegisterNUICallback('nui_log', function(data, cb)
    print("^1[NUI " .. tostring(data.level) .. "] " .. tostring(data.message) .. "^7")
    cb('ok')
end)

RegisterNetEvent('npci_client:serverDebugLog')
AddEventHandler('npci_client:serverDebugLog', function(message)
    print(message)
end)

RegisterNetEvent('npci_client:runNpcCommand')
AddEventHandler('npci_client:runNpcCommand', function(cmd)
    if state.currentNpc and DoesEntityExist(state.currentNpc) then
        ExecuteNpcCommand(state.currentNpc, cmd)
    end
end)

-- Teleport NPC to player (used for SMS meetup requests)
RegisterNetEvent('npci_client:meetPlayer')
AddEventHandler('npci_client:meetPlayer', function(npcIdOrName, destKey, destX, destY, destZ)
    if type(npcIdOrName) ~= 'string' or npcIdOrName == '' then
        ESX.ShowNotification("~y~NPC not nearby for meetup.", "info")
        return
    end

    local npc = nil
    if state.currentNpc and DoesEntityExist(state.currentNpc)
        and (state.currentNpcData.id == npcIdOrName or state.currentNpcData.name == npcIdOrName) then
        npc = state.currentNpc
    end

    if not npc then
        for ped, data in pairs(ActiveAIPeds or {}) do
            if DoesEntityExist(ped) and (data.stateBagId == npcIdOrName or data.id == npcIdOrName or data.name == npcIdOrName) then
                npc = ped
                break
            end
        end
    end

    if not npc then
        local playerCoords = GetEntityCoords(PlayerPedId())
        for _, ped in ipairs(GetGamePool('CPed')) do
            if DoesEntityExist(ped) and not IsPedAPlayer(ped) and not IsEntityDead(ped) then
                local st = Entity(ped).state
                if (st.npci_id == npcIdOrName or st.npci_name == npcIdOrName)
                    and #(GetEntityCoords(ped) - playerCoords) < 150.0 then
                    npc = ped
                    break
                end
            end
        end
    end

    if not npc or not DoesEntityExist(npc) then
        ESX.ShowNotification("~y~NPC not nearby for meetup.", "info")
        return
    end
    local pCoords = GetEntityCoords(PlayerPedId())
    local offsetX = math.random(-40, 40)
    local offsetY = math.random(-40, 40)
    local meetCoords = vector3(destX + offsetX, destY + offsetY, destZ)
    ClearPedTasksImmediately(npc)
    SetEntityCoords(npc, meetCoords.x, meetCoords.y, meetCoords.z, false, false, false, true)
    FreezeEntityPosition(npc, true)
    CreateThread(function()
        Wait(500)
        if DoesEntityExist(npc) then
            FreezeEntityPosition(npc, false)
            TaskGoToCoordAnyMeans(npc, destX, destY, destZ, 1.0, 0, 0, 786603, 0xbf800000)
        end
    end)
    ESX.ShowNotification(("~g~NPC heading to ~y~%s~s~ (within 40m of you)"):format(destKey:gsub("_", " "):gsub("^%l", string.upper)), "info")
end)

-- Periodic re-application of NPC blocking flags during interaction
local lastBlockReapply = 0
local lastDriverSeatEnforce = 0
local lastDriverAntiJack = 0
local lastTargetNpcCheck = 0
local cachedTargetNpc = nil

-- Throttled GetTargetNpc - runs max 10 times per second instead of every frame
local function GetTargetNpcThrottled()
    local now = GetGameTimer()
    if now - lastTargetNpcCheck < 100 then
        return cachedTargetNpc
    end
    lastTargetNpcCheck = now
    cachedTargetNpc = GetTargetNpc()
    return cachedTargetNpc
end

-- Interaction logic thread (runs at 100ms intervals, NOT every frame)
CreateThread(function()
    while true do
        Wait(100)

        if not IsCompanionExtrasEnabled() and state.isCompanion then
            state.isCompanion = false
            state.companionVehicle = 0
            state.wasInVehicle = false
            state.companionCombatTarget = nil
        end

        if not IsDrivingExtrasEnabled() and state.npcIsDriver then
            ResetDriverState()
        end

        -- Distance check for active interaction
        if state.isInteracting and state.currentNpc then
            if DoesEntityExist(state.currentNpc) then
                local npc = state.currentNpc
                local pCoords = GetEntityCoords(PlayerPedId())
                local nCoords = GetEntityCoords(npc)
                local dist = #(pCoords - nCoords)
                if dist > 25.0 and not state.isCompanion then
                    ESX.ShowNotification("Interaction ended: Walked too far away (>25m).", "error")
                    StopInteraction()
                end

                local now = GetGameTimer()
                if now - lastBlockReapply > 2000 then
                    lastBlockReapply = now
                    SetBlockingOfNonTemporaryEvents(npc, true)
                    SetPedFleeAttributes(npc, 0, 0)
                    for _, mn in ipairs(state.multiNpcs) do
                        if DoesEntityExist(mn) then
                            SetBlockingOfNonTemporaryEvents(mn, true)
                            SetPedFleeAttributes(mn, 0, 0)
                        end
                    end
                end
            else
                StopInteraction()
            end
        end

        -- Driver seat lockdown: keep player as passenger and NPC as driver
        if IsDrivingExtrasEnabled() and state.npcIsDriver and state.driverNpc and DoesEntityExist(state.driverNpc) then
            local now = GetGameTimer()
            local playerD = PlayerPedId()
            local npcD = state.driverNpc

            if now - lastDriverAntiJack > 2000 then
                lastDriverAntiJack = now
                SetPedCanBeDraggedOut(npcD, false)
                SetPedStayInVehicleWhenJacked(npcD, true)
                local group = GetPedGroupIndex(playerD)
                if group == 0 or group == 255 then
                    group = GetPedGroupIndex(npcD)
                    if group == 0 or group == 255 then group = 0 end
                end
                SetPedAsGroupMember(npcD, group)
                SetPedAsGroupLeader(playerD, group)
                SetGroupSeparationRange(group, 1.9, 0.8)
            end

            if now - lastDriverSeatEnforce >= 200 then
                lastDriverSeatEnforce = now
                local npcVehD = GetVehiclePedIsIn(npcD, false)
                local playerVehD = GetVehiclePedIsIn(playerD, false)

                if npcVehD ~= 0 and playerVehD == npcVehD then
                    local playerSeat = GetPedSeatInVehicle(playerD, npcVehD)
                    if playerSeat and playerSeat >= 0 then
                        state.driverPassengerSeat = playerSeat
                    end

                    if GetIsTaskActive(playerD, 165) then
                        local moved, seat = ForcePlayerIntoPassengerSeat(playerD, npcVehD, state.driverPassengerSeat)
                        if moved and seat and seat >= 0 then
                            state.driverPassengerSeat = seat
                        end
                    end

                    local driverNow = GetPedInVehicleSeat(npcVehD, -1)
                    if driverNow == playerD then
                        local moved, seat = ForcePlayerIntoPassengerSeat(playerD, npcVehD, state.driverPassengerSeat)
                        if moved then
                            if seat and seat >= 0 then
                                state.driverPassengerSeat = seat
                            end
                            SetPedIntoVehicle(npcD, npcVehD, -1)
                        end
                    elseif driverNow ~= npcD then
                        SetPedIntoVehicle(npcD, npcVehD, -1)
                    end
                end
            end
        end

        -- Fallback: clear stuck PTT if not interacting
        if not state.isInteracting and state.voicePttHeld then
            state.voicePttHeld = false
    SendNUIMessage({ action = 'stopAudio' })
    SendNUIMessage({ action = 'ptt_stop' })
        end
    end
end)

-- 3D rendering thread (runs every frame only for drawing)
CreateThread(function()
    while true do
        Wait(0)
        local targetNpc = GetTargetNpcThrottled()
        if targetNpc then
            local c = GetEntityCoords(targetNpc)
            if not state.isInteracting or state.currentNpc == targetNpc then
                local promptText = state.isInteracting and "[E] Stop Talk" or "[E] Talk"
                DrawText3D(c.x, c.y, c.z + 1.0, promptText)
            elseif state.isInteracting and state.currentNpc ~= targetNpc then
                local isInMulti = false
                for _, mn in ipairs(state.multiNpcs) do
                    if mn == targetNpc then isInMulti = true break end
                end
                if not isInMulti then
                    local multiText = IsAdminOrPremium() and "[Y] Add to conversation" or ""
                    if multiText ~= "" then
                        DrawText3D(c.x, c.y, c.z + 1.6, multiText)
                    end
                end
            end
        end
    end
end)

-- Proactive monitor: crash detection + idle timeout during active conversations
CreateThread(function()
    local IDLE_TIMEOUT = 180000
    local lastKnownVehHealth = 1000.0
    local lastProactiveVeh = 0
    while true do
        Wait(200)
        if state.isInteracting and state.currentNpc and DoesEntityExist(state.currentNpc) then
            local npc = state.currentNpc
            local currentVeh = GetVehiclePedIsIn(npc, false)

            -- Crash detection
            if currentVeh ~= 0 then
                local currentHealth = GetVehicleEngineHealth(currentVeh)
                if currentVeh ~= lastProactiveVeh then
                    -- New vehicle: seed baseline so an already-damaged vehicle
                    -- doesn't register as a crash on the first tick
                    lastProactiveVeh = currentVeh
                    lastKnownVehHealth = currentHealth
                else
                    local healthDelta = lastKnownVehHealth - currentHealth
                    if healthDelta > 50.0 then
                        lastKnownVehHealth = currentHealth
                        state.lastInteractionTime = GetGameTimer()
                        local netId = NetworkGetNetworkIdFromEntity(npc)
                        TriggerServerEvent('npci_server:proactiveReaction', netId, 'VEHICLE_CRASH', state.currentNpcData)
                    else
                        lastKnownVehHealth = currentHealth
                    end
                end
            else
                lastProactiveVeh = 0
            end

            -- Idle timeout
            if state.lastInteractionTime > 0 and (GetGameTimer() - state.lastInteractionTime) >= IDLE_TIMEOUT then
                state.lastInteractionTime = GetGameTimer()
                local netId = NetworkGetNetworkIdFromEntity(npc)
                TriggerServerEvent('npci_server:proactiveReaction', netId, 'PLAYER_SILENT', state.currentNpcData)
            end
        end
    end
end)

-- Register /t command as a 100% reliable fallback for text chat
RegisterCommand('t', function(source, args, rawCommand)
    local text = rawCommand:sub(3) -- Get everything after '/t '
    if text and text ~= "" then
        if state.isInteracting then
            HandleInput(text)
        else
            ESX.ShowNotification("You are not in an active AI NPC conversation. Press E on an NPC first.", "error")
        end
    end
end, false)

-- Fix brightness if stuck dark from a timecycle modifier (e.g., spectator5 from passing out)
RegisterCommand('fixlight', function()
    ClearTimecycleModifier()
    SetTimecycleModifierStrength(0.0)
    ClearExtraTimecycleModifier()
    SetWeatherTypeNow('CLEAR')
    SetWeatherTypeNowPersist('CLEAR')
    SetArtificialLightsState(false)
    SetNuiFocus(false, false)
    SetClockTime(12, 0, 0)
    ESX.ShowNotification('~g~Brightness, UI focus, and weather reset')
end, false)

-- Auto-clear timecycle modifiers on spawn (prevents stuck spectator5/REDMIST_blend)
AddEventHandler('esx:onPlayerSpawn', function()
    ClearTimecycleModifier()
    SetTimecycleModifierStrength(0.0)
    ClearExtraTimecycleModifier()
end)

-- Y key to add a targeted NPC into the active multi-conversation
RegisterCommand('npci_multi_add', function()
    if not state.isInteracting then
        ESX.ShowNotification("Start a conversation first (E on an NPC).", "error")
        return
    end
    if not IsAdminOrPremium() then
        ESX.ShowNotification("~r~You do not have permission to add multiple NPCs.", "error")
        return
    end
    local addNpc = GetTargetNpc()
    if not addNpc then
        ESX.ShowNotification("~y~Look at an NPC to add them.", "info")
        return
    end
    AddMultiNpcToConversation(addNpc)
end, false)
RegisterKeyMapping('npci_multi_add', 'Add NPC to conversation', 'keyboard', 'y')

-- E key to start/stop interaction (polled via command instead of per-frame loop)
RegisterCommand('npci_interact', function()
    if state.isInteracting then
        StopInteraction()
    else
        local npc = GetTargetNpcThrottled()
        if npc then
            StartInteraction(npc)
        end
    end
end, false)
RegisterKeyMapping('npci_interact', 'Talk to NPC / Stop Talking', 'keyboard', 'e')

-- Local handler for text chat messages (runs client-side)
AddEventHandler('chatMessage', function(source, author, text)
    if text:sub(1, 1) == '/' then return end
    if state.isInteracting then
        CancelEvent()
        HandleInput(text)
    end
end)

function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = GetScreenCoordFromWorldCoord(x, y, z)
    if onScreen then
        SetTextScale(0.35, 0.35); SetTextFont(4); SetTextProportional(1); SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING"); SetTextCentre(1); AddTextComponentString(text); DrawText(_x, _y)
    end
end

-- ============================================================================
--                   NPCI CLIENT COMMAND & COMPANION ENGINE
-- ============================================================================

local commandTriggers = {
    { cmd = "hands_up", phrases = {"put your hands up", "get your hands up", "keep your hands up", "hands up"} },
    { cmd = "get_on_knees", phrases = {"get on your knees", "kneel down"} },
    { cmd = "lay_on_ground", phrases = {"lay on the ground", "get on the ground", "palms out", "do not move"} },
    { cmd = "sit_down", phrases = {"have a seat", "sit down", "go sit down over there", "take a seat", "take your seat", "please sit down"} },
    { cmd = "get_up", phrases = {"get up", "get to your feet", "stand up", "put your hands down", "you can stop now"} },
    { cmd = "step_out_vehicle", phrases = {"step out of the vehicle", "get out of the vehicle", "get off the bike", "exit the bike", "step out", "exit the vehicle", "get out", "getout"} },
    { cmd = "get_in_vehicle", phrases = {"get back in the vehicle", "get back on the bike", "sit in the vehicle", "get in my car", "get in the car", "let's go for a ride", "get in the vehicle", "sit in", "get back in your vehicle", "get back in your car"} },
    { cmd = "help_me_out", phrases = {"help me out", "helpmeout", "cover me", "fight with me", "back me up"} },
    { cmd = "run_away", phrases = {"get out of here", "get the fuck out of here", "move faster", "leave now", "get lost"} },
    { cmd = "pushups", phrases = {"drop down and give me twenty", "do some pushups", "do some push-ups"} },
    { cmd = "situps", phrases = {"do some sit-ups", "do some situps"} },
    { cmd = "dance", phrases = {"dance for me", "bust a move"} },
    { cmd = "jog", phrases = {"jog for me", "jog in place"} },
    { cmd = "go_to_point", phrases = {"go stand over there", "go to where i'm pointing", "go there", "go over there", "get against the wall", "get against my vehicle", "drive over there", "drive to where i'm pointing"} },
    { cmd = "taser", phrases = {"taser", "you're gonna get tased"} },
    { cmd = "delete", phrases = {"delete", "clear", "remove"} },
    { cmd = "dismiss", phrases = {"we're done here", "you're free to go", "take care", "you can go now", "go home"} },
    { cmd = "wait_here", phrases = {"wait here", "stay here", "stay put", "hold still", "don't move", "hold your position", "stand by"} },
    { cmd = "crouch", phrases = {"crouch down", "crouch", "get low", "get down low", "duck down"} },
    { cmd = "lean", phrases = {"lean against the wall", "lean", "lean on the wall", "lean against that"} },
    { cmd = "smoke", phrases = {"light a cigarette", "smoke a cigarette", "have a smoke", "smoke", "light one up"} },
    { cmd = "face_me", phrases = {"face me", "look at me", "turn to face me"} },
    { cmd = "turn_around", phrases = {"turn around", "face away from me", "turn your back", "look the other way"} },
    { cmd = "hands_behind_back", phrases = {"hands behind your back", "put your hands behind your back", "hands behind back", "cuff up", "hands behind ya back"} },
    { cmd = "use_phone", phrases = {"get on your phone", "use your phone", "call someone", "make a call", "check your phone", "use phone"} },
    { cmd = "wave", phrases = {"wave", "wave at me", "say hello", "wave your hand"} },
    { cmd = "guard_area", phrases = {"stand guard", "guard this area", "keep watch", "watch for cops", "lookout", "guard duty"} },
    { cmd = "drink", phrases = {"have a drink", "take a drink", "drink something", "drink", "take a shot"} },
    { cmd = "salute", phrases = {"salute", "salute me", "show respect"} },
    { cmd = "stop", phrases = {"stop what you're doing", "stop that", "at ease", "cut it out", "stop"} },
    { cmd = "lap_dance", phrases = {"give me a lap dance", "do a lap dance", "lap dance", "be kinky", "sexy dance", "dance sexy", "strip for me"} },
    { cmd = "beg", phrases = {"beg for money", "beg for your life", "beg", "beg me", "cry for help", "plead"} },
    { cmd = "listen_at_door", phrases = {"listen at the door", "listen at that door", "put your ear to the door", "listen at the wall"} },
    { cmd = "take_photo", phrases = {"take a photo", "take a selfie", "take a picture", "snap a photo", "selfie"} },
    { cmd = "stretch", phrases = {"stretch your body", "stretch out", "stretch", "loosen up"} },
    { cmd = "meditate", phrases = {"meditate", "do some yoga", "yoga", "clear your mind", "relax"} },
    { cmd = "flex", phrases = {"flex your muscles", "flex", "show off", "show your muscles", "pump up"} },
    { cmd = "point", phrases = {"point forward", "point that way", "point over there", "point", "point ahead"} },
    { cmd = "lay_on_bed", phrases = {"lay on the bed", "lay on bed", "get on the bed", "lay down on the bed", "go to bed", "sleep on the bed", "lie down on the bed"} },
    { cmd = "sexy", phrases = {"sexy moves", "sexy dance", "be sexy", "do something sexy", "seduce me", "get sexy"} },
    { cmd = "blow_me", phrases = {"blow me", "suck my dick", "give me head", "blowjob", "suck me off"} },
    { cmd = "make_babies", phrases = {"lets do babys", "let's do babys", "lets make babies", "let's make babies", "have sex", "lets fuck", "make love", "fuck me"} }
}

local function EscapeLuaPattern(s)
    return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

function ParseCommandText(text)
    local lowerText = string.lower(text)
    for _, item in ipairs(commandTriggers) do
        for _, phrase in ipairs(item.phrases) do
            local pattern = "%f[%a]" .. EscapeLuaPattern(string.lower(phrase)) .. "%f[%A]"
            if string.find(lowerText, pattern) then
                if IsSubscriptionLockedCommand(item.cmd) then
                    ESX.ShowNotification("~y~This feature is reserved for subscription extras.", "info")
                    return "__feature_locked__"
                end
                return item.cmd
            end
        end
    end
    return nil
end

function GetCrosshairCoords()
    local player = PlayerPedId()
    local camRot = GetGameplayCamRot(2)
    local camCoords = GetGameplayCamCoord()
    local forward = RotationToDirection(camRot)
    local target = camCoords + (forward * 50.0)
    local ray = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, target.x, target.y, target.z, -1, player, 0)
    local _, hit, endCoords, _, _ = GetShapeTestResult(ray)
    if hit then return endCoords end
    return nil
end

function RotationToDirection(rotation)
    local adjustedRotation = {
        x = (math.pi / 180) * rotation.x,
        y = (math.pi / 180) * rotation.y,
        z = (math.pi / 180) * rotation.z
    }
    local direction = {
        x = -math.sin(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        y = math.cos(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        z = math.sin(adjustedRotation.x)
    }
    return vector3(direction.x, direction.y, direction.z)
end

-- Seat/chair/sofa detection for intelligent sitting
local SeatPropModels = {
    -- Chairs
    "prop_chair_01","prop_chair_02","prop_chair_03","prop_chair_04","prop_chair_05",
    "prop_chair_06","prop_chair_07","prop_chair_08","prop_chair_09","prop_chair_10",
    "prop_off_chair_01","prop_off_chair_02","prop_off_chair_03","prop_off_chair_04","prop_off_chair_05",
    "prop_diner_chair_01","prop_direct_chair_01",
    "prop_waiting_seat_01","prop_waiting_bench_01",
    "prop_rock_chair_01","prop_thron_01","prop_deckchair","prop_wheelchair_01",
    "prop_bar_stool_01",
    -- Benches
    "prop_bench_01","prop_bench_02","prop_bench_03","prop_bench_04","prop_bench_05",
    "prop_bench_06","prop_bench_07","prop_bench_08","prop_bench_09","prop_bench_10","prop_bench_11",
    -- Sofas / couches
    "prop_sofa_01","prop_sofa_02","prop_sofa_03",
    "prop_couch_01","prop_couch_02","prop_couch_03","prop_couch_04",
    "prop_armchair_01",
    -- Interior high-detail
    "v_ilev_chair02_ped","v_res_tre_chair","v_res_tre_sofa",
    "v_res_tre_sofa_mess_a","v_res_tre_sofa_mess_b","v_res_tre_sofa_mess_c",
    -- Picnic table
    "prop_picnictable_01",
}
local SeatPropHashes = nil
local BedPropHashes = nil

function GetPropHashes(modelNames, cacheRef)
    if cacheRef and next(cacheRef) then return cacheRef end
    local hashes = {}
    for _, name in ipairs(modelNames) do
        hashes[GetHashKey(name)] = true
    end
    if cacheRef then
        for k, v in pairs(hashes) do cacheRef[k] = v end
    end
    return hashes
end

function FindClosestPropByHashes(npc, radius, hashes)
    return FindClosestPropByHashesAt(GetEntityCoords(npc), radius, hashes)
end

function FindClosestPropByHashesAt(coords, radius, hashes)
    local closestDist = radius + 1.0
    local closestObj = nil
    local objects = GetGamePool('CObject')
    for _, obj in ipairs(objects) do
        if DoesEntityExist(obj) then
            local model = GetEntityModel(obj)
            if hashes[model] then
                local objCoords = GetEntityCoords(obj)
                local dist = #(coords - objCoords)
                if dist < radius and dist < closestDist then
                    closestDist = dist
                    closestObj = obj
                end
            end
        end
    end
    if closestObj then
        return GetEntityCoords(closestObj), GetEntityHeading(closestObj), closestObj
    end
    return nil, nil, nil
end

local BedPropModels = {
    "prop_bed_01","prop_bed_02","prop_bed_03","prop_bed_04","prop_bed_05",
    "prop_bed_06","prop_bed_07","prop_bed_08",
    "v_res_tre_bed","v_res_tre_bed1","v_ilev_ta_bed","v_res_tre_bed2",
    "prop_mattress_01",
    "v_ilev_trev_bed",
}

function FindClosestSeatCoords(npc, radius)
    local hashes = GetPropHashes(SeatPropModels, SeatPropHashes)
    local coords, heading, obj = FindClosestPropByHashes(npc, radius, hashes)
    return coords, heading, obj
end

function FindClosestSeatCoordsAt(coords, radius)
    local hashes = GetPropHashes(SeatPropModels, SeatPropHashes)
    return FindClosestPropByHashesAt(coords, radius, hashes)
end

-- Pick the scenario that matches a seat prop (mirrors the /sit_down command logic)
function SeatScenarioForSeatProp(seatObj)
    local scenario = "PROP_HUMAN_SEAT_BENCH"
    if seatObj and DoesEntityExist(seatObj) then
        local sModel = GetEntityModel(seatObj)
        if sModel == GetHashKey("prop_bar_stool_01") or sModel == GetHashKey("v_club_bahbarstool") then
            scenario = "PROP_HUMAN_SEAT_BAR"
        elseif sModel == GetHashKey("prop_sofa_01") or sModel == GetHashKey("prop_sofa_02") or sModel == GetHashKey("prop_sofa_03")
            or sModel == GetHashKey("prop_couch_01") or sModel == GetHashKey("prop_couch_02") or sModel == GetHashKey("prop_couch_03")
            or sModel == GetHashKey("prop_couch_04") or sModel == GetHashKey("prop_armchair_01") then
            scenario = "PROP_HUMAN_SEAT_BENCH"
        elseif sModel == GetHashKey("v_club_baham_bckt_chr") or sModel == GetHashKey("prop_chair_01") or sModel == GetHashKey("prop_chair_02") then
            scenario = "PROP_HUMAN_SEAT_CHAIR"
        end
    end
    return scenario
end

-- Pose detection: pelvis height above the ped's entity origin.
-- ~0.95 standing / ~0.55-0.65 sitting on a bench / ~0.45 sitting on ground.
function IsPedSittingPose(ped)
    if not DoesEntityExist(ped) then return false end
    local ok, pelvis = pcall(function()
        return GetWorldPositionOfEntityBone(ped, GetPedBoneIndex(ped, 0x2E28))
    end)
    if not ok or not pelvis then return false end
    local origin = GetEntityCoords(ped)
    return (pelvis.z - origin.z) < 0.75
end

function FindClosestBedCoords(npc, radius)
    local hashes = GetPropHashes(BedPropModels, BedPropHashes)
    return FindClosestPropByHashes(npc, radius, hashes)
end

-- Weather/zone caches for GetPlayerContext (refreshed every 10s)
local cachedWeather = "CLEAR"
local cachedZoneName = "Los Santos"
local cachedStreetName = "Unknown Street"
local lastContextCacheRefresh = 0

local classNames = {"Compact","Sedan","SUV","Coupe","Muscle","Sports Classic","Sports","Super","Motorcycle","Off-road","Industrial","Utility","Van","Cycle","Boat","Helicopter","Plane","Service","Emergency","Military","Commercial","Train"}

function GetPlayerContext()
    local ctx = {}
    local player = PlayerPedId()
    local coords = GetEntityCoords(player)

    local now = GetGameTimer()
    if now - lastContextCacheRefresh > 10000 then
        lastContextCacheRefresh = now
        local success, weatherHash = pcall(GetWeatherTypeTransition)
        if success and type(weatherHash) == "number" and WeatherHashes[weatherHash] then
            cachedWeather = WeatherHashes[weatherHash]
        else
            cachedWeather = "CLEAR"
        end
        local streetHash, _ = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
        cachedStreetName = GetStreetNameFromHashKey(streetHash) or "Unknown Street"
        local zoneKey = GetNameOfZone(coords.x, coords.y, coords.z)
        local zn = zones[zoneKey] or GetLabelText(zoneKey)
        if zn == "NULL" or zn == "" then zn = zoneKey or "Los Santos" end
        cachedZoneName = zn
    end

    ctx.environment = {}
    ctx.environment.weather = cachedWeather
    local hour, minute = GetClockHours(), GetClockMinutes()
    ctx.environment.time = string.format("%02d:%02d", hour, minute)
    if hour < 6 then ctx.environment.timeOfDay = "Night"
    elseif hour < 12 then ctx.environment.timeOfDay = "Morning"
    elseif hour < 18 then ctx.environment.timeOfDay = "Afternoon"
    else ctx.environment.timeOfDay = "Evening" end
    local interior = GetInteriorFromEntity(player)
    ctx.environment.isInterior = interior ~= 0
    ctx.environment.street = cachedStreetName
    ctx.environment.zone = cachedZoneName

    local veh = GetVehiclePedIsIn(player, false)
    if veh ~= 0 then
        local model = GetEntityModel(veh)
        local modelName = GetDisplayNameFromVehicleModel(model)
        local primaryColor, _ = GetVehicleColours(veh)
        local class = GetVehicleClass(veh)
        local bodyHealth = GetVehicleBodyHealth(veh)
        local engineHealth = GetVehicleEngineHealth(veh)
        local dirt = GetVehicleDirtLevel(veh)
        ctx.vehicle = {
            model = modelName,
            color = VehicleColors[primaryColor] or "Unknown",
            class = classNames[class] or "Vehicle",
            damage = math.max(0, math.min(100, math.floor((1000 - bodyHealth) / 10))),
            engineDamage = math.max(0, math.min(100, math.floor((1000 - engineHealth) / 10))),
            cleanliness = math.max(0, math.min(100, math.floor((1 - dirt) * 100))),
            -- WHO DRIVES: makes seat ownership explicit so the NPC never flips
            -- "player is in my car" into "the player must be driving, so I'm a passenger"
            seat = (GetPedInVehicleSeat(veh, -1) == player) and "driver" or "passenger",
            seatMap = GetVehicleSeatMap(veh, state.currentNpc or 0)
        }

        local radioIdx = GetPlayerRadioStationIndex()
        if radioIdx ~= 255 and RadioStations[radioIdx] then
            ctx.radio = { station = RadioStations[radioIdx] }
        end
    end

    local weapon = GetSelectedPedWeapon(player)
    if weapon ~= 0 and weapon ~= GetHashKey("WEAPON_UNARMED") then
        ctx.weapon = {
            name = WeaponNames[weapon] or "Unknown Weapon",
            isDrawn = IsPedArmed(player, 4) or IsPlayerFreeAiming(PlayerId())
        }
    end

    if state.isInteracting and #state.multiNpcs > 0 then
        local present = {}
        for _, mn in ipairs(state.multiNpcs) do
            if DoesEntityExist(mn) then
                local mnData = state.multiNpcData[mn]
                table.insert(present, { name = mnData and mnData.name or "Unknown", role = mnData and mnData.role or "Civilian", gender = mnData and mnData.gender or "Unknown", mood = mnData and mnData.mood or "indifferent" })
            end
        end
        if #present > 0 then
            ctx.multiNpcsPresent = present
        end
    end

    ctx.isInCombat = IsPedInCombat(player, -1)
    ctx.isAiming = IsPlayerFreeAiming(PlayerId())
    ctx.health = GetEntityHealth(player)

    return ctx
end

-- ============================================================================
-- LIVING WORLD HELPERS (T1-A schedule, T1-B scenarios, T2-H weather, T3-I needs)
-- ============================================================================

-- Game-clock phase for a role: WORK / OFF / NIGHT (handles shifts that wrap midnight)
function GetGamePhase(role)
    local S = Config.NpcSchedule
    if not (S and S.Enabled) then return "WORK" end
    local rule = (role and S.Roles and S.Roles[role]) or S.Default
    if not rule then return "WORK" end
    local h = GetClockHours()
    local function inRange(a, b)
        if a == nil or b == nil then return false end
        if a == b then return false end
        if a < b then return h >= a and h < b end
        return h >= a or h < b -- wraps midnight (e.g. 20-4)
    end
    if inRange(rule.sleepStart, rule.sleepEnd) then return "NIGHT" end
    if inRange(rule.workStart, rule.workEnd) then return "WORK" end
    return "OFF"
end

function IsBadWeather()
    local wb = Config.WeatherBehavior
    if not (wb and wb.Enabled) then return false end
    return wb.RainyWeathers and wb.RainyWeathers[string.upper(cachedWeather or "CLEAR")] == true
end

-- Phase + role + weather + needs aware activity picker (T1-B + T3-I)
function PickArrivalScenario(ped, pedData)
    local A = Config.ArrivalActivities or {}
    local role = (pedData and pedData.role) or "Civilian"
    local phase = GetGamePhase(role)
    local roleScn = Config.RoleScenarios and Config.RoleScenarios[role] or nil

    -- Needs pull strongest (T3-I)
    if Config.Needs and Config.Needs.Enabled and pedData and pedData.needs then
        local n = pedData.needs
        if (n.hunger or 100) <= (Config.Needs.HungryThreshold or 30) and A.Hungry then
            return A.Hungry[math.random(#A.Hungry)]
        end
        if (n.energy or 100) <= (Config.Needs.LowEnergyThreshold or 30) and A.LowEnergy then
            return A.LowEnergy[math.random(#A.LowEnergy)]
        end
    end

    local pool
    if phase == "NIGHT" and A.Sleep then
        pool = A.Sleep
    elseif IsBadWeather() and A.Rain then
        pool = A.Rain
    elseif phase == "NIGHT" and A.Night and math.random(1, 100) <= 60 then
        pool = A.Night
    end

    if not pool and roleScn then
        if phase == "WORK" and roleScn.work then
            pool = roleScn.work
        elseif phase ~= "WORK" and roleScn.casual then
            pool = roleScn.casual
        end
    end

    if not pool then
        if phase == "WORK" and A.FallbackWork then
            pool = A.FallbackWork
        else
            pool = A.FallbackCasual or A.FallbackWork or { "WORLD_HUMAN_STAND_MOBILE" }
        end
    end
    return pool[math.random(#pool)]
end

-- Seat-aware scenario start: bench/chair pools snap to a real seat prop (T1-B)
function StartScenarioSmart(ped, scenario)
    if not DoesEntityExist(ped) then return end
    scenario = scenario or "WORLD_HUMAN_STAND_MOBILE"
    if scenario == "PROP_HUMAN_SEAT_BENCH" or scenario == "PROP_HUMAN_SEAT_CHAIR" then
        local seatCoords, _, seatObj = FindClosestSeatCoordsAt(GetEntityCoords(ped), 4.0)
        if seatCoords then
            ClearPedTasks(ped)
            local seatScenario = SeatScenarioForSeatProp(seatObj)
            TaskStartScenarioAtCoords(ped, seatScenario, seatCoords.x, seatCoords.y, seatCoords.z,
                GetEntityHeading(seatObj or ped), 0, true, true, false)
            return
        end
        scenario = "WORLD_HUMAN_STAND_MOBILE" -- no seat nearby, never float-sit
    end
    TaskStartScenarioInPlace(ped, scenario, 0, true)
end

local scheduleNextCheck = {} -- [ped] = GetGameTimer() when the next check is allowed

-- Time-of-day scheduler (T1-A): walks idle peds home / to social spots / to work scenes
function ApplySchedule(ped, pedData, now, isTaskActive)
    local S = Config.NpcSchedule
    if not (S and S.Enabled) then return end
    if (scheduleNextCheck[ped] or 0) > now then return end
    scheduleNextCheck[ped] = now + math.random(45000, 75000)
    if not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then return end
    if pedData.isBusy or pedData.isInConversation or pedData.weatherHold or pedData.manualHold then return end
    if IsPedInAnyVehicle(ped, false) then return end

    local routine = pedData.routine or "WANDER"
    -- Only steer idle/standing peds; never yank someone mid errand (GO_TO_WORK etc.)
    if routine ~= "WANDER" and routine ~= "IDLE" and routine ~= "SCENARIO" then return end

    local phase = GetGamePhase(pedData.role)
    local rule = (S.Roles and S.Roles[pedData.role]) or S.Default
    if not rule then return end

    local function walkTo(spotKey)
        local c = GetLocationCoords(spotKey)
        if not c then return false end
        TaskGoToCoordAnyMeans(ped, c.x, c.y, c.z, 1.0, 0, 0, 786432, 0xbf800000)
        return true
    end

    local function issueScenario()
        pedData.routine = "SCENARIO"
        pedData.targetLocation = nil
        pedData.scenarioIssuedAt = now
        StartScenarioSmart(ped, PickArrivalScenario(ped, pedData))
    end

    -- Has their standing scenario died out (they stopped doing anything)?
    local scenarioDead = routine == "SCENARIO" and not isTaskActive
        and (pedData.scenarioIssuedAt or 0) + 120000 < now

    if phase == "NIGHT" then
        if pedData.phaseTag == "NIGHT" and not scenarioDead then return end
        pedData.phaseTag = "NIGHT"
        local home = rule.homeSpot or (S.Default and S.Default.homeSpot)
        if home and walkTo(home) then
            pedData.routine = "SOCIAL"
            pedData.targetLocation = home
        else
            issueScenario()
        end
    elseif phase == "WORK" then
        if pedData.phaseTag == "WORK" and not scenarioDead then return end
        pedData.phaseTag = "WORK"
        issueScenario()
    else -- OFF: social life - occasional relocation to hangout spots
        pedData.phaseTag = "OFF"
        if not IsBadWeather() and math.random(1, 100) <= (S.RelocationChance or 12) then
            local spots = rule.socialSpots or {}
            if #spots > 0 then
                local spot = spots[math.random(#spots)]
                if walkTo(spot) then
                    pedData.routine = "SOCIAL"
                    pedData.targetLocation = spot
                    return
                end
            end
        end
        if routine == "WANDER" or routine == "IDLE" or scenarioDead then
            issueScenario()
        end
    end
end

function DetectNpcDescription(role)
    local descs = {
        Police = "A disciplined officer in uniform, alert and watchful.",
        EMS = "A paramedic in uniform, calm and ready to help.",
        Firefighter = "A firefighter in gear, brave and focused.",
        ["Shop Personal"] = "A store worker in a retail outfit, polite and helpful.",
        ["Hotdog Guy"] = "A street vendor with a hotdog cart, friendly and chatty.",
        Guard = "A security guard in uniform, vigilant and serious.",
        Vagos = "A gang member in Vagos colors, loud and aggressive.",
        Grove = "A gang member in Grove Street colors, loyal and street-smart.",
        Ballas = "A gang member in Ballas colors, menacing and territorial.",
        ["Gang Member"] = "A street gang member, rough and unpredictable.",
        Inmate = "A convict in prison orange, hardened and wary.",
        ["Builder Guy"] = "A construction worker in a hard hat and vest, tough and hardworking.",
        ["Garbage Worker"] = "A sanitation worker in uniform, going about the daily grind.",
        ["Dock Worker"] = "A dock worker in sturdy clothes, used to heavy labor.",
        ["Airport Worker"] = "An airport employee in uniform, professional and efficient.",
        Lifeguard = "A lifeguard in red shorts, fit and vigilant.",
        ["Sexy Ped"] = "An attractive person in stylish clothes, confident and flirtatious.",
        ["Ugly Ped"] = "A rough-looking person, unkempt and unpleasant.",
        Homeless = "A homeless person in tattered clothes, desperate and weary.",
        ["Body Builder"] = "A muscular person in a tank top, strong and vain.",
        Junkie = "A strung-out addict, twitchy and erratic.",
        Biker = "A biker in leather, rugged and rebellious.",
        Hiker = "A hiker in outdoor gear, cheerful and energetic.",
        Golfer = "A golfer in polo and cap, relaxed and focused on the game.",
        Redneck = "A redneck in flannel, down-to-earth and suspicious of strangers.",
        Beachgoer = "A beach visitor in swimwear, laid-back and carefree.",
        Businessman = "A businessperson in a suit, polished and in a hurry.",
        Hipster = "A hipster in vintage clothes, ironic and pretentious.",
        Cultist = "A cult follower in robes, eerie and fanatical.",
        Athlete = "A sporty person in athletic wear, energetic and competitive.",
        ["Meth Cook"] = "A gaunt, paranoid cook, jittery and dangerous.",
        ["Drug Dealer"] = "A shady dealer in a hoodie, watching for cops.",
        Valet = "A valet in uniform, polite and eager to please.",
        Bartender = "A bartender in club attire, mixing drinks behind the bar.",
        Dancer = "A dancer in flashy clubwear, moving to the music.",
        ["Club DJ"] = "The club DJ at the turntables, focused on the mix.",
        ["Club-goer"] = "A club patron enjoying a night out, dancing and drinking.",
        Civilian = "An ordinary person going about their day.",
    }
    return descs[role] or "A regular person on the street."
end

function DetectContextChanges(oldCtx, newCtx)
    local changes = {}
    if not oldCtx or not next(oldCtx) then return changes end

    -- Vehicle changes
    local oldVeh = oldCtx.vehicle
    local newVeh = newCtx.vehicle
    if oldVeh and not newVeh then
        table.insert(changes, "Player exited their vehicle")
    elseif not oldVeh and newVeh then
        table.insert(changes, "Player entered a " .. newVeh.color .. " " .. newVeh.model)
    elseif oldVeh and newVeh and oldVeh.model ~= newVeh.model then
        table.insert(changes, "Player switched to a " .. newVeh.color .. " " .. newVeh.model)
    end

    -- Weapon changes
    local oldWep = oldCtx.weapon
    local newWep = newCtx.weapon
    if not oldWep and newWep then
        table.insert(changes, "Player drew a " .. newWep.name)
    elseif oldWep and not newWep then
        table.insert(changes, "Player holstered their weapon")
    elseif oldWep and newWep and oldWep.name ~= newWep.name then
        table.insert(changes, "Player switched to " .. newWep.name)
    end

    -- Combat changes
    if not oldCtx.isInCombat and newCtx.isInCombat then
        table.insert(changes, "Player entered combat")
    elseif oldCtx.isInCombat and not newCtx.isInCombat then
        table.insert(changes, "Player is no longer in combat")
    end

    return changes
end

local function EnterRaceMode(npc, veh)
    SetPedStayInVehicleWhenJacked(npc, true)
    SetDriverAbility(npc, 1.0)
    SetDriverAggressiveness(npc, 0.6)
    SetVehicleModKit(veh, 0)
    SetVehicleMod(veh, 11, 3, false)
    SetVehicleMod(veh, 12, 2, false)
    SetVehicleMod(veh, 13, 2, false)
    SetVehicleMod(veh, 16, 2, false)
    SetVehicleWheelType(veh, 7)
    -- Try to drive to player's GPS waypoint first for destination-based racing
    local wpCoords = GetWaypointCoords()
    if wpCoords and (wpCoords.x ~= 0.0 or wpCoords.y ~= 0.0) then
        SetDriveTaskDrivingStyle(npc, 786468)
        TaskVehicleDriveToCoordLongrange(npc, veh, wpCoords.x, wpCoords.y, wpCoords.z, 60.0, 786468, 20.0)
    else
        SetDriveTaskDrivingStyle(npc, 786468)
        TaskVehicleDriveWander(npc, veh, 60.0, 786468)
    end
    state.npcIsDriver = true
    state.driverNpc = npc
    state.isCompanion = true
    state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
    state.companionVehicle = veh
    state.wasInVehicle = true
    state.drivingMode = "race"
    state.drivingSpeed = 60.0
    ESX.ShowNotification("~g~[RACE]~s~ NPC enters racer mode!", "success")
end

local STRIPPED_COMMANDS = {
    follow_me = true, lead_the_way = true, stop_following = true,
    companion = true, leave_companion = true,
    you_drive = true, stop_driving = true, drive_go = true, drive_stop = true,
    slow_down = true, escape_cops = true, lets_race = true, land_here = true
}
function ExecuteNpcCommand(npc, cmd)
    if cmd and STRIPPED_COMMANDS[cmd] then return end
    if not DoesEntityExist(npc) then return end
    
    local npcVehicle = GetVehiclePedIsIn(npc, false)
    local inVehicle = npcVehicle ~= 0

    -- T4: player-command hold. Wait/guard/pose commands keep ownership of the ped
    -- (manualHold) until a movement command or an AI-issued route takes over; the
    -- background life loop, shelter/initiative/incident threads and the
    -- StopInteraction release all check the flag so they never stomp a command.
    local holdCmds = {
        wait_here = true, stop = true, stop_following = true, get_up = true,
        guard_area = true, sit_down = true, hands_up = true, get_on_knees = true,
        lay_on_ground = true, crouch = true, lean = true, smoke = true,
        face_me = true, turn_around = true, hands_behind_back = true,
        use_phone = true, beg = true, listen_at_door = true, meditate = true,
        drink = true, take_photo = true, stretch = true, lap_dance = true,
        dance = true, pushups = true, situps = true, run_away = true,
        flex = true, sexy = true, lay_on_bed = true,
        blow_me = true, make_babies = true
    }
    local releaseCmds = {
        follow_me = true, lead_the_way = true, help_me_out = true,
        go_to_point = true, get_in_vehicle = true, step_out_vehicle = true,
        companion = true, leave_companion = true, you_drive = true,
        stop_driving = true, drive_go = true, drive_stop = true,
        slow_down = true, land_here = true, escape_cops = true,
        lets_race = true, dismiss = true, delete = true
    }
    local followCmds = { follow_me = true, help_me_out = true, companion = true }
    local pedData0 = ActiveAIPeds[npc]
    if pedData0 then
        if releaseCmds[cmd] then
            pedData0.manualHold = nil
            pedData0.weatherHold = nil
        elseif holdCmds[cmd] then
            pedData0.manualHold = true
            pedData0.weatherHold = nil
        end
    end
    if followCmds[cmd] and (npc == state.currentNpc or state.followNpc == nil) then
        if state.followNpc and state.followNpc ~= npc and DoesEntityExist(state.followNpc) then
            ClearPedTasksImmediately(state.followNpc)
        end
        state.explicitFollow = true
        state.followNpc = npc
    end

    -- Special case: in-vehicle animation, don't clear tasks (which would kick NPC out)
    if cmd == "blow_me" or cmd == "make_babies" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        state.helpMeOut = false
        if inVehicle then
            local dict, anim
            if cmd == "blow_me" then
                dict = "oddjobs@towing"
                anim = "f_blow_job_loop"
            else
                dict = "mini@prostitutes@sexlow_veh"
                anim = "low_car_sex_loop_female"
            end
            RequestAnimDict(dict)
            for _ = 1, 50 do
                if HasAnimDictLoaded(dict) then break end
                Wait(10)
            end
            if HasAnimDictLoaded(dict) then
                TaskPlayAnim(npc, dict, anim, 8.0, -8.0, -1, 1, 0, 0, 0, 0)
                ESX.ShowNotification(cmd == "blow_me" and "Command: Blow Me" or "Command: Let's Do Babys", "info")
                CreateThread(function()
                    Wait(20000)
                    if DoesEntityExist(npc) then
                        StopAnimTask(npc, dict, anim, 1.0)
                    end
                end)
            else
                ESX.ShowNotification("Animation not available.", "error")
            end
        else
            ESX.ShowNotification("NPC needs to be in a vehicle for this.", "error")
        end
        return
    end
    
    -- Special case: race mode, don't clear tasks if already driving (would eject NPC)
    if cmd == "lets_race" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        local veh = GetVehiclePedIsIn(npc, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == npc then
            EnterRaceMode(npc, veh)
        else
            local pCoords = GetEntityCoords(npc)
            local targetVeh = GetClosestVehicle(pCoords, 15.0, 0, 70)
            if targetVeh ~= 0 and IsVehicleSeatFree(targetVeh, -1) then
                ClearPedTasksImmediately(npc)
                TaskEnterVehicle(npc, targetVeh, 10000, -1, 1.0, 1, 0)
                ESX.ShowNotification("~g~[RACE]~s~ Getting into vehicle...", "info")
                CreateThread(function()
                    local started = GetGameTimer()
                    while GetGameTimer() - started < 15000 do
                        Wait(200)
                        if GetPedInVehicleSeat(targetVeh, -1) == npc then
                            EnterRaceMode(npc, targetVeh)
                            return
                        end
                    end
                    ESX.ShowNotification("~y~[RACE]~s~ Could not get into vehicle.", "info")
                end)
            else
                ESX.ShowNotification("~y~No nearby vehicle with a free driver seat!", "info")
            end
        end
        return
    end
    
    -- Clear tasks for all other commands (this may cause vehicle exit, which is intended for on-foot commands)
    FreezeEntityPosition(npc, false)
    ClearPedTasksImmediately(npc)
    
    if cmd == "hands_up" then
        RequestAnimDict("random@mugging3")
        for _ = 1, 100 do if HasAnimDictLoaded("random@mugging3") then break end Wait(10) end
        TaskPlayAnim(npc, "random@mugging3", "handsup_standing_base", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Hands Up", "info")
        
    elseif cmd == "follow_me" then
        state.isFollowing = true
        TaskGoToEntity(npc, PlayerPedId(), -1, 1.0, 1.0, 1073741824, 0)
        ESX.ShowNotification("Command: Follow Player", "info")
        
    elseif cmd == "lead_the_way" then
        state.isLeading = true
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        local destName = state.lastEngineTarget or state.targetLocation
        local coords = nil
        if destName and destName ~= "none" then
            coords, _ = GetLocationCoords(destName)
        end
        if not coords then
            local pCoords = GetEntityCoords(PlayerPedId())
            local forward = GetEntityForwardVector(npc)
            coords = pCoords + (forward * 30.0)
        end
        state.leadDestination = coords
        ClearPedTasksImmediately(npc)
        FreezeEntityPosition(npc, false)
        ExecuteAITravelWithPlayer(npc, coords)
        ESX.ShowNotification("Command: NPC leads the way", "info")

    elseif cmd == "stop_following" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        state.isLeading = false
        state.leadDestination = nil
        state.helpMeOut = false
        state.companionCombatTarget = nil
        ResetDriverState()
        ClearPedTasksImmediately(npc)
        FreezeEntityPosition(npc, true)
        ESX.ShowNotification("Command: Stop Following", "info")

    elseif cmd == "help_me_out" then
        state.helpMeOut = true
        state.isFollowing = true
        state.companionCombatTarget = nil
        SetPedFleeAttributes(npc, 0, 0)
        SetPedCombatAttributes(npc, 46, true)
        SetPedCombatAttributes(npc, 5, true)
        if not IsPedArmed(npc, 4) then
            GiveWeaponToPed(npc, GetHashKey("WEAPON_COMBATPISTOL"), 300, false, true)
        end
        TaskGoToEntity(npc, PlayerPedId(), -1, 2.0, 1.5, 1073741824, 0)
        ESX.ShowNotification("~g~[Backup]~s~ NPC will fight with you.", "success")
        
    elseif cmd == "get_on_knees" then
        RequestAnimDict("random@arrests")
        for _ = 1, 100 do if HasAnimDictLoaded("random@arrests") then break end Wait(10) end
        TaskPlayAnim(npc, "random@arrests", "kneeling_arrest_idle", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Kneel Down", "info")
        
    elseif cmd == "lay_on_ground" then
        RequestAnimDict("random@arrests@busted")
        for _ = 1, 100 do if HasAnimDictLoaded("random@arrests@busted") then break end Wait(10) end
        TaskPlayAnim(npc, "random@arrests@busted", "idle_a", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Lay on Ground", "info")
        
    elseif cmd == "sit_down" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        local seatCoords, seatH, seatObj = FindClosestSeatCoords(PlayerPedId(), 20.0)
        if seatCoords then
            FreezeEntityPosition(npc, false)
            local seatScenario = "PROP_HUMAN_SEAT_CHAIR"
            if seatObj and DoesEntityExist(seatObj) then
                local sModel = GetEntityModel(seatObj)
                if sModel == GetHashKey("prop_bar_stool_01") or sModel == GetHashKey("v_club_bahbarstool") then
                    seatScenario = "PROP_HUMAN_SEAT_BAR"
                elseif sModel == GetHashKey("v_club_baham_bckt_chr") then
                    seatScenario = "PROP_HUMAN_SEAT_CHAIR"
                elseif sModel == GetHashKey("prop_sofa_01") or sModel == GetHashKey("prop_sofa_02") or sModel == GetHashKey("prop_sofa_03") or sModel == GetHashKey("prop_couch_01") or sModel == GetHashKey("prop_couch_02") or sModel == GetHashKey("prop_couch_03") or sModel == GetHashKey("prop_couch_04") or sModel == GetHashKey("prop_armchair_01") then
                    seatScenario = "PROP_HUMAN_SEAT_BENCH"
                elseif sModel == GetHashKey("prop_bench_01") or sModel == GetHashKey("prop_bench_02") or sModel == GetHashKey("prop_bench_03") or sModel == GetHashKey("prop_bench_04") or sModel == GetHashKey("prop_bench_05") or sModel == GetHashKey("prop_bench_06") or sModel == GetHashKey("prop_bench_07") or sModel == GetHashKey("prop_bench_08") or sModel == GetHashKey("prop_bench_09") or sModel == GetHashKey("prop_bench_10") or sModel == GetHashKey("prop_bench_11") or sModel == GetHashKey("prop_waiting_bench_01") or sModel == GetHashKey("prop_waiting_seat_01") or sModel == GetHashKey("prop_picnictable_01") then
                    seatScenario = "PROP_HUMAN_SEAT_BENCH"
                end
            end
            TaskStartScenarioAtPosition(npc, seatScenario, seatCoords.x, seatCoords.y, seatCoords.z, seatH, -1, true, false)
            ESX.ShowNotification("Command: Take a Seat", "info")
        else
            -- No seat found: sit on ground at current position
            FreezeEntityPosition(npc, false)
            if IsPedMale(npc) then
                RequestAnimDict("amb@world_human_sit_ground@male@base")
                for _ = 1, 100 do if HasAnimDictLoaded("amb@world_human_sit_ground@male@base") then break end Wait(10) end
                TaskPlayAnim(npc, "amb@world_human_sit_ground@male@base", "base", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
            else
                RequestAnimDict("amb@world_human_sit_ground@female@base")
                for _ = 1, 100 do if HasAnimDictLoaded("amb@world_human_sit_ground@female@base") then break end Wait(10) end
                TaskPlayAnim(npc, "amb@world_human_sit_ground@female@base", "base", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
            end
            ESX.ShowNotification("Command: Sit on Floor", "info")
        end
        
    elseif cmd == "get_up" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        ClearPedTasksImmediately(npc)
        FreezeEntityPosition(npc, true)
        ESX.ShowNotification("Command: Stand Up", "info")
        
    elseif cmd == "step_out_vehicle" then
        TaskLeaveAnyVehicle(npc, 0, 0)
        state.isInVehicle = false
        ESX.ShowNotification("Command: Exit Vehicle", "info")
        
    elseif cmd == "get_in_vehicle" then
        -- Clear follow/backup tasks first: the follow thread (TaskGoToEntity every 1s)
        -- and helpMeOut thread (every 0.5s) were cancelling this TaskEnterVehicle.
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        state.helpMeOut = false
        ClearPedTasksImmediately(npc)
        local playerCoords = GetEntityCoords(PlayerPedId())
        local playerVeh = GetVehiclePedIsIn(PlayerPedId(), false)
        
        if playerVeh == 0 then
            playerVeh = GetVehiclePedIsIn(PlayerPedId(), true) -- Try last driven vehicle
        end
        if playerVeh == 0 then
            -- Fallback to ESX game utility to find closest vehicle of any model type
            playerVeh = ESX.Game.GetClosestVehicle(playerCoords)
        end
        
        if playerVeh and playerVeh ~= 0 then
            local seat = -1
            -- Loop through standard seat indices: -1 (driver), 0 (front passenger), 1 (back left), 2 (back right)
            for i = -1, 3 do
                if IsVehicleSeatFree(playerVeh, i) then
                    seat = i
                    break
                end
            end
            
            if seat ~= -1 then
                -- Ensure they are unfrozen so they can physically move and open the doors
                FreezeEntityPosition(npc, false)
                TaskEnterVehicle(npc, playerVeh, 20000, seat, 1.0, 1, 0)
                state.isInVehicle = true
                ESX.ShowNotification("Command: Entering Vehicle...", "info")
            else
                ESX.ShowNotification("No free seats in vehicle!", "error")
            end
        else
            ESX.ShowNotification("No vehicle nearby!", "error")
        end
        
    elseif cmd == "companion" then
        if not IsCompanionExtrasEnabled() then
            ESX.ShowNotification("~y~Companion mode is a subscription extra.", "info")
            return
        end
        state.isCompanion = true
        state.companionVehicle = 0
        state.wasInVehicle = false
        state.companionCombatTarget = nil
        state.isFollowing = true
        TaskGoToEntity(npc, PlayerPedId(), -1, 1.0, 1.0, 1073741824, 0)
        ESX.ShowNotification("~g~[Companion]~s~ NPC is now your companion!", "success")

    elseif cmd == "you_drive" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        state.npcIsDriver = true
        state.driverNpc = npc
        state.isCompanion = true
        state.isFollowing = true
        state.companionVehicle = 0
        state.wasInVehicle = false
        state.companionCombatTarget = nil
        state.drivingMode = "wander"
        state.drivingSpeed = 30.0

        local player = PlayerPedId()
        local playerVeh = GetVehiclePedIsIn(player, false)
        local pCoords = GetEntityCoords(player)

        if playerVeh ~= 0 then
            -- Player is inside: force player to passenger first, then NPC to driver
            local moved, seat = ForcePlayerIntoPassengerSeat(player, playerVeh, state.driverPassengerSeat)
            if not moved then
                ESX.ShowNotification("~y~No free passenger seats!", "info")
                ResetDriverState()
                return
            end
            state.driverPassengerSeat = seat
            Wait(100)
            SetPedIntoVehicle(npc, playerVeh, -1)
            LockNpcAsDriver(npc, playerVeh, player)
            state.companionVehicle = playerVeh
            state.wasInVehicle = true
            ESX.ShowNotification("~g~[Companion]~s~ NPC takes the wheel", "info")
        else
            -- Player is outside: find nearest vehicle and seat both
            local targetVeh = GetClosestVehicle(pCoords, 10.0, 0, 70)
            if targetVeh ~= 0 and IsVehicleSeatFree(targetVeh, -1) then
                local moved, seat = ForcePlayerIntoPassengerSeat(player, targetVeh, state.driverPassengerSeat)
                if moved then
                    state.driverPassengerSeat = seat
                    Wait(100)
                    SetPedIntoVehicle(npc, targetVeh, -1)
                    LockNpcAsDriver(npc, targetVeh, player)
                    state.companionVehicle = targetVeh
                    state.wasInVehicle = true
                    ESX.ShowNotification("~g~[Companion]~s~ NPC takes the wheel", "info")
                else
                    ESX.ShowNotification("~y~No free passenger seats in the nearby vehicle!", "info")
                    ResetDriverState()
                end
            else
                ESX.ShowNotification("~y~No nearby vehicle with a free driver seat!", "info")
                ResetDriverState()
            end
        end

    elseif cmd == "stop_driving" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        ResetDriverState()
        local veh = GetVehiclePedIsIn(npc, false)
        if veh ~= 0 then
            ClearPedTasksImmediately(npc)
            TaskVehicleTempAction(npc, veh, 1, 3000)
        end
        ESX.ShowNotification("Command: NPC stops driving", "info")

    elseif cmd == "drive_go" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        state.drivingMode = "waypoint"
        state.drivingSpeed = 30.0
        ESX.ShowNotification("~g~[Companion]~s~ Driving to waypoint", "info")

    elseif cmd == "drive_stop" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        state.drivingMode = "stopped"
        local veh = GetVehiclePedIsIn(npc, false)
        if veh ~= 0 then
            ClearPedTasksImmediately(npc)
            TaskVehicleTempAction(npc, veh, 1, 5000)
        end
        ESX.ShowNotification("~y~[Companion]~s~ Vehicle stopped", "info")

    elseif cmd == "slow_down" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        state.drivingSpeed = math.max((state.drivingSpeed or 60.0) - 10.0, 5.0)
        ESX.ShowNotification("~y~[Companion]~s~ Speed reduced to " .. math.floor(state.drivingSpeed), "info")

    elseif cmd == "land_here" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        local veh = GetVehiclePedIsIn(npc, false)
        if veh == 0 then
            ESX.ShowNotification("~y~NPC is not in a vehicle.", "info")
            return
        end
        local vClass = GetVehicleClass(veh)
        if vClass ~= 15 and vClass ~= 16 then
            ESX.ShowNotification("~y~This command only works with helicopters or planes.", "info")
            return
        end
        local playerPos = GetEntityCoords(PlayerPedId())
        ClearPedTasksImmediately(npc)
        if vClass == 15 then
            TaskHeliMission(npc, veh, 0, 0, playerPos.x, playerPos.y, playerPos.z, 4, 20.0, 10.0, -1.0, 0, 0, 0)
            ESX.ShowNotification("~g~Helicopter landing at your position.", "info")
        else
            TaskPlaneMission(npc, veh, 0, 0, playerPos.x, playerPos.y, playerPos.z, 3, 30.0, 100.0, 0.0, 0, 0, 0)
            ESX.ShowNotification("~g~Plane approaching your position.", "info")
        end

    elseif cmd == "escape_cops" then
        if not IsDrivingExtrasEnabled() then
            ESX.ShowNotification("~y~NPC driving is a subscription extra.", "info")
            return
        end
        local veh = GetVehiclePedIsIn(npc, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == npc then
            TaskVehicleDriveWander(npc, veh, 50.0, 786468)
            ModifyVehicleTopSpeed(veh, 20.0)
            state.drivingMode = "escape"
            ESX.ShowNotification("~r~EVASIVE! Going dark!", "info")
        else
            ESX.ShowNotification("~y~NPC is not driving.", "info")
        end

    elseif cmd == "leave_companion" then
        if not IsCompanionExtrasEnabled() and not state.isCompanion then
            ESX.ShowNotification("~y~Companion mode is a subscription extra.", "info")
            return
        end
        state.isCompanion = false
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        state.helpMeOut = false
        ResetDriverState()
        state.companionVehicle = 0
        state.companionCombatTarget = nil
        ClearPedTasksImmediately(npc)
        FreezeEntityPosition(npc, true)
        ESX.ShowNotification("~r~[Companion]~s~ Companion dismissed.", "info")

    elseif cmd == "run_away" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        state.isCompanion = false
        state.helpMeOut = false
        state.companionCombatTarget = nil
        SetPedFleeAttributes(npc, 1, 0)
        TaskSmartFleePed(npc, PlayerPedId(), 100.0, -1, true, true)
        ESX.ShowNotification("Command: Run Away Scared", "info")
        SetTimeout(2000, function() StopInteraction() end)
        
    elseif cmd == "pushups" then
        RequestAnimDict("amb@world_human_push_ups@male@base")
        for _ = 1, 100 do if HasAnimDictLoaded("amb@world_human_push_ups@male@base") then break end Wait(10) end
        TaskPlayAnim(npc, "amb@world_human_push_ups@male@base", "base", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Push-ups", "info")
        
    elseif cmd == "situps" then
        RequestAnimDict("amb@world_human_sit_ups@male@base")
        for _ = 1, 100 do if HasAnimDictLoaded("amb@world_human_sit_ups@male@base") then break end Wait(10) end
        TaskPlayAnim(npc, "amb@world_human_sit_ups@male@base", "base", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Sit-ups", "info")
        
    elseif cmd == "dance" then
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_PARTYING", 0, true)
        ESX.ShowNotification("Command: Dance", "info")
        
    elseif cmd == "jog" then
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_JOG", 0, true)
        ESX.ShowNotification("Command: Jog in Place", "info")
        
    elseif cmd == "go_to_point" then
        local coords = GetCrosshairCoords()
        if coords then
            FreezeEntityPosition(npc, false)
            ClearPedTasksImmediately(npc)
            TaskGoToCoordAnyMeans(npc, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
            ESX.ShowNotification("Command: Move to Pointed Location", "info")
        else
            ESX.ShowNotification("Could not find point target!", "error")
        end
        
    elseif cmd == "taser" then
        GiveWeaponToPed(PlayerPedId(), GetHashKey("WEAPON_STUNGUN"), 100, false, true)
        SetCurrentPedWeapon(PlayerPedId(), GetHashKey("WEAPON_STUNGUN"), true)
        ESX.ShowNotification("Taser Armed!", "info")
        
    elseif cmd == "delete" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        DeleteEntity(npc)
        ESX.ShowNotification("Command: Remove Ped", "info")
        StopInteraction()
        
    elseif cmd == "dismiss" then
        -- Set proper engine action based on common dismissal phrases
        -- If player said "go home", set GO_HOME; otherwise default to WANDER
        if not state.lastEngineAction or state.lastEngineAction == "WANDER" then
            state.lastEngineAction = "WANDER"
            state.lastEngineTarget = "none"
        end
        StopInteraction()

    elseif cmd == "wait_here" then
        DismissCompanionPed(npc)
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        ClearPedTasksImmediately(npc)
        SetEntityVelocity(npc, 0.0, 0.0, 0.0)
        FreezeEntityPosition(npc, true)
        local pCoords3 = GetEntityCoords(PlayerPedId())
        local nCoords3 = GetEntityCoords(npc)
        SetEntityHeading(npc, HeadingFromVector(pCoords3.x - nCoords3.x, pCoords3.y - nCoords3.y))
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
        ESX.ShowNotification("Command: Wait Here", "info")

    elseif cmd == "crouch" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_CROUCH_INSPECT", 0, true)
        ESX.ShowNotification("Command: Crouch", "info")

    elseif cmd == "lean" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_LEANING", 0, true)
        ESX.ShowNotification("Command: Lean", "info")

    elseif cmd == "smoke" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        if IsPedMale(npc) then
            TaskStartScenarioInPlace(npc, "WORLD_HUMAN_SMOKING", 0, true)
        else
            TaskStartScenarioInPlace(npc, "WORLD_HUMAN_SMOKING_FEMALE", 0, true)
        end
        ESX.ShowNotification("Command: Smoke", "info")

    elseif cmd == "face_me" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        ClearPedTasksImmediately(npc)
        TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
        ESX.ShowNotification("Command: Face Me", "info")

    elseif cmd == "turn_around" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        ClearPedTasksImmediately(npc)
        local nCoords = GetEntityCoords(npc)
        local pCoords = GetEntityCoords(PlayerPedId())
        local dir = vector3(nCoords.x - pCoords.x, nCoords.y - pCoords.y, 0)
        local facing = nCoords + (dir * 5.0)
        TaskTurnPedToFaceCoord(npc, facing.x, facing.y, facing.z, -1)
        ESX.ShowNotification("Command: Turn Around", "info")

    elseif cmd == "hands_behind_back" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("mp_arresting")
        for _ = 1, 100 do if HasAnimDictLoaded("mp_arresting") then break end Wait(10) end
        TaskPlayAnim(npc, "mp_arresting", "idle", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Hands Behind Back", "info")

    elseif cmd == "use_phone" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_STAND_MOBILE", 0, true)
        ESX.ShowNotification("Command: Use Phone", "info")

    elseif cmd == "wave" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("gestures@m@standing@casual")
        for _ = 1, 100 do if HasAnimDictLoaded("gestures@m@standing@casual") then break end Wait(10) end
        TaskPlayAnim(npc, "gestures@m@standing@casual", "gesture_hello", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Wave", "info")

    elseif cmd == "guard_area" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_GUARD_STAND", 0, true)
        ESX.ShowNotification("Command: Guard Area", "info")

    elseif cmd == "drink" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_DRINKING", 0, true)
        ESX.ShowNotification("Command: Drink", "info")

    elseif cmd == "salute" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("anim@mp_player_intcelebrationmale@salute")
        for _ = 1, 100 do if HasAnimDictLoaded("anim@mp_player_intcelebrationmale@salute") then break end Wait(10) end
        TaskPlayAnim(npc, "anim@mp_player_intcelebrationmale@salute", "salute", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Salute", "info")

    elseif cmd == "stop" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        ClearPedTasksImmediately(npc)
        FreezeEntityPosition(npc, true)
        ESX.ShowNotification("Command: Stop", "info")

    elseif cmd == "lap_dance" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("mini@strip_club@private_dance@part1")
        for _ = 1, 100 do if HasAnimDictLoaded("mini@strip_club@private_dance@part1") then break end Wait(10) end
        TaskPlayAnim(npc, "mini@strip_club@private_dance@part1", "priv_dance_p1", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Lap Dance", "info")

    elseif cmd == "beg" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_BUM_FREEWAY", 0, true)
        ESX.ShowNotification("Command: Beg", "info")

    elseif cmd == "listen_at_door" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("mini@safe_cracking")
        for _ = 1, 100 do if HasAnimDictLoaded("mini@safe_cracking") then break end Wait(10) end
        TaskPlayAnim(npc, "mini@safe_cracking", "idle_base", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Listen at Door", "info")

    elseif cmd == "take_photo" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_SELFIE", 0, true)
        ESX.ShowNotification("Command: Take Photo", "info")

    elseif cmd == "stretch" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_STRETCH", 0, true)
        ESX.ShowNotification("Command: Stretch", "info")

    elseif cmd == "meditate" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_MEDITATE", 0, true)
        ESX.ShowNotification("Command: Meditate", "info")

    elseif cmd == "flex" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        TaskStartScenarioInPlace(npc, "WORLD_HUMAN_MUSCLE_FLEX", 0, true)
        ESX.ShowNotification("Command: Flex", "info")

    elseif cmd == "point" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("gestures@m@standing@casual")
        for _ = 1, 100 do if HasAnimDictLoaded("gestures@m@standing@casual") then break end Wait(10) end
        TaskPlayAnim(npc, "gestures@m@standing@casual", "gesture_point", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Point", "info")

    elseif cmd == "lay_on_bed" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        local bedCoords, bedH = FindClosestBedCoords(npc, 8.0)
        if bedCoords then
            ClearPedTasksImmediately(npc)
            FreezeEntityPosition(npc, false)
            TaskStartScenarioAtPosition(npc, "PROP_HUMAN_SLEEP_BED", bedCoords.x, bedCoords.y, bedCoords.z, bedH, -1, true, false)
            ESX.ShowNotification("Command: Lay on Bed", "info")
        else
            TaskStartScenarioInPlace(npc, "WORLD_HUMAN_SLEEP_GROUND", 0, true)
            ESX.ShowNotification("Command: Sleep Ground", "info")
        end

    elseif cmd == "sexy" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        RequestAnimDict("mini@strip_club@idles@bob")
        for _ = 1, 100 do if HasAnimDictLoaded("mini@strip_club@idles@bob") then break end Wait(10) end
        TaskPlayAnim(npc, "mini@strip_club@idles@bob", "idle_a", 8.0, -8.0, -1, 9, 0, 0, 0, 0)
        ESX.ShowNotification("Command: Sexy Moves", "info")

    elseif cmd == "blow_me" or cmd == "make_babies" then
        state.isFollowing = false; state.explicitFollow = false; state.followNpc = nil
        if npcVehicle ~= 0 then
            local dict, anim, label
            if cmd == "blow_me" then
                dict = "oddjobs@towing"
                anim = "f_blow_job_loop"
                label = "Blow Me"
            else
                dict = "mini@prostitutes@sexlow_veh"
                anim = "low_car_sex_loop_female"
                label = "Let's Do Babys"
            end
            RequestAnimDict(dict)
            for _ = 1, 100 do if HasAnimDictLoaded(dict) then break end Wait(10) end
            TaskPlayAnim(npc, dict, anim, 8.0, -8.0, -1, 1, 0, 0, 0, 0)
            ESX.ShowNotification("Command: " .. label, "info")
            CreateThread(function()
                Wait(20000)
                if DoesEntityExist(npc) then
                    StopAnimTask(npc, dict, anim, 1.0)
                end
            end)
        else
            ESX.ShowNotification("NPC needs to be in a vehicle for this.", "error")
        end
    end
end

-- Thread to handle active follow behavior. An explicit "follow me" persists after
-- the conversation ends (state.explicitFollow + state.followNpc); without it the
-- follow only lives while the interaction is open.
CreateThread(function()
    while true do
        Wait(1000)
        local followPed = state.followNpc or state.currentNpc
        if state.isFollowing and followPed and (state.isInteracting or state.explicitFollow)
            and not state.isCompanion and DoesEntityExist(followPed)
            and not IsPedDeadOrDying(followPed, true) then
            local player = PlayerPedId()
            local pCoords = GetEntityCoords(player)
            local nCoords = GetEntityCoords(followPed)
            local dist = #(pCoords - nCoords)

            if state.explicitFollow and dist > 40.0 then
                -- Player is hopelessly far ahead: give up and release the ped
                state.isFollowing, state.explicitFollow, state.followNpc = false, false, nil
            else
                -- Teleport NPC if player changed interior (property door)
                local playerInterior = GetInteriorFromEntity(player)
                if playerInterior ~= state.lastInterior then
                    state.lastInterior = playerInterior
                    local npcVeh = GetVehiclePedIsIn(followPed, false)
                    if npcVeh == 0 then
                        SetEntityCoords(followPed, pCoords.x, pCoords.y, pCoords.z, false, false, false, false)
                        ESX.ShowNotification("NPC followed you inside.", "info")
                    end
                end

                if dist > 2.5 and dist <= 40.0 then
                    local npcVeh = GetVehiclePedIsIn(followPed, false)
                    if npcVeh == 0 then
                        TaskGoToEntity(followPed, player, -1, 1.0, 1.5, 1073741824, 0)
                    end
                end
            end
        end
    end
end)

-- Wrapper for NPC leading the way with vehicle warp + arrival freeze
function ExecuteAITravelWithPlayer(npc, targetCoords)
    TaskGoToCoordAnyMeans(npc, targetCoords.x, targetCoords.y, targetCoords.z, 1.0, 0, 0, 786603, 0xbf800000)

    CreateThread(function()
        local hasArrived = false

        while not hasArrived do
            Wait(500)

            if not DoesEntityExist(npc) or not state.isLeading then
                state.isLeading = false
                state.leadDestination = nil
                -- Do NOT ClearPedTasks here: StopInteraction already released the NPC
                -- (seat restore / engine action) and this exit path fires up to 500ms
                -- later, wiping that release.
                return
            end

            local playerPed = PlayerPedId()
            local npcCoords = GetEntityCoords(npc)
            local distToTarget = #(npcCoords - targetCoords)

            -- Vehicle check: NPC grabbed a car, warp player into passenger seat
            if IsPedInAnyVehicle(npc, false) then
                local veh = GetVehiclePedIsIn(npc, false)
                if not IsPedInVehicle(playerPed, veh, false) then
                    if IsVehicleSeatFree(veh, 0) then
                        SetPedIntoVehicle(playerPed, veh, 0)
                    elseif IsVehicleSeatFree(veh, 1) then
                        SetPedIntoVehicle(playerPed, veh, 1)
                    end
                end
            else
                -- On-foot follow: player walks behind NPC
                local pCoords = GetEntityCoords(playerPed)
                local dist = #(pCoords - npcCoords)
                if dist > 3.0 and dist <= 40.0 then
                    TaskGoToEntity(playerPed, npc, -1, 1.0, 1.5, 1073741824, 0)
                elseif dist > 40.0 then
                    SetEntityCoords(playerPed, npcCoords.x + 2.0, npcCoords.y + 2.0, npcCoords.z, false, false, false, false)
                end
            end

            -- Arrival check: clear tasks so NPC idles in place
            if distToTarget < 5.0 then
                hasArrived = true
                state.isLeading = false
                state.leadDestination = nil
                DismissCompanionPed(npc)
                ClearPedTasks(npc)
                ESX.ShowNotification("~g~Arrived at destination. Conversation continues.", "info")
                local pCoords = GetEntityCoords(playerPed)
                SetEntityHeading(npc, HeadingFromVector(pCoords.x - npcCoords.x, pCoords.y - npcCoords.y))
                TaskLookAtEntity(npc, PlayerPedId(), -1, 2048, 3)
            end
        end
    end)
end

-- Simplified lead thread: only handles interior teleport edge cases
CreateThread(function()
    while true do
        Wait(1000)
        if state.isInteracting and state.isLeading and state.currentNpc and DoesEntityExist(state.currentNpc) then
            local player = PlayerPedId()
            local npc = state.currentNpc
            local playerInterior = GetInteriorFromEntity(player)
            if playerInterior ~= state.lastInterior then
                state.lastInterior = playerInterior
                local pCoords = GetEntityCoords(player)
                SetEntityCoords(npc, pCoords.x + 2.0, pCoords.y + 2.0, pCoords.z, false, false, false, false)
            end
        end
    end
end)

-- Help-me-out mode thread: follow player and assist in combat on foot
local lastPoolScanHelp = 0
CreateThread(function()
    while true do
        Wait(500)
        if state.isInteracting and state.helpMeOut and state.currentNpc and DoesEntityExist(state.currentNpc) then
            local player = PlayerPedId()
            local npc = state.currentNpc
            local pCoords = GetEntityCoords(player)
            local nCoords = GetEntityCoords(npc)
            local dist = #(pCoords - nCoords)

            if IsEntityDead(npc) then
                state.helpMeOut = false
                state.companionCombatTarget = nil
                ESX.ShowNotification("~r~[Backup]~s~ Your backup has been killed!", "error")
            else
                local npcVeh = GetVehiclePedIsIn(npc, false)
                if npcVeh == 0 and not IsPedInCombat(npc, 0) then
                    if dist > 3.0 and dist <= 45.0 then
                        TaskGoToEntity(npc, player, -1, 2.0, 1.8, 1073741824, 0)
                    elseif dist > 45.0 then
                        SetEntityCoords(npc, pCoords.x + 1.0, pCoords.y + 1.0, pCoords.z, false, false, false, false)
                    end
                end

                local tgtFound, tgtEnt = GetPlayerTargetEntity(PlayerId())
                local target = (type(tgtFound) == "boolean") and tgtEnt or tgtFound
                if type(target) ~= "number" then target = nil end
                local currentHealth = GetEntityHealth(player)
                local tookDamage = currentHealth < state.lastHealth
                state.lastHealth = currentHealth

                SetPedFleeAttributes(npc, 0, 0)
                SetPedCombatAttributes(npc, 46, true)
                SetPedCombatAttributes(npc, 5, true)
                SetPedCombatMovement(npc, 2)
                SetPedCombatRange(npc, 2)

                if tookDamage and not state.companionCombatTarget then
                    local now = GetGameTimer()
                    if now - lastPoolScanHelp > 1000 then
                        lastPoolScanHelp = now
                        local closestAttacker = nil
                        local closestDist = 50.0
                        local nearby = GetGamePool('CPed')
                        for _, ped in ipairs(nearby) do
                            if DoesEntityExist(ped) and not IsEntityDead(ped) and not IsPedAPlayer(ped) then
                                local d = #(GetEntityCoords(ped) - pCoords)
                                if d < closestDist and (IsPedInCombat(ped, player) or IsPedShooting(ped)) then
                                    closestDist = d
                                    closestAttacker = ped
                                end
                            end
                        end
                        if closestAttacker then
                            state.companionCombatTarget = closestAttacker
                        end
                    end
                end

                if target and target ~= 0 and IsEntityAPed(target) and not IsPedAPlayer(target) and not IsEntityDead(target) then
                    state.companionCombatTarget = target
                    if not IsPedInCombat(npc, target) then
                        if not IsPedArmed(npc, 4) then
                            local weapons = { "WEAPON_PISTOL", "WEAPON_ASSAULTRIFLE", "WEAPON_MICROSMG", "WEAPON_COMBATPISTOL" }
                            GiveWeaponToPed(npc, GetHashKey(weapons[math.random(#weapons)]), 250, false, true)
                        end
                        TaskCombatPed(npc, target, 0, 3)
                    end
                elseif state.companionCombatTarget then
                    local combatTarget = state.companionCombatTarget
                    if DoesEntityExist(combatTarget) and not IsEntityDead(combatTarget) then
                        if not IsPedInCombat(npc, combatTarget) then
                            TaskCombatPed(npc, combatTarget, 0, 3)
                        end
                    else
                        state.companionCombatTarget = nil
                    end
                end
            end
        end
    end
end)

-- Companion mode thread: follow, vehicle, combat, guard
local lastPoolScan = 0
CreateThread(function()
    while true do
        Wait(500)
        if IsCompanionExtrasEnabled() and state.isCompanion and state.currentNpc and DoesEntityExist(state.currentNpc) then
            local player = PlayerPedId()
            local npc = state.currentNpc
            local pCoords = GetEntityCoords(player)
            local nCoords = GetEntityCoords(npc)
            local dist = #(pCoords - nCoords)
            local playerVeh = GetVehiclePedIsIn(player, false)
            local npcVeh = GetVehiclePedIsIn(npc, false)
            local playerInAnyVeh = playerVeh ~= 0

            -- NPC dies -> end companion
            if IsEntityDead(npc) then
                state.isCompanion = false
                state.companionVehicle = 0
                state.companionCombatTarget = nil
                if state.isInteracting then
                    StopInteraction()
                end
                ESX.ShowNotification("~r~[Companion]~s~ Your companion has been killed!", "error")
            end

            -- Follow/vehicle behavior (still active when NPC is designated driver)
            if not state.isInteracting or state.npcIsDriver then

            -- Teleport companion if player changed interior (property door)
            local playerInterior = GetInteriorFromEntity(player)
            if playerInterior ~= state.lastInterior then
                state.lastInterior = playerInterior
                local npcInVeh = GetVehiclePedIsIn(npc, false)
                if npcInVeh == 0 then
                    SetEntityCoords(npc, pCoords.x, pCoords.y, pCoords.z, false, false, false, false)
                    ESX.ShowNotification("~y~[Companion]~s~ Companion followed you inside.", "info")
                end
            end

            -- Player entered a vehicle -> NPC gets in too
            if playerInAnyVeh and npcVeh == 0 then
                if not state.npcIsDriver then
                    local freeSeat
                    for i = -2, 3 do
                        if IsVehicleSeatFree(playerVeh, i) then
                            freeSeat = i
                            break
                        end
                    end
                    if freeSeat then
                        ClearPedTasksImmediately(npc)
                        TaskEnterVehicle(npc, playerVeh, 20000, freeSeat, 1.0, 1, 0)
                        state.companionVehicle = playerVeh
                    end
                end
                state.wasInVehicle = true

            -- Player exited vehicle -> NPC stays in driver seat if designated driver
            elseif not playerInAnyVeh and state.wasInVehicle then
                if not state.npcIsDriver then
                    if npcVeh ~= 0 then
                        TaskLeaveAnyVehicle(npc, 0, 16)
                    end
                    state.companionVehicle = 0
                    state.wasInVehicle = false
                else
                    -- Re-seat NPC if game engine ejected them when player exited
                    if npcVeh == 0 then
                        local playerVeh = GetVehiclePedIsIn(PlayerPedId(), false)
                        if playerVeh == 0 then playerVeh = state.companionVehicle end
                        if playerVeh ~= 0 then
                            SetPedIntoVehicle(npc, playerVeh, -1)
                            SetPedStayInVehicleWhenJacked(npc, true)
                            npcVeh = playerVeh
                        end
                    end
                    state.companionVehicle = npcVeh
                    state.wasInVehicle = npcVeh ~= 0
                end

            -- Player was never in vehicle, just follow on foot
            elseif not playerInAnyVeh and not state.wasInVehicle then
                local npcInVeh = GetVehiclePedIsIn(npc, false)
                if dist > 3.0 and dist <= 60.0 and npcInVeh == 0 then
                    TaskGoToEntity(npc, player, -1, 1.0, 1.5, 1073741824, 0)
                elseif dist > 60.0 then
                    SetEntityCoords(npc, pCoords.x + 2.0, pCoords.y + 2.0, pCoords.z, false, false, false, false)
                    ESX.ShowNotification("~y~[Companion]~s~ Companion teleported to you.", "info")
                end
            end

            -- Keep state synced in dedicated driver mode without force-teleporting either ped.
            if state.npcIsDriver then
                state.companionVehicle = npcVeh ~= 0 and npcVeh or 0
                state.wasInVehicle = npcVeh ~= 0
            end

            end -- follow/vehicle behavior gate

            -- Combat detection & guard behavior
            local tgtFound, tgtEnt = GetPlayerTargetEntity(PlayerId())
            local target = (type(tgtFound) == "boolean") and tgtEnt or tgtFound
            if type(target) ~= "number" then target = nil end
            local currentHealth = GetEntityHealth(player)
            local tookDamage = currentHealth < state.lastHealth
            state.lastHealth = currentHealth
            local isInCombat = state.companionCombatTarget ~= nil

            -- Suppress NPC fear/flee so it fights to the death
            SetPedFleeAttributes(npc, 0, 0)
            SetPedCombatAttributes(npc, 46, true)
            SetPedCombatAttributes(npc, 5, true)
            SetPedCombatMovement(npc, 2)
            SetPedCombatRange(npc, 2)

            -- When entering combat during interaction: unfreeze so they can move
            if isInCombat and state.isInteracting then
                FreezeEntityPosition(npc, false)
            end

            -- Detect attack: player lost health (throttled to 1s)
            if tookDamage and not state.companionCombatTarget then
                local now = GetGameTimer()
                if now - lastPoolScan > 1000 then
                    lastPoolScan = now
                    local closestAttacker = nil
                    local closestDist = 50.0
                    local nearby = GetGamePool('CPed')
                    for _, ped in ipairs(nearby) do
                        if DoesEntityExist(ped) and not IsEntityDead(ped) and not IsPedAPlayer(ped) then
                            local d = #(GetEntityCoords(ped) - pCoords)
                            if d < closestDist then
                                local isAttacking = IsPedInCombat(ped, player) or IsPedShooting(ped)
                                if isAttacking then
                                    closestDist = d
                                    closestAttacker = ped
                                end
                            end
                        end
                    end
                    if closestAttacker then
                        state.companionCombatTarget = closestAttacker
                    end
                end
            end

            -- Player is aiming at or attacking someone -> NPC assists
            if target and target ~= 0 and IsEntityAPed(target) and not IsPedAPlayer(target) and not IsEntityDead(target) then
                state.companionCombatTarget = target
                if not IsPedInCombat(npc, target) then
                    if not IsPedArmed(npc, 4) then
                        local weapons = { "WEAPON_PISTOL", "WEAPON_ASSAULTRIFLE", "WEAPON_MICROSMG", "WEAPON_COMBATPISTOL" }
                        GiveWeaponToPed(npc, GetHashKey(weapons[math.random(#weapons)]), 250, false, true)
                    end
                    TaskCombatPed(npc, target, 0, 3)
                end

            elseif state.companionCombatTarget then
                local combatTarget = state.companionCombatTarget
                if DoesEntityExist(combatTarget) and not IsEntityDead(combatTarget) then
                    if not IsPedInCombat(npc, combatTarget) then
                        TaskCombatPed(npc, combatTarget, 0, 3)
                    end
                else
                    state.companionCombatTarget = nil
                    ClearPedTasksImmediately(npc)
                end
            end

            -- When combat ends: NPC stops fighting naturally, BlockingOfNonTemporaryEvents
            -- prevents AI from assigning wander tasks
        end
    end
end)

-- Track which seat player is entering (used to distinguish driver-door vs passenger-door entry)
local playerIntendedSeat = nil
local playerIntendedSeatExpiry = 0

AddEventHandler("VehicleStartEntering", function(vehicle, seat, door, currentSeat)
    if IsDrivingExtrasEnabled() and state.currentNpc and state.npcIsDriver then
        playerIntendedSeat = seat
        playerIntendedSeatExpiry = GetGameTimer() + 3000
    end
end)

-- Context change detection thread: monitors world and queues observations
CreateThread(function()
    while true do
        Wait(2000)
        if state.isInteracting and state.currentNpc then
            local newCtx = GetPlayerContext()
            local changes = DetectContextChanges(state.lastContext, newCtx)
            if #changes > 0 then
                state.pendingContextChange = "Context Update: " .. table.concat(changes, ". ") .. "."
            end
            state.lastContext = newCtx
        end
    end
end)

-- NPC driving thread: responds to state.drivingMode, state.drivingSpeed, and waypoints
-- Drive tasks are only issued when mode/target/speed changes or on a periodic refresh.
-- The old code re-issued the task every second (restarting pathfinding) and used a
-- blocking reverse hack, which made the NPC stutter and drive forward/backwards in place.
local DRIVE_REFRESH_MS = 8000
local STUCK_STILL_MS = 7000
local STUCK_TICKS = 3
local MAX_STUCK_ATTEMPTS = 5

local function IssueDriveTask(npc, veh, mode, speed)
    if mode == "escape" then
        ModifyVehicleTopSpeed(veh, 20.0)
        TaskVehicleDriveWander(npc, veh, 50.0, 786468)
    elseif mode == "race" then
        local wp = GetFirstBlipInfoId(8)
        if DoesBlipExist(wp) then
            local coord = GetBlipInfoIdCoord(wp)
            SetDriveTaskDrivingStyle(npc, 786468)
            TaskVehicleDriveToCoordLongrange(npc, veh, coord.x, coord.y, coord.z, speed, 786468, 20.0)
        else
            TaskVehicleDriveWander(npc, veh, speed, 786468)
        end
    elseif mode == "waypoint" then
        local wp = GetFirstBlipInfoId(8)
        if DoesBlipExist(wp) then
            local coord = GetBlipInfoIdCoord(wp)
            SetDriveTaskDrivingStyle(npc, 786468)
            TaskVehicleDriveToCoordLongrange(npc, veh, coord.x, coord.y, coord.z, speed, 1, 25.0)
        end
    elseif mode == "navigate" and state.drivingTarget then
        local t = state.drivingTarget
        SetDriverAbility(npc, 1.0)
        TaskVehicleDriveToCoordLongrange(npc, veh, t.x, t.y, t.z, speed, 786468, 25.0)
    else
        TaskVehicleDriveWander(npc, veh, speed, 1)
    end
end

CreateThread(function()
    local lastSessionNpc = nil
    local lastTaskKey = nil
    local lastIssueAt = 0
    local lastMovingAt = 0
    local stuckTicks = 0
    local stuckAttempts = 0
    local reversingUntil = 0
    local wasReversing = false

    while true do
        Wait(1000)
        if IsDrivingExtrasEnabled() and state.isCompanion and state.driverNpc and DoesEntityExist(state.driverNpc) and state.npcIsDriver then
            local npc = state.driverNpc
            if lastSessionNpc ~= npc then
                -- New driving session (or after ResetDriverState): start clean
                lastSessionNpc = npc
                lastTaskKey = nil
                lastIssueAt = 0
                lastMovingAt = GetGameTimer()
                stuckTicks = 0
                stuckAttempts = 0
                reversingUntil = 0
                wasReversing = false
            end

            local veh = GetVehiclePedIsIn(npc, false)
            if veh == 0 then
                -- NPC left vehicle involuntarily (engine ejects when player exits). Re-seat.
                local playerVeh = GetVehiclePedIsIn(PlayerPedId(), false)
                if playerVeh == 0 then playerVeh = state.companionVehicle end
                if playerVeh ~= 0 and IsVehicleSeatFree(playerVeh, -1) and not IsEntityDead(playerVeh) then
                    SetPedIntoVehicle(npc, playerVeh, -1)
                    SetPedStayInVehicleWhenJacked(npc, true)
                    SetDriverAbility(npc, 1.0)
                    veh = playerVeh
                    lastTaskKey = nil -- force a fresh drive task after re-seating
                else
                    ResetDriverState()
                    state.companionVehicle = 0
                    state.wasInVehicle = false
                end
            end

            if veh ~= 0 then
                local now = GetGameTimer()
                local speed = state.drivingSpeed or 30.0
                local mode = state.drivingMode or "wander"

                -- Arrival bookkeeping (runs before tasks are issued)
                if mode == "waypoint" then
                    local wp = GetFirstBlipInfoId(8)
                    if not DoesBlipExist(wp) then
                        ESX.ShowNotification("~y~[Companion]~s~ No waypoint set. Wandering instead.", "info")
                        mode = "wander"
                        state.drivingMode = mode
                        lastTaskKey = nil
                    elseif #(GetEntityCoords(veh) - GetBlipInfoIdCoord(wp)) <= 25.0 then
                        ClearPedTasksImmediately(npc)
                        TaskVehicleTempAction(npc, veh, 1, 3000)
                        ESX.ShowNotification("~g~[Companion]~s~ Arrived at destination.", "info")
                        mode = "wander"
                        state.drivingMode = mode
                        lastTaskKey = nil
                    end
                elseif mode == "navigate" then
                    if state.drivingTarget then
                        if #(GetEntityCoords(veh) - state.drivingTarget) <= 25.0 then
                            ClearPedTasksImmediately(npc)
                            TaskVehicleTempAction(npc, veh, 1, 3000)
                            ESX.ShowNotification("~g~Arrived at ~y~" .. (state.drivingTargetName or "destination"), "info")
                            state.drivingMode = "stopped"
                            state.drivingTarget = nil
                            state.drivingTargetName = nil
                            mode = "stopped"
                            lastTaskKey = nil
                        end
                    else
                        state.drivingMode = "wander"
                        mode = "wander"
                        lastTaskKey = nil
                    end
                end

                -- Anti-stuck monitor: non-blocking, escalates each attempt, gives up after 5.
                -- Only for modes where the NPC is supposed to be moving - a wandering NPC
                -- waiting at a light or behind traffic must not be told to reverse.
                local recoveryMode = mode == "navigate" or mode == "waypoint" or mode == "race" or mode == "escape"
                if not recoveryMode then
                    stuckTicks = 0
                    stuckAttempts = 0
                    reversingUntil = 0
                    wasReversing = false
                elseif now < reversingUntil then
                    -- Reversal in progress, leave the ped alone
                elseif wasReversing then
                    -- Reversal finished: drop the task key so the forward task is re-issued below
                    wasReversing = false
                    stuckTicks = 0
                    lastTaskKey = nil
                else
                    local spd = GetEntitySpeed(veh)
                    local upsideDown = IsVehicleStuckOnRoof(veh) or IsEntityUpsideDown(veh)
                    if spd > 3.0 then
                        lastMovingAt = now
                        stuckTicks = 0
                        stuckAttempts = 0
                    elseif upsideDown or (now - lastMovingAt) >= STUCK_STILL_MS then
                        stuckTicks = stuckTicks + 1
                    else
                        stuckTicks = 0
                    end

                    if stuckTicks >= (upsideDown and 1 or STUCK_TICKS) then
                        stuckTicks = 0
                        stuckAttempts = stuckAttempts + 1

                        if stuckAttempts > MAX_STUCK_ATTEMPTS then
                            ClearPedTasksImmediately(npc)
                            TaskVehicleTempAction(npc, veh, 1, 5000)
                            ESX.ShowNotification("~r~[Companion]~s~ Vehicle is stuck. Driving stopped.", "error")
                            state.drivingMode = "stopped"
                            mode = "stopped"
                            stuckAttempts = 0
                            lastTaskKey = nil
                        else
                            local reverseMs = 2000 + math.min(stuckAttempts, 3) * 500
                            ClearPedTasks(npc)
                            if upsideDown then
                                SetVehicleOnGroundProperly(veh)
                            end
                            TaskVehicleTempAction(npc, veh, 3, reverseMs)
                            reversingUntil = now + reverseMs
                            wasReversing = true
                            lastTaskKey = nil
                            lastMovingAt = now -- grace: don't re-trigger before the reverse finishes
                        end
                    end
                end

                -- Issue a drive task only when the situation changed or a refresh is due
                if mode ~= "stopped" and now >= reversingUntil then
                    local target = nil
                    if mode == "navigate" and state.drivingTarget then
                        target = state.drivingTarget
                    elseif mode == "waypoint" or mode == "race" then
                        local wp = GetFirstBlipInfoId(8)
                        if DoesBlipExist(wp) then
                            target = GetBlipInfoIdCoord(wp)
                        end
                    end

                    local key = mode .. ":" .. math.floor(speed)
                    if target then
                        key = string.format("%s:%d,%d,%d:%d", mode, math.floor(target.x), math.floor(target.y), math.floor(target.z), math.floor(speed))
                    end

                    if key ~= lastTaskKey or (now - lastIssueAt) >= DRIVE_REFRESH_MS then
                        IssueDriveTask(npc, veh, mode, speed)
                        lastTaskKey = key
                        lastIssueAt = now
                    end
                end
            end
        else
            Wait(5000)
        end
    end
end)

-- /spawnnpc command: spawn a stationary AI NPC with a model picker and character description
RegisterCommand('spawnnpc', function()
    local player = PlayerPedId()
    local coords = GetOffsetFromEntityInWorldCoords(player, 0.0, 3.0, 0.0)
    local heading = GetEntityHeading(player)

    AddTextEntry('SPAWN_MODEL', 'Enter ped model name (e.g. a_m_m_skater_01):')
    DisplayOnscreenKeyboard(1, 'SPAWN_MODEL', '', '', '', '', '', 64)
    while UpdateOnscreenKeyboard() == 0 do Wait(0) end
    if UpdateOnscreenKeyboard() ~= 1 then
        ESX.ShowNotification("~y~Spawn cancelled.", "info")
        return
    end
    local modelName = GetOnscreenKeyboardResult()
    local modelHash = GetHashKey(modelName)
    if not IsModelInCdimage(modelHash) or not IsModelAPed(modelHash) then
        ESX.ShowNotification("~r~Invalid ped model: " .. modelName, "error")
        return
    end

    AddTextEntry('SPAWN_DESC', 'Enter short character description:')
    DisplayOnscreenKeyboard(1, 'SPAWN_DESC', '', 'A simple civilian', '', '', '', 128)
    while UpdateOnscreenKeyboard() == 0 do Wait(0) end
    if UpdateOnscreenKeyboard() ~= 1 then
        ESX.ShowNotification("~y~Spawn cancelled.", "info")
        return
    end
    local description = GetOnscreenKeyboardResult()
    if description == "" then description = "A simple civilian" end

    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) and timeout < 100 do
        Wait(100)
        timeout = timeout + 1
    end
    if not HasModelLoaded(modelHash) then
        ESX.ShowNotification("~r~Failed to load model: " .. modelName, "error")
        return
    end

    local npc = CreatePed(0, modelHash, coords.x, coords.y, coords.z, heading, true, false)
    SetModelAsNoLongerNeeded(modelHash)
    if not npc or npc == 0 then
        ESX.ShowNotification("~r~Failed to spawn NPC.", "error")
        return
    end

    FreezeEntityPosition(npc, true)
    SetBlockingOfNonTemporaryEvents(npc, true)
    SetPedFleeAttributes(npc, 0, 0)
    ClearPedTasksImmediately(npc)
    TaskStandStill(npc, -1)

    local role = "Stationary NPC"
    local npcId = string.format("static_%d_%.0f_%.0f_%.0f", modelHash, math.floor(coords.x / 5.0 + 0.5) * 5, math.floor(coords.y / 5.0 + 0.5) * 5, math.floor(coords.z / 5.0 + 0.5) * 5)
    Entity(npc).state:set('npci_id', npcId, true)
    Entity(npc).state:set('npci_role', role, true)
    Entity(npc).state:set('npci_mood', 'friendly', true)
    Entity(npc).state:set('npci_name', modelName, true)
    Entity(npc).state:set('npci_description', description, true)

    ESX.ShowNotification("~g~Stationary AI NPC spawned: " .. description, "success")
end, false)

-- ============================================================================
--              BACKGROUND LIFE LOOP (Client-Side Task Monitor)
-- ============================================================================
CreateThread(function()
    while true do
        Wait(5000)

        -- Monitor all active AI peds for task completion
        for ped, pedData in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and not pedData.isInConversation
                and not pedData.manualHold then
                local isTaskActive = GetIsTaskActive(ped, 210) or -- TaskGoToCoordAnyMeans
                                    GetIsTaskActive(ped, 200) or -- TaskWanderStandard
                                    GetIsTaskActive(ped, 222) or -- TaskGoToEntity
                                    GetIsTaskActive(ped, 241) or -- TaskStartScenarioInPlace
                                    GetIsTaskActive(ped, 235)    -- TaskEnterVehicle

                local pedVeh = GetVehiclePedIsIn(ped, false)
                local isDriver = pedVeh ~= 0 and GetPedInVehicleSeat(pedVeh, -1) == ped

                if isDriver then
                    -- Driving NPCs: the on-foot resume logic below (TaskGoToCoordAnyMeans
                    -- re-issued every 5s) used to fight the drive task and make the vehicle
                    -- stutter forward/backwards. Maintain one refreshed drive task instead.
                    local now = GetGameTimer()
                    local routine = pedData.routine or "WANDER"

                    if state.npcIsDriver and ped == state.driverNpc then
                        -- Companion driving thread owns this NPC, stay out of its way
                    elseif routine == "ESCAPE_COPS" then
                        if now - (pedData.lastDriveIssue or 0) >= 10000 then
                            ModifyVehicleTopSpeed(pedVeh, 20.0)
                            TaskVehicleDriveWander(ped, pedVeh, 50.0, 786468)
                            pedData.lastDriveIssue = now
                        end
                    elseif routine ~= "WANDER" and routine ~= "IDLE" then
                        local locCoords, radius = GetLocationCoords(pedData.targetLocation)
                        if locCoords and pedData.targetLocation and pedData.targetLocation ~= "none" then
                            local dist = #(GetEntityCoords(ped) - locCoords)
                            local arriveRadius = math.max(radius or 5.0, 15.0)
                            if dist <= arriveRadius then
                                if not pedData.hasArrivedByCar then
                                    pedData.hasArrivedByCar = true
                                    ClearPedTasks(ped)
                                    TaskVehicleTempAction(ped, pedVeh, 1, 5000)
                                end
                            else
                                pedData.hasArrivedByCar = nil
                                if now - (pedData.lastDriveIssue or 0) >= 10000 then
                                    SetDriverAbility(ped, 1.0)
                                    TaskVehicleDriveToCoordLongrange(ped, pedVeh, locCoords.x, locCoords.y, locCoords.z, 30.0, 786468, 25.0)
                                    pedData.lastDriveIssue = now
                                end
                            end
                        end
                    end
                    -- WANDER/IDLE drivers: leave the driving task alone (no walk/wander spam)

                else
                    -- T1-A: time-of-day schedule nudges idle peds between home/work/social
                    local isFollowed = state.isFollowing and ped == state.followNpc
                    if not isFollowed then
                        ApplySchedule(ped, pedData, GetGameTimer(), isTaskActive)
                    end

                    -- PATROL (AI engine action, target "none"): keep walking a beat
                    -- instead of standing forever on the first random waypoint.
                    if not isFollowed and not isTaskActive and (pedData.routine or "") == "PATROL"
                        and not pedData.isBusy and not pedData.weatherHold
                        and GetGameTimer() - (pedData.lastPatrolIssue or 0) >= 3000 then
                        local patrolCoords = GetEntityCoords(ped)
                        TaskGoToCoordAnyMeans(ped, patrolCoords.x + math.random(-50, 50),
                            patrolCoords.y + math.random(-50, 50), patrolCoords.z,
                            1.0, 0, 0, 786432, 0xbf800000)
                        pedData.lastPatrolIssue = GetGameTimer()
                    end

                    -- If ped has arrived at their destination and has a target location
                    if not isTaskActive and not isFollowed and pedData.targetLocation and pedData.targetLocation ~= "none" then
                        local pedCoords = GetEntityCoords(ped)
                        local locCoords, radius = GetLocationCoords(pedData.targetLocation)
                        if locCoords then
                            local dist = #(pedCoords - locCoords)
                            if dist <= (radius or 5.0) then
                                -- Arrived! Phase/role/weather/seat-aware scenario (T1-B)
                                pedData.scenarioIssuedAt = GetGameTimer()
                                StartScenarioSmart(ped, PickArrivalScenario(ped, pedData))
                                ActiveAIPeds[ped].routine = "SCENARIO"
                                ActiveAIPeds[ped].targetLocation = nil
                            end
                        end
                    end

                    -- Check if ped has no active task at all -> resume routine
                    if not isTaskActive and not isFollowed then
                        local routine = pedData.routine or "WANDER"
                        if routine ~= "WANDER" and routine ~= "IDLE" then
                            -- Re-apply routine task
                            local coords, _ = GetLocationCoords(pedData.targetLocation)
                            if coords then
                                TaskGoToCoordAnyMeans(ped, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
                            end
                        end
                    end
                end
            elseif not DoesEntityExist(ped) then
                -- Clean up despawned peds
                ActiveAIPeds[ped] = nil
            end
        end
    end
end)

-- ============================================================================
--              PROXIMITY-BASED MUTTERING LOOP
-- ============================================================================
CreateThread(function()
    local MUTTER_CHECK_INTERVAL = 20000
    local MUTTER_CHANCE = 15

    while true do
        Wait(MUTTER_CHECK_INTERVAL)

        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        for ped, pedData in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and not pedData.isInConversation then
                local pedCoords = GetEntityCoords(ped)
                local dist = #(playerCoords - pedCoords)

                if dist < 15.0 then
                    if math.random(1, 100) <= MUTTER_CHANCE then
                        TriggerServerEvent('npci_server:requestMutter', pedData.stateBagId, pedData.role, pedData.mood, pedData.routine, cachedWeather, BuildNpcChatCtx(ped, pedData))
                    end
                end
            end
        end
    end
end)

-- ============================================================================
--              NPC-TO-NPC CHAT DETECTION (Client-Side Proximity)
-- ============================================================================
CreateThread(function()
    local npcChatRange = (Config.NpcChat and Config.NpcChat.ProximityRange) or 3.0
    local npcChatCooldownTime = (Config.NpcChat and Config.NpcChat.CooldownTime) or 120

    while true do
        Wait(10000)

        local pedList = {}
        for ped, data in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and not data.isBusy
                and not data.isInConversation and not data.manualHold
                and not (state.isFollowing and ped == state.followNpc) then
                table.insert(pedList, { ped = ped, data = data })
            end
        end

        -- Check each pair of peds for proximity
        for i = 1, #pedList do
            for j = i + 1, #pedList do
                local a = pedList[i]
                local b = pedList[j]

                local coordsA = GetEntityCoords(a.ped)
                local coordsB = GetEntityCoords(b.ped)
                local dist = #(coordsA - coordsB)

                if dist < npcChatRange then
                    -- Check cooldown
                    local now = GetGameTimer() / 1000
                    if now - (a.data.lastChatTime or 0) > npcChatCooldownTime and now - (b.data.lastChatTime or 0) > npcChatCooldownTime then
                        -- Trigger chance is rolled SERVER-side (relation-aware, T2-F)
                        -- Lock both peds
                        a.data.isBusy = true
                        b.data.isBusy = true
                        a.data.lastChatTime = now
                        b.data.lastChatTime = now

                        -- Turn them to face each other
                        TaskTurnPedToFaceEntity(a.ped, b.ped, 3000)
                        TaskTurnPedToFaceEntity(b.ped, a.ped, 3000)

                        -- Request the server to orchestrate the chat
                        TriggerServerEvent('npci_server:orchestrateNpcChat',
                            a.data.stateBagId, b.data.stateBagId,
                            a.data.role, b.data.role,
                            a.data.mood, b.data.mood,
                            a.data.name, b.data.name,
                            BuildNpcChatCtx(a.ped, a.data),
                            BuildNpcChatCtx(b.ped, b.data)
                        )
                    end
                end
            end
        end
    end
end)

RegisterNetEvent('npci_server:releaseFromChat', function(pedA_id, pedB_id)
    local pedA = GetPedByStateBagId(pedA_id)
    local pedB = GetPedByStateBagId(pedB_id)

    if pedA and ActiveAIPeds[pedA] then
        ActiveAIPeds[pedA].isBusy = false
        -- Resume their routine (shelter thread owns rain-kids; never wander them off)
        if ActiveAIPeds[pedA].weatherHold or ActiveAIPeds[pedA].manualHold then
            -- leave them be; the weather thread re-issues shelter within 15s
        else
        local routine = ActiveAIPeds[pedA].routine or "WANDER"
        if routine ~= "WANDER" and routine ~= "IDLE" then
            local coords, _ = GetLocationCoords(ActiveAIPeds[pedA].targetLocation)
            if coords then
                TaskGoToCoordAnyMeans(pedA, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
            else
                TaskWanderStandard(pedA, 10.0, 10)
            end
        else
            TaskWanderStandard(pedA, 10.0, 10)
        end
        end
    end

    if pedB and ActiveAIPeds[pedB] then
        ActiveAIPeds[pedB].isBusy = false
        if ActiveAIPeds[pedB].weatherHold or ActiveAIPeds[pedB].manualHold then
            -- owned by the weather thread
        else
        local routine = ActiveAIPeds[pedB].routine or "WANDER"
        if routine ~= "WANDER" and routine ~= "IDLE" then
            local coords, _ = GetLocationCoords(ActiveAIPeds[pedB].targetLocation)
            if coords then
                TaskGoToCoordAnyMeans(pedB, coords.x, coords.y, coords.z, 1.0, 0, 0, 786432, 0xbf800000)
            else
                TaskWanderStandard(pedB, 10.0, 10)
            end
        else
            TaskWanderStandard(pedB, 10.0, 10)
        end
        end
    end
end)

-- ============================================================================
--              RECEIVE AWAKENED PEDS FROM SERVER
-- ============================================================================
RegisterNetEvent('npci_server:receiveAwakenedPeds', function(peds)
    AwakenedPeds = peds or {}
end)

-- Request awakened peds on resource start
CreateThread(function()
    Wait(5000)
    TriggerServerEvent('npci_server:requestAwakenedPeds')
end)

-- Monitor for awakened peds entering proximity and activate them
CreateThread(function()
    while true do
        Wait(10000)
        if not AwakenedPeds or not next(AwakenedPeds) then
            Wait(30000)
        else
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)

            for stateBagId, pedData in pairs(AwakenedPeds) do
                if pedData.coords then
                    local dist = #(playerCoords - vector3(pedData.coords.x, pedData.coords.y, pedData.coords.z))
                    if dist < 100.0 then
                        AwakenedPeds[stateBagId] = nil
                    end
                end
            end
        end
    end
end)

CreateThread(function()
    local savedPreference = GetResourceKvpInt('npci_voice_playback')
    if savedPreference == 0 then
        state.voiceResponseEnabled = false
    else
        state.voiceResponseEnabled = true
    end
end)

RegisterCommand('toggleNpcVoice', function()
    state.voiceResponseEnabled = not state.voiceResponseEnabled

    if state.voiceResponseEnabled then
        SetResourceKvpInt('npci_voice_playback', 1)
        ESX.ShowNotification("~g~[NPCI] Voice Response: ENABLED")
    else
        SetResourceKvpInt('npci_voice_playback', 0)
        ESX.ShowNotification("~r~[NPCI] Voice Response: DISABLED")
    end
end, false)

RegisterKeyMapping('toggleNpcVoice', 'Toggle NPC AI Voice Responses', 'keyboard', 'O')

-- ============================================================================
--              3D THINKING INDICATOR (dots over NPC head)
-- ============================================================================
local function DrawThinkingText3D(coords, text)
    local onScreen, _x, _y = World3dToScreen2d(coords.x, coords.y, coords.z)
    if onScreen then
        SetTextScale(0.38, 0.38)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(220, 220, 220, 255)
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)

        local factor = (string.len(text)) / 370
        DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 75)
    end
end

CreateThread(function()
    local dotState = "."
    local frameCounter = 0

    while true do
        if state.npcIsThinking and state.isInteracting and state.currentNpc and DoesEntityExist(state.currentNpc) then
            Wait(100)

            frameCounter = frameCounter + 1
            if frameCounter % 3 == 0 then
                if dotState == "." then dotState = ".."
                elseif dotState == ".." then dotState = "..."
                else dotState = "." end
            end

            local headCoords = GetPedBoneCoords(state.currentNpc, 31086, 0.0, 0.0, 0.0)
            DrawThinkingText3D(vector3(headCoords.x, headCoords.y, headCoords.z + 0.38), "~b~Thinking~w~" .. dotState)
        else
            Wait(500)
            frameCounter = 0
        end
    end
end)

-- ============================================================================
--              LIVING WORLD THREADS (T1-C/D, T2-G/H/J, T3-I/J)
-- ============================================================================

-- Bark playback: short AI/canned lines spoken outside full conversations (T1-C/D)
RegisterNetEvent('npci_server:playBark', function(stateBagId, text, kind)
    if type(stateBagId) ~= 'string' or type(text) ~= 'string' or text == '' then return end
    local ped = GetPedByStateBagId(stateBagId)
    if not ped or not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then return end
    local playerPed = PlayerPedId()
    if playerPed == 0 then return end
    local coords = GetEntityCoords(ped)
    if #(GetEntityCoords(playerPed) - coords) > 12.0 then return end

    PlayTtsAudio(text, coords, 0.35, ped)

    if kind == 'greeting' then
        TaskPlayAnim(ped, "gestures@m@standing@casual", "gesture_hello", 8.0, -8.0, -1, 49, 0, 0, 0, 0)
    elseif kind == 'initiative' then
        -- Walk up to the player and open the full conversation on arrival
        if state.isInteracting or IsPedInAnyVehicle(playerPed, false) then return end
        TaskGoToEntity(ped, playerPed, -1, 2.2, 1.2, 0, 0)
        CreateThread(function()
            local tries = 0
            while DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and tries < 50 do
                Wait(400)
                tries = tries + 1
                if #(GetEntityCoords(ped) - GetEntityCoords(playerPed)) <= 2.8 then break end
            end
            local data = ActiveAIPeds[ped]
            if tries < 50 and not state.isInteracting and DoesEntityExist(ped)
                and not IsPedDeadOrDying(ped, true) and data
                and not data.isInConversation and not data.isBusy then
                StartInteraction(ped)
            end
        end)
    end
end)

-- T1-C: passing recognition barks (memory-gated on the server)
CreateThread(function()
    local G = Config.Greeting
    if not (G and G.Enabled) then return end
    while true do
        Wait(G.CheckIntervalMs or 12000)
        local playerPed = PlayerPedId()
        if playerPed ~= 0 and not IsPedDeadOrDying(playerPed, true) and not state.isInteracting
            and not IsPedInAnyVehicle(playerPed, false) then
            local pc = GetEntityCoords(playerPed)
            for ped, data in pairs(ActiveAIPeds) do
                if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                    and not data.isInConversation and not data.isBusy and not data.manualHold
                    and #(GetEntityCoords(ped) - pc) <= (G.Range or 3.0) then
                    TriggerServerEvent('npci_server:requestBark', 'greeting', data.stateBagId, data.role, data.mood)
                    break -- one request per tick; server cooldown gates repeats
                end
            end
        end
    end
end)

-- T1-D: NPC initiative - rarely approaches a known player on their own
CreateThread(function()
    local I = Config.Initiative
    if not (I and I.Enabled) then return end
    while true do
        Wait(I.CheckIntervalMs or 30000)
        local playerPed = PlayerPedId()
        if playerPed ~= 0 and not state.isInteracting and not IsPedDeadOrDying(playerPed, true)
            and not IsPedInAnyVehicle(playerPed, false) then
            local pc = GetEntityCoords(playerPed)
            local best, bestDist = nil, nil
            for ped, data in pairs(ActiveAIPeds) do
                if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                    and not data.isInConversation and not data.isBusy
                    and not data.manualHold
                    and ped ~= state.driverNpc
                    and not (state.isFollowing and ped == state.followNpc) then
                    local d = #(GetEntityCoords(ped) - pc)
                    if d > 6.0 and d <= (I.ApproachRange or 20.0) and (not bestDist or d < bestDist) then
                        best, bestDist = data, d
                    end
                end
            end
            if best then
                TriggerServerEvent('npci_server:requestBark', 'initiative', best.stateBagId, best.role, best.mood)
            end
        end
    end
end)

-- T2-H: bad weather - walk to shelter, wait it out, complain about it
CreateThread(function()
    local WB = Config.WeatherBehavior
    if not (WB and WB.Enabled) then return end
    local shelterWalkIssued = {} -- [ped] = GetGameTimer()
    while true do
        Wait(15000)
        local bad = IsBadWeather()
        for ped, data in pairs(ActiveAIPeds) do
            if not DoesEntityExist(ped) then
                shelterWalkIssued[ped] = nil
            elseif data.weatherHold then
                if not bad then
                    -- Weather cleared: back to normal life
                    data.weatherHold = false
                    data.shelterCoords = nil
                    data.routine = "WANDER"
                    data.targetLocation = nil
                    if not IsPedDeadOrDying(ped, true) and not data.isInConversation then
                        TaskWanderStandard(ped, 10.0, 10)
                    end
                elseif not IsPedDeadOrDying(ped, true) and not data.isInConversation and not data.isBusy then
                    local sc = data.shelterCoords
                    if sc then
                        local d = #(GetEntityCoords(ped) - sc)
                        if d > 4.0 then
                            local now = GetGameTimer()
                            if (shelterWalkIssued[ped] or 0) + 8000 < now and not GetIsTaskActive(ped, 210) then
                                TaskGoToCoordAnyMeans(ped, sc.x, sc.y, sc.z, 1.0, 0, 0, 786432, 0xbf800000)
                                shelterWalkIssued[ped] = now
                            end
                        elseif not GetIsTaskActive(ped, 241) and not IsPedSittingPose(ped) then
                            TaskStartScenarioInPlace(ped, "WORLD_HUMAN_STAND_MOBILE", 0, true)
                        end
                    end
                end
            elseif bad and not IsPedDeadOrDying(ped, true) and not data.isInConversation
                and not data.isBusy and ped ~= state.driverNpc and not IsPedInAnyVehicle(ped, false)
                and not data.manualHold and not (state.isFollowing and ped == state.followNpc) then
                local routine = data.routine or "WANDER"
                if routine == "WANDER" or routine == "IDLE" or routine == "SCENARIO" then
                    local pc = GetEntityCoords(ped)
                    local best, bestDist = nil, nil
                    for _, spot in ipairs(WB.ShelterSpots or {}) do
                        local sc = vector3(spot.x, spot.y, spot.z)
                        local d = #(pc - sc)
                        if d <= (WB.ShelterSearchRadius or 60.0) and (not bestDist or d < bestDist) then
                            best, bestDist = sc, d
                        end
                    end
                    if best then
                        data.weatherHold = true
                        data.shelterCoords = best
                        data.routine = "SHELTER"
                        data.targetLocation = nil
                        data.scenarioIssuedAt = GetGameTimer()
                        shelterWalkIssued[ped] = 0
                        if bestDist > 4.0 then
                            TaskGoToCoordAnyMeans(ped, best.x, best.y, best.z, 1.0, 0, 0, 786432, 0xbf800000)
                        else
                            TaskStartScenarioInPlace(ped, "WORLD_HUMAN_STAND_MOBILE", 0, true)
                        end
                        -- one weather complaint on the way (server rolls the chance)
                        TriggerServerEvent('npci_server:requestBark', 'weather', data.stateBagId, data.role, data.mood)
                    end
                end
            end
        end
    end
end)

-- T2-G: ambient street incidents between clustered NPCs
CreateThread(function()
    local INC = Config.Incidents
    if not (INC and INC.Enabled) then return end
    local incTypes = { "argument", "car_trouble", "dropped_groceries", "busker", "lost_tourist" }
    while true do
        Wait((INC.IntervalMinutes or 6) * 60000)
        if math.random(1, 100) > (INC.Chance or 65) then goto continue end
        local playerPed = PlayerPedId()
        if playerPed == 0 or IsPedDeadOrDying(playerPed, true) or state.isInteracting then goto continue end
        local pc = GetEntityCoords(playerPed)

        local pool = {}
        for ped, data in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                and not data.isInConversation and not data.isBusy and not data.weatherHold
                and not data.manualHold
                and ped ~= state.driverNpc and not (state.isFollowing and ped == state.followNpc)
                and not IsPedInAnyVehicle(ped, false) then
                local d = #(GetEntityCoords(ped) - pc)
                if d <= (INC.PlayerRange or 45.0) then
                    pool[#pool + 1] = { ped = ped, data = data, coords = GetEntityCoords(ped) }
                end
            end
        end

        if #pool >= (INC.MinPeds or 2) then
            local seed = pool[math.random(#pool)]
            local group = { seed }
            for _, cand in ipairs(pool) do
                if #group >= (INC.MaxPeds or 3) then break end
                if cand ~= seed and #(cand.coords - seed.coords) <= (INC.MaxPairDistance or 25.0) then
                    group[#group + 1] = cand
                end
            end
            if #group >= (INC.MinPeds or 2) then
                local participants = {}
                for i, g in ipairs(group) do
                    g.data.isBusy = true
                    participants[i] = { id = g.data.stateBagId, role = g.data.role, mood = g.data.mood }
                    for j = i + 1, #group do
                        TaskTurnPedToFaceEntity(g.ped, group[j].ped, 4000)
                    end
                end
                TriggerServerEvent('npci_server:orchestrateIncident', incTypes[math.random(#incTypes)], participants)
            end
        end
        ::continue::
    end
end)

-- T3-J: death watch - kill reporting, witness panic, corpse recovery
CreateThread(function()
    local D = Config.Death
    if not (D and D.Enabled) then return end
    local downAt = {}
    while true do
        Wait(4000)
        local playerPed = PlayerPedId()
        for ped, data in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) then
                if IsPedDeadOrDying(ped, true) then
                    if not downAt[ped] then
                        downAt[ped] = GetGameTimer()
                        local dc = GetEntityCoords(ped)
                        -- Report the kill if the local player did it (T2-E + T3-J)
                        local killer = GetPedSourceOfDeath(ped)
                        local killedByPlayer = playerPed ~= 0 and killer == playerPed
                        if not killedByPlayer and killer ~= 0 and DoesEntityExist(killer)
                            and GetPedInVehicleSeat(killer, -1) == playerPed then
                            killedByPlayer = true
                        end
                        if killedByPlayer then
                            TriggerServerEvent('npci_server:reportNpcDeath', data.stateBagId)
                        end
                        -- Witnesses panic (T3-J)
                        if D.WitnessPanic and playerPed ~= 0
                            and #(GetEntityCoords(playerPed) - dc) <= (D.WitnessRange or 18.0) then
                            TriggerServerEvent('npci_server:requestBark', 'panic', data.stateBagId, data.role, data.mood)
                            for ped2, data2 in pairs(ActiveAIPeds) do
                                if ped2 ~= ped and DoesEntityExist(ped2) and not IsPedDeadOrDying(ped2, true)
                                    and not data2.isInConversation and not data2.isBusy
                                    and not data2.manualHold
                                    and #(GetEntityCoords(ped2) - dc) <= (D.WitnessRange or 18.0) then
                                    TaskSmartFleeCoord(ped2, dc.x, dc.y, dc.z, 60.0, 8000, false, false)
                                end
                            end
                        end
                    end
                    -- Recovery: the soul refuses to stay dead (T3-J)
                    local recSec = D.RecoverySeconds or 0
                    if recSec > 0 and GetGameTimer() - downAt[ped] >= recSec * 1000 then
                        downAt[ped] = nil
                        ResurrectPed(ped)
                        SetEntityHealth(ped, GetEntityMaxHealth(ped))
                        ClearPedBloodDamage(ped)
                        ClearPedTasks(ped)
                        -- A new life: any player hold/freeze died with the old body
                        data.manualHold = nil
                        data.weatherHold = false
                        FreezeEntityPosition(ped, false)
                        data.routine = "WANDER"
                        data.targetLocation = nil
                        TaskWanderStandard(ped, 10.0, 10)
                    end
                else
                    downAt[ped] = nil
                end
            else
                downAt[ped] = nil
            end
        end
    end
end)

-- T2-E: player attacked an NPC (non-lethal) -> violent reputation bump
local lastAttackReport = {}
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    if type(args) ~= 'table' then return end
    local victim, attacker = args[1], args[2]
    if attacker ~= PlayerPedId() then return end
    if type(victim) ~= 'number' then return end
    if not ActiveAIPeds[victim] then return end
    SetTimeout(400, function()
        local data = ActiveAIPeds[victim]
        if not data or not DoesEntityExist(victim) then return end
        if IsPedDeadOrDying(victim, true) then return end -- death watch reports kills
        local now = GetGameTimer()
        if not lastAttackReport[victim] or now - lastAttackReport[victim] > 60000 then
            lastAttackReport[victim] = now
            TriggerServerEvent('npci_server:reportPlayerAttack', data.stateBagId)
        end
    end)
end)

-- T3-I: needs drift (hunger/energy/comfort) feeding the scenario picker
CreateThread(function()
    local N = Config.Needs
    if not (N and N.Enabled) then return end
    while true do
        Wait(60000)
        for ped, data in pairs(ActiveAIPeds) do
            if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                local n = data.needs
                if not n then
                    n = { hunger = math.random(55, 100), energy = math.random(55, 100), comfort = math.random(55, 100) }
                    data.needs = n
                end
                n.hunger = math.max(0, n.hunger - (N.HungerDriftPerMin or 0.4))
                n.energy = math.max(0, n.energy - (N.EnergyDriftPerMin or 0.3))
                n.comfort = math.max(0, n.comfort - (N.ComfortDriftPerMin or 0.2))
                -- They quietly sort themselves out before hitting zero (keeps variety cycling)
                if n.hunger <= 0 then n.hunger = math.random(50, 70) end
                if n.energy <= 0 then n.energy = math.random(50, 70) end
                if n.comfort <= 0 then n.comfort = math.random(55, 75) end
                -- Sitting down recharges energy and comfort (T3-I)
                if data.routine == "SCENARIO" and IsPedSittingPose(ped) then
                    n.energy = math.min(100, n.energy + (N.RecoveryOnSitPerMin or 2.5))
                    n.comfort = math.min(100, n.comfort + (N.RecoveryOnSitPerMin or 2.5))
                end
            end
        end
    end
end)
