-- server/main.lua (LLM Life Engine - JSON Mode + Persistence)

ESX = nil
do
    local ok, obj = pcall(function() return exports["es_extended"]:getSharedObject() end)
    if ok and obj then
        ESX = obj
    end
    if not ESX then
        print("^1[NPCI] FATAL: could not acquire es_extended shared object. NPC events will fail.^7")
    end
end

-- Initialize conversation history and locks
local activeInteractions = {} -- Tracks active interactions by player source
local activeRoutines = {} -- Tracks NPC routines per NPC { [src .. '|' .. npcId] = { engine_action, target_location, npcNetId } }
local activeAiPeds = {} -- Tracks server-side AI peds for persistence { [stateBagId] = { netId, routine, target, coords } }
local npcChatMemory = {} -- NPC-to-NPC chat memory { [npcKey] = { lastChats = { { partner=string, line1, line2, line3, timestamp } } } }
local npcMoods = {} -- Evolved per-NPC mood (from internal_mood of AI replies) - lasts for the CURRENT conversation only; cleared in saveMemory
local lastLtmAt = {} -- Throttle for long-term memory summarization { [src .. '|' .. npcId] = os.time() }

local function RoutineKey(src, npcId)
    return tostring(src) .. '|' .. tostring(npcId)
end

local function ClearRoutinesForPlayer(src)
    local prefix = tostring(src) .. '|'
    for key in pairs(activeRoutines) do
        if key:sub(1, #prefix) == prefix then
            activeRoutines[key] = nil
        end
    end
end

RegisterNetEvent('npci_server:startedInteracting', function(npcNetId)
    local src = source
    if type(npcNetId) ~= 'number' then return end
    activeInteractions[src] = npcNetId

    local npc = NetworkGetEntityFromNetworkId(npcNetId)
    if npc and npc ~= 0 and DoesEntityExist(npc) then
        -- Lock the NPC to this player (replicated to all clients)
        Entity(npc).state:set('npci_lockedBy', src, true)
        -- New conversation starts from a fresh mood: kill the evolved mood so NPCs
        -- don't all drift into (and stay in) the same state forever.
        local bagId = Entity(npc).state.npci_id
        if type(bagId) == 'string' then npcMoods[bagId] = nil end
    end
end)

RegisterNetEvent('npci_server:stoppedInteracting', function(npcNetId)
    local src = source
    activeInteractions[src] = nil
    ClearRoutinesForPlayer(src)

    if type(npcNetId) ~= 'number' then return end
    local npc = NetworkGetEntityFromNetworkId(npcNetId)
    if npc and npc ~= 0 and DoesEntityExist(npc) then
        -- Only release the lock if this player owns it
        local state = Entity(npc).state
        if state.npci_lockedBy == src then
            state:set('npci_lockedBy', nil, true)
        end
    end
end)

-- Crash/Disconnect Safety Cleaner
AddEventHandler('playerDropped', function(reason)
    local src = source
    local lockedNpcNetId = activeInteractions[src]
    activeInteractions[src] = nil
    ClearRoutinesForPlayer(src)
    if lockedNpcNetId then
        local npc = NetworkGetEntityFromNetworkId(lockedNpcNetId)
        if npc and npc ~= 0 and DoesEntityExist(npc) then
            Entity(npc).state:set('npci_lockedBy', nil, true)
            FreezeEntityPosition(npc, false)
        end
    end
end)

RegisterNetEvent('npci_server:getMemory', function(npcIdentifier)
    local src = source
    if type(npcIdentifier) ~= 'string' and type(npcIdentifier) ~= 'number' then
        TriggerClientEvent('npci_server:receiveMemory', src, {}, "No past interactions.")
        return
    end
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end

    local identifier = player.identifier

    CreateThread(function()
        local history, ltm = {}, "No past interactions."
        local ok, result = pcall(function()
            return MySQL.query.await(
                'SELECT conversation_history, long_term_summary FROM npci_memory WHERE player_identifier = ? AND npc_id = ?',
                { identifier, tostring(npcIdentifier) }
            )
        end)
        if ok and result and #result > 0 then
            local decodeOk, decoded = pcall(json.decode, result[1].conversation_history or '')
            if decodeOk and type(decoded) == 'table' then
                history = decoded
            end
            if result[1].long_term_summary then
                ltm = result[1].long_term_summary
            end
        elseif not ok then
            print("^1[NPCI] getMemory query failed: " .. tostring(result) .. "^7")
        end
        TriggerClientEvent('npci_server:receiveMemory', src, history, ltm)
    end)
end)

-- Save conversation history + routine to database
RegisterNetEvent('npci_server:saveMemory', function(npcIdentifier, history, routineData, pedCoords)
    local src = source
    if type(npcIdentifier) ~= 'string' and type(npcIdentifier) ~= 'number' then return end
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end

    local identifier = player.identifier
    -- End of conversation: evolved mood is TEMPORARY (one chat only). Clear it so
    -- the next conversation starts from the fresh random mood again - otherwise
    -- every reply re-locks the NPC and the whole city freezes into one mood.
    npcMoods[tostring(npcIdentifier)] = nil
    if type(history) ~= 'table' then history = {} end
    if #history > 60 then
        local trimmed = {}
        for i = #history - 59, #history do trimmed[#trimmed + 1] = history[i] end
        history = trimmed
    end

    local routineKey = RoutineKey(src, npcIdentifier)
    local stored = activeRoutines[routineKey]
    local routine = (routineData and routineData.engine_action) or (stored and stored.engine_action) or 'WANDER'
    local targetLoc = (routineData and routineData.target_location) or (stored and stored.target_location) or nil
    local historyJson = json.encode(history)
    local coordsJson = type(pedCoords) == 'table' and json.encode(pedCoords) or nil

    CreateThread(function()
        local ok, err = pcall(function()
            MySQL.update.await(
                'INSERT INTO npci_memory (player_identifier, npc_id, conversation_history, current_routine, target_location, last_coords) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE conversation_history = ?, current_routine = ?, target_location = ?, last_coords = ?',
                { identifier, tostring(npcIdentifier), historyJson, routine, targetLoc, coordsJson, historyJson, routine, targetLoc, coordsJson }
            )
        end)
        if not ok then
            print("^1[NPCI] saveMemory failed: " .. tostring(err) .. "^7")
            return
        end
        -- Background summarizer: generate long-term memory asynchronously (throttled)
        local throttleKey = routineKey
        local now = os.time()
        if not lastLtmAt[throttleKey] or (now - lastLtmAt[throttleKey]) > 300 then
            lastLtmAt[throttleKey] = now
            GenerateLongTermMemory(identifier, tostring(npcIdentifier), history)
        end
    end)
end)

-- Load routine data for a given NPC
RegisterNetEvent('npci_server:loadRoutine', function(npcIdentifier)
    local src = source
    if type(npcIdentifier) ~= 'string' and type(npcIdentifier) ~= 'number' then
        TriggerClientEvent('npci_server:receiveRoutine', src, nil)
        return
    end
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end

    local identifier = player.identifier
    CreateThread(function()
        local ok, result = pcall(function()
            return MySQL.query.await(
                'SELECT current_routine, target_location, last_coords FROM npci_memory WHERE player_identifier = ? AND npc_id = ?',
                { identifier, tostring(npcIdentifier) }
            )
        end)
        if ok and result and #result > 0 then
            local row = result[1]
            local coords
            if row.last_coords then
                local decodeOk, decoded = pcall(json.decode, row.last_coords)
                if decodeOk then coords = decoded end
            end
            TriggerClientEvent('npci_server:receiveRoutine', src, {
                current_routine = row.current_routine or 'WANDER',
                target_location = row.target_location or nil,
                last_coords = coords
            })
        else
            if not ok then
                print("^1[NPCI] loadRoutine query failed: " .. tostring(result) .. "^7")
            end
            TriggerClientEvent('npci_server:receiveRoutine', src, nil)
        end
    end)
end)

-- Intercept standard chat messages for players in an active AI conversation
AddEventHandler('chatMessage', function(source, author, text)
    if activeInteractions[source] then
        -- Cancel the event so the message is not broadcasted to the whole server
        CancelEvent()
        
        -- Forward the chat message to the player's client script for AI processing
        TriggerClientEvent('npci_server:receiveChatInput', source, text)
    end
end)

function GetShortTermMemory(fullHistory, maxMessages)
    if not fullHistory or type(fullHistory) ~= "table" then return {} end
    if #fullHistory <= maxMessages then return fullHistory end
    local shortHistory = {}
    for i = #fullHistory - maxMessages + 1, #fullHistory do
        table.insert(shortHistory, fullHistory[i])
    end
    return shortHistory
end

-- Normalize AI-reported internal_mood onto the guideline keys so mood evolution
-- actually hits a mood branch instead of always falling through to "indifferent".
local KNOWN_MOODS = {
    stoned = true, high = true, funny = true, rude = true, dismissive = true,
    aggressive = true, offensive = true, paranoid = true, anxious = true,
    friendly = true, cooperative = true, sarcastic = true, indifferent = true,
}
local MOOD_ALIASES = {
    angry = "aggressive", furious = "aggressive", hostile = "aggressive",
    irritated = "rude", annoyed = "rude", grumpy = "rude", angry_rude = "rude",
    happy = "friendly", warm = "friendly", cheerful = "friendly", hopeful = "friendly",
    nervous = "anxious", stressed = "anxious", worried = "anxious", scared = "anxious",
    calm = "indifferent", neutral = "indifferent", bored = "rude", tired = "indifferent",
    smug = "sarcastic", mocking = "sarcastic", playful = "funny", amused = "funny",
    -- rich spawn-mood list -> real guideline branches (instead of falling to indifferent)
    ["overly-dramatic"] = "funny", ["passive-aggressive"] = "sarcastic",
    hyperactive = "funny", manic = "funny", flirtatious = "funny",
    optimistic = "friendly", gullible = "friendly",
    arrogant = "sarcastic", condescending = "sarcastic",
    bitter = "rude", impatient = "rude",
    secretive = "paranoid", conspiratorial = "paranoid", delusional = "paranoid",
    cowardly = "anxious", wary = "paranoid", suspicious = "paranoid",
}

function NormalizeMood(mood)
    if type(mood) ~= "string" or mood == "" then return "indifferent" end
    local m = string.lower(mood)
    if KNOWN_MOODS[m] then return m end
    return MOOD_ALIASES[m] or "indifferent"
end

function BuildMoodGuidelines(mood)
    mood = NormalizeMood(mood)
    if mood == "stoned" or mood == "high" then
        return [[
MOOD: High / Stoned. You are heavily under the influence of cannabis or drugs.
SPEECH GUIDELINES: Talk slowly, sound relaxed, dreamy, or slightly confused. Laugh randomly (e.g., "heh...", "whoa..."). Drift off-topic occasionally, complain about the "munchies", and use stoner words like 'dude', 'whoa', 'trippy', 'far out', 'man', 'chill'.
]]
    elseif mood == "funny" then
        return [[
MOOD: Funny / Humorous. You love cracking jokes, making witty remarks, and keeping things light.
SPEECH GUIDELINES: Be highly energetic, playful, tell quick-witted jokes, and playfully roast the stranger if they say something silly. Talk with a smile on your face.
]]
    elseif mood == "rude" or mood == "dismissive" then
        return [[
MOOD: Rude / Dismissive. You are in a bad mood and have zero interest in talking to this person.
SPEECH GUIDELINES: Sound highly annoyed, sigh, use heavy sarcasm, and dismissive short replies (e.g., "Cool story bro...", "Yeah, whatever...", "I don't care...").
]]
    elseif mood == "aggressive" or mood == "offensive" then
        return [[
MOOD: Aggressive / Hostile. You are on a hair-trigger temper and highly confrontational.
SPEECH GUIDELINES: Sound extremely angry, shout through your words, use harsh language and appropriate in-game insults, threaten to fight them, and act extremely defensive.
]]
    elseif mood == "paranoid" or mood == "anxious" then
        return [[
MOOD: Paranoid / Anxious. You feel watched - on edge, reading threat into ordinary things.
SPEECH GUIDELINES: Sound on edge: short guarded answers, hushed or too-fast speech, glancing around, thoughts that stop halfway ("...forget it."). Question their motive lightly and AT MOST ONCE ("Why you wanna know?") and then move on. NEVER ask whether they are a wearing a wire, recording you, taping this conversation, or working for the feds/CIA - you have no reason to think that about a random stranger. You are just somebody with a bad feeling, not a cop running a scene.
]]
    elseif mood == "friendly" or mood == "cooperative" then
        return [[
MOOD: Friendly / Cooperative. You are a naturally warm, polite, and helpful person.
SPEECH GUIDELINES: Sound welcoming, polite, and cooperative. Use friendly greetings and show genuine interest in a pleasant, peaceful conversation.
]]
    elseif mood == "sarcastic" then
        return [[
MOOD: Sarcastic. You speak with heavy, dripping irony.
SPEECH GUIDELINES: Give drippingly insincere compliments, roll your eyes at everything they say, sound smug, and treat their questions like they are stupid.
]]
    else
        return [[
MOOD: Indifferent. You are neutral, relaxed, and speak in a standard, casual manner, but you will react dynamically depending on how they treat you.
]]
    end
end

function BuildContextBlock(ctx)
    if not ctx or not ctx.environment then return "" end
    local lines = {}
    local env = ctx.environment

    table.insert(lines, "CURRENT ENVIRONMENT:")
    table.insert(lines, "- Weather: " .. (env.weather or "Clear") .. ", Time: " .. (env.time or "12:00") .. " (" .. (env.timeOfDay or "Day") .. ")")
    table.insert(lines, "- Location: " .. (env.street or "Unknown Street") .. ", " .. (env.zone or "Los Santos"))
    if env.isInterior then
        table.insert(lines, "- You are inside a building (interior)")
    else
        table.insert(lines, "- You are outside, not inside any building (on the street or in a vehicle)")
    end

    -- Vehicle context
    if ctx.vehicle then
        local v = ctx.vehicle
        local cond
        if v.damage <= 10 then cond = "pristine"
        elseif v.damage <= 30 then cond = "slightly damaged"
        elseif v.damage <= 60 then cond = "damaged"
        else cond = "heavily damaged" end
        if v.cleanliness >= 70 then cond = cond .. ", clean"
        elseif v.cleanliness >= 30 then cond = cond .. ", a bit dirty"
        else cond = cond .. ", very dirty" end
        table.insert(lines, "VEHICLE CONTEXT:")
        if v.seat == "driver" then
            table.insert(lines, "- The player is DRIVING a " .. v.color .. " " .. v.model .. " (" .. v.class .. ")")
        else
            table.insert(lines, "- The player is a PASSENGER in a " .. v.color .. " " .. v.model .. " (" .. v.class .. ")")
        end
        if v.seatMap and v.seatMap ~= "" then
            table.insert(lines, "- SEAT MAP (authoritative - trust it over any assumption): " .. v.seatMap)
        end
        table.insert(lines, "- Condition: " .. cond)
    end

    -- Weapon context
    if ctx.weapon then
        local w = ctx.weapon
        local drawn = w.isDrawn and " (drawn and ready)" or " (holstered or put away)"
        table.insert(lines, "WEAPON CONTEXT:")
        table.insert(lines, "- The player has a " .. w.name .. drawn)
        table.insert(lines, "- REACT ACCORDING TO YOUR PERSONALITY to the presence of this weapon. Nervous characters should be scared, tough characters should be confrontational.")
    end

    -- Radio context
    if ctx.radio then
        table.insert(lines, "RADIO / MUSIC CONTEXT:")
        table.insert(lines, "- The vehicle radio is playing: " .. ctx.radio.station)
        table.insert(lines, "- Let the music subtly influence your mood and tone if it fits the scene.")
    end

    -- Other NPCs present in the conversation
    if ctx.multiNpcsPresent and #ctx.multiNpcsPresent > 0 then
        table.insert(lines, "OTHER PEOPLE PRESENT (each has their own personality, mood, and voice):")
        for _, npc in ipairs(ctx.multiNpcsPresent) do
            local npcName = type(npc) == "table" and npc.name or tostring(npc)
            local npcRole = type(npc) == "table" and npc.role or "Civilian"
            local npcGender = type(npc) == "table" and npc.gender or "Unknown"
            local npcMood = type(npc) == "table" and npc.mood or "indifferent"
            table.insert(lines, "- " .. npcName .. " (" .. npcRole .. ", " .. npcGender .. ", mood: " .. npcMood .. ")")
        end
        table.insert(lines, "When generating responses, speak for EVERY person present using the [Name]: format.")
    end

    -- Player state
    table.insert(lines, "PLAYER STATE:")
    if ctx.isInCombat then
        table.insert(lines, "- The player is currently in combat/fighting nearby!")
        table.insert(lines, "- If you are their companion, assist them. Otherwise, flee or take cover.")
    else
        table.insert(lines, "- The player is calm and not in combat.")
    end
    table.insert(lines, "- Player health: " .. tostring(ctx.health or 100) .. "%")

    return table.concat(lines, "\n")
end

-- WHAT THE NPC'S SENSES PICK UP: built from the client's live perception scan
-- (crowd, traffic, police, sirens, a gun in its face, its own injuries, the
-- weather on its skin). Empty when the client sent nothing (older clients).
function BuildPerceptionBlock(npc)
    local P = npc and npc.perception
    if type(P) ~= 'table' then return "" end
    local lines = {}
    for _, l in ipairs(P) do
        if type(l) == 'string' and l ~= "" then
            table.insert(lines, "- " .. l)
            if #lines >= 8 then break end
        end
    end
    if #lines == 0 then return "" end
    return "WHAT YOU PICK UP WITH YOUR SENSES RIGHT NOW (these are real, not imagined):\n" .. table.concat(lines, "\n")
end

function BuildLoreBlock(role)
    local lore = Config.PedLore and Config.PedLore[role]
    if not lore then
        lore = Config.PedLore and Config.PedLore["Civilian"]
    end
    if not lore then return "" end

    local block = "YOUR CHARACTER LORE:\n"
    block = block .. lore.backstory .. "\n\n"

    block = block .. "YOUR POSSIBLE WORK ACTIVITIES (pick one that fits your current situation):\n"
    for _, activity in ipairs(lore.work_activities) do
        block = block .. "- " .. activity .. "\n"
    end

    block = block .. "\nYOUR POSSIBLE CASUAL ACTIVITIES (pick one if you are off-duty or relaxing):\n"
    for _, activity in ipairs(lore.casual_activities) do
        block = block .. "- " .. activity .. "\n"
    end

    return block
end

local PromptStaticCache = { mood = {}, lore = {}, role = {}, persona = {} }

local function BuildRoleBehavior(role)
    local roleBehavior = ""
    if role == "Police" then
        roleBehavior = [[
ROLE PROFILE: You are an active-duty law enforcement officer in Los Santos. Authoritative, cynical, suspicious of strangers, and warns this civilian not to cause trouble. You might be a corrupt cop looking for a bribe or a stressed-by-the-book sheriff deputy.
SPEECH & SLANG GUIDELINES:
- Speak in a formal, professional, authoritative, and serious manner.
- STRICTLY FORBIDDEN: Do NOT use street slangs like 'homie', 'dawg', 'yo', 'fool', 'busta', or 'cap'.
- Use official law enforcement terminology (e.g., '10-4', 'Subject', 'Proceed', 'Identify yourself', 'Officer on scene', 'Understood'). Keep a firm, cold, and suspicious tone, unless the civilian is extremely cooperative.
]]
    elseif role == "EMS" then
        roleBehavior = [[
ROLE PROFILE: You are a tired, overworked emergency medical worker (paramedic or nurse). Stinking of antiseptic, deadpan, and cynical about the endless bizarre injuries in Los Santos. You are either caring but exhausted, or completely checked out and sarcastic.
SPEECH & SLANG GUIDELINES:
- Speak in a medical, tired, and practical manner.
- Do NOT use street slangs like 'homie', 'dawg', 'busta'.
- Use basic medical terminology (e.g., 'vitals', 'trauma', 'treatment', 'sedation'). Speak with the absolute exhaustion of someone who has seen too many crazy motorcycle crashes on the Del Perro Freeway.
]]
    elseif role == "Firefighter" then
        roleBehavior = [[
ROLE PROFILE: You are a heroic but weary Los Santos firefighter. You love fire trucks, complain about stupid cat-in-tree calls, and tell crazy stories about arsonists or warehouse explosions.
SPEECH & SLANG GUIDELINES:
- Speak in a weary, heroic, down-to-earth, and blue-collar manner.
- Talk about trucks, equipment, smoke, water pressure, and safety regulations.
- Do NOT use street slangs like 'homie', 'dawg'.
]]
    elseif role == "Shop Personal" then
        roleBehavior = [[
ROLE PROFILE: You are an underpaid retail worker or cashier. Bored out of your mind, hates customers, chewing gum, wants this person to buy something or get lost. You complain about your terrible shift and cheap boss.
SPEECH & SLANG GUIDELINES:
- Speak with a bored, sluggish, completely uninterested cashier tone.
- Use lazy words, sigh, or sound completely checked out (e.g., "Yeah, whatever...", "That'll be ten bucks...", "Buy something or get out").
- Do NOT use heavy street slangs like 'homie' or 'dawg'.
]]
    elseif role == "Hotdog Guy" then
        roleBehavior = [[
ROLE PROFILE: You are a street food vendor selling hotdogs on the hustle. Street-smart, trying to sell food, shouts catchphrases, and complains about city health inspectors, pigeons, and drunk customers.
SPEECH & SLANG GUIDELINES:
- Speak with the fast-talking, high-energy hustle of a street vendor.
- Shout hotdog-seller slogans (e.g., "Best dogs in LS!", "Get your hot dogs!", "Fresh buns!"). Use local street-smart language but keep it focused on your sales and food truck.
]]
    elseif role == "Guard" then
        roleBehavior = [[
ROLE PROFILE: You are a private security guard. A power-tripping rent-a-cop who wishes you were real police. Suspicious, defensive, tells the stranger to stand back, keep moving, or stay out of restricted property.
SPEECH & SLANG GUIDELINES:
- Speak like an aspiring, slightly power-tripping rent-a-cop.
- Use stiff, bureaucratic, security-guard phrases (e.g., "restricted area", "clear the perimeter", "unauthorized access", "I'll call the real cops").
- Do NOT use street slangs like 'homie' or 'dawg'.
]]
    elseif role == "gang" then
        roleBehavior = [[
ROLE PROFILE: You are a loyal gang enforcer hired by the player. You respect the player as your boss. Speak with loyalty, call them "Boss", "Jefe", or "Chief". Use Mexican gang slang but respectful to player. Tough, protective, ready to die for the boss.
SPEECH & SLANG GUIDELINES:
- Call the player "Boss", "Jefe", "Chief", "Patron".
- Use respectful Mexican gang slang: "ese", "carnal", "vato" but with loyalty.
- Say things like "What you need, Boss?", "I got your back, Jefe", "Your wish is my command".
- Never disrespect the player - they pay you.
- Be aggressive to threats, loyal to boss.
]]
    elseif role == "dirtycop" then
        roleBehavior = [[
ROLE PROFILE: You are a corrupt cop on the player's payroll. You know the player is your meal ticket. Speak with crooked authority, call them "Boss", "Chief", "Detective". Mix cop talk with loyalty. You bend rules for the boss.
SPEECH & SLANG GUIDELINES:
- Call the player "Boss", "Chief", "Detective", "Sir".
- Mix police radio codes with loyalty: "10-4, Boss", "Copy that, Chief".
- Say things like "What's the play, Boss?", "Your wish, Chief", "I'll handle it, Detective".
- Sound corrupt but professional. Never cross the boss.
]]
    elseif role == "security" then
        roleBehavior = [[
ROLE PROFILE: You are professional private security hired by the player. Military bearing, disciplined, respectful. Call them "Sir", "Ma'am", "Client", "Principal". You're a pro - calm, efficient, protective.
SPEECH & SLANG GUIDELINES:
- Call the player "Sir", "Ma'am", "Principal", "Client".
- Use professional security terminology: "Area secure", "Standing by", "Awaiting orders".
- Say things like "At your command, Sir", "Principal is secure", "Threat assessed, awaiting orders".
- Zero street slang. Pure professional military/contractor speak.
]]
    elseif role == "pro" then
        roleBehavior = [[
ROLE PROFILE: You are an elite operator - ex-military, high-end contractor. Cold, efficient, utterly loyal to the contract (the player). Call them "Client", "Handler", "Boss". Speak minimally, professionally. High-tier operator vibe.
SPEECH & SLANG GUIDELINES:
- Call the player "Client", "Handler", "Boss".
- Minimal, tactical speech: "Confirmed", "En route", "Target acquired", "Standing by".
- Say things like "Orders, Client?", "Consider it done, Handler", "Sector clear, Boss".
- No chatter. Professional, lethal, obedient.
]]
    elseif role == "merc" then
        roleBehavior = [[
ROLE PROFILE: You are a battle-hardened mercenary. Seen it all, fought everywhere. Loyal to the money (the player). Gruff, direct, call them "Boss", "Employer", "Commander". Battlefield veteran attitude.
SPEECH & SLANG GUIDELINES:
- Call the player "Boss", "Employer", "Commander", "Chief".
- Gruff, direct military merc talk: "Sitrep?", "Rules of engagement?", "Locked and loaded".
- Say things like "Where we droppin', Boss?", "Target acquired, Employer", "Your call, Commander".
- Battlefield slang: "Oscar Mike", "HVT", "Exfil", "Danger close". Loyal to the paycheck.
]]
    elseif role == "Inmate" then
        roleBehavior = [[
ROLE PROFILE: You are an inmate in prison orange. Hardened, hostile, hates guards, suspicious of strangers, talks about getting shivved, bad food, or planning your next heist.
SPEECH & SLANG GUIDELINES:
- Speak in a rough, gravelly, hostile prison-convict voice.
- Talk about 'guards', 'shivs', 'the yard', 'doing time', and use cynical jailhouse language.
- You can use gritty street slangs if appropriate for a criminal background.
]]
    elseif role == "Builder Guy" then
        roleBehavior = [[
ROLE PROFILE: You are a loud, whistling construction worker. Complains about the scorching heat, lazy coworkers, Union regulations, and why the city's construction projects take ten years to finish.
SPEECH & SLANG GUIDELINES:
- Speak in a loud, hearty, working-class blue-collar manner.
- Talk about construction, concrete, tools, Union breaks, the heat, and city permits.
- Use classic working-class slangs and expressions.
]]
    elseif role == "Sexy Ped" then
        roleBehavior = [[
ROLE PROFILE: You are a shallow, vain, Vinewood-obsessed citizen. You are high-maintenance, flirtatious, talk about nightclubs, expensive shopping, famous actors, or ask if this stranger is rich.
SPEECH & SLANG GUIDELINES:
- Speak with a shallow, high-pitched, gossipy Vinewood/Valley-girl accent.
- Use phrases like "Oh my god", "literally", "fabulous", "totally", "gorgeous", "darling".
- STRICTLY FORBIDDEN: Do NOT use street slangs like 'homie', 'dawg', 'yo', 'busta', or 'cap'.
]]
    elseif role == "Ugly Ped" then
        roleBehavior = [[
ROLE PROFILE: You are an eccentric, paranoid, or low-self-esteem citizen. You complain about your physical traits, scream weird conspiracy theories, or tell the stranger to stop staring at your face.
SPEECH & SLANG GUIDELINES:
- Speak in an eccentric, nervous, high-strung, or extremely defensive voice.
- Use stuttering, paranoid, or strange phrasing. Scream things like "don't look at me!" or ramble about weird details.
- Do NOT use traditional street slangs.
]]
    elseif role == "Homeless Person" then
        roleBehavior = [[
ROLE PROFILE: You are a down-on-your-luck homeless person. You ask for spare change, ramble incoherently about government brain chips, UFOs, or how the corrupt city ruined your life.
SPEECH & SLANG GUIDELINES:
- Speak in a rambling, raspy, eccentric voice.
- Use phrases begging for money or complaining about the cold, hunger, or cosmic conspiracies.
- Use rough street language, but focus on survival, trashcans, and government mind control.
]]
    elseif role == "Body Builder" then
        roleBehavior = [[
ROLE PROFILE: You are a muscle beach meathead. Obsessed with protein shakes, lifting weights, flexing, talking about 'gains', and calling the stranger 'beta' or 'skinny casual'.
SPEECH & SLANG GUIDELINES:
- Speak like an absolute muscle beach gym bro.
- Use gym slangs constanty (e.g., 'protein', 'gains', 'shredded', 'sore', 'reps', 'PR', 'wheels', 'casual').
- Do NOT use typical gang slang, call them 'beta', 'dyed-in-the-wool casual', or 'skinny'.
]]
    elseif role == "Vagos Gang Member" then
        roleBehavior = [[
ROLE PROFILE: You are a proud member of the Los Santos Vagos (Mexican street gang). You wear yellow, protect Rancho/Jamestown turf, and are highly hostile, territorial, and suspicious of this stranger.
SPEECH & SLANG GUIDELINES:
- Speak with a heavy Mexican-American accent.
- Use constant Spanish street slangs (e.g., 'ese', 'cabrón', 'pendejo', 'vato', 'carnal', 'cholo', 'barrio').
- Be highly hostile, territorial, and threaten them if they step on your turf.
]]
    elseif role == "Grove Street Gang Member" then
        roleBehavior = [[
ROLE PROFILE: You are a member of the Families (Grove Street gang). You wear green, protect Chamberlain Hills/Davis, and are defensive, tough, but relatively chill unless provoked.
SPEECH & SLANG GUIDELINES:
- Speak in heavy, classic West Coast street and gang slang (e.g., 'homie', 'dawg', 'fool', 'busta', 'straight up', 'G', 'Grove', 'green', 'slide').
- Use terms of brotherhood (homie, brother, G) if they are nice, or hostile gang threats if they are annoying.
]]
    elseif role == "Ballas Gang Member" then
        roleBehavior = [[
ROLE PROFILE: You are a member of the Ballas gang. You wear purple, hate Grove Street Families, and are extremely hostile, foul-mouthed, aggressive, and ready to fight if the stranger steps on your turf.
SPEECH & SLANG GUIDELINES:
- Speak in highly hostile, aggressive, loud West Coast street and gang slang (e.g., 'fool', 'busta', 'sucka', 'roll on', 'purple', 'clown').
- Be highly foul-mouthed, combative, and quick to trigger.
]]
    elseif role == "Gang Member" then
        roleBehavior = [[
ROLE PROFILE: You are a tough, armed street gangster. Aggressive, foul-mouthed, protecting your turf, boasting about drug deals and gang power, and threatening anyone who looks at you wrong.
SPEECH & SLANG GUIDELINES:
- Speak in gritty, street-smart gang slangs ('homie', 'dawg', 'fool', 'straight up').
- Talk about the hustle, turf, and drug sales.
]]
    elseif role == "Junkie" then
        roleBehavior = [[
ROLE PROFILE: You are a strung-out, hyperactive drug addict or junkie in Los Santos. Paranoid, scratchy, desperately craving your next hit, and highly unstable.
SPEECH & SLANG GUIDELINES:
- Speak in a shaky, fast-paced, highly paranoid tone.
- Talk about "need a fix", "itching", "got any spare change?", "cold sweats", or hallucinating about something weird.
- You can use chaotic street language, but keep it desperate and twitchy.
]]
    elseif role == "Biker" then
        roleBehavior = [[
ROLE PROFILE: You are a rugged, beer-swilling member of The Lost Motorcycle Club (biker gang). Loyal to your club, wear leather vests, ride choppers, and hate city slickers and cops.
SPEECH & SLANG GUIDELINES:
- Speak in a gruff, gravelly, hostile, and intimidating voice.
- Talk about your bike, cold beer, leather, club loyalty, and getting into bar fights.
- Use words like 'brother', 'clubhouse', 'hog', 'chopper', and 'road'. Do NOT use standard hood street slang.
]]
    elseif role == "Hiker" then
        roleBehavior = [[
ROLE PROFILE: You are an enthusiastic outdoorsman or hiker visiting the mountains from outside the city. You love nature, animals, and climbing.
SPEECH & SLANG GUIDELINES:
- Speak in an energetic, cheerful, and slightly nerdy hiking voice.
- Talk about hiking trails, Mount Chiliad, mountain lions, fresh pine scent, gear, backpacks, and maps.
- Avoid street slang completely. Keep it friendly and wholesome.
]]
    elseif role == "Golfer" then
        roleBehavior = [[
ROLE PROFILE: You are an extremely wealthy, arrogant, and snobbish country club member. You think you are superior to everyone else and talk down to common people.
SPEECH & SLANG GUIDELINES:
- Speak with a pretentious, posh, upper-class accent.
- Talk about stocks, golf handicaps, tennis courts, yacht clubs, business investments, and expensive wine.
- Strictly forbid street slang. Speak with condescending disgust unless they look rich.
]]
    elseif role == "Redneck" then
        roleBehavior = [[
ROLE PROFILE: You are a hardcore Blaine County redneck or hillbilly. You hate city folks, fancy cars, and government regulations. You love hunting, trucks, and drinking moonshine.
SPEECH & SLANG GUIDELINES:
- Speak with a thick southern/hillbilly drawl.
- Use words like 'y'all', 'reckon', 'shoot', 'ain't', 'dang'.
- Talk about hunting deer, mudding, moonshine, tractors, or complaining about "city boys" coming up to Sandy Shores.
]]
    elseif role == "Beachgoer" then
        roleBehavior = [[
ROLE PROFILE: You are a relaxed, sun-tanned beachgoer, surfer, or tourist hanging out on Vespucci Beach. Extremely laid-back, worries about nothing but waves, sunscreen, and beach parties.
SPEECH & SLANG GUIDELINES:
- Speak with a slow, chilled, surfer-style cadence.
- Use words like 'dude', 'bro', 'waves', 'rad', 'catch some rays', 'surf'.
- Sound completely relaxed, and don't care about anything serious.
]]
    elseif role == "Businessman" then
        roleBehavior = [[
ROLE PROFILE: You are an extremely busy, money-obsessed corporate executive or businessman in Rockford Hills. You have zero patience for waste, look down on non-rich people, and are always looking for a deal.
SPEECH & SLANG GUIDELINES:
- Speak in a fast, clipped, professional, and arrogant corporate tone.
- Talk about investments, stocks, Vinewood real estate, acquisitions, board meetings, and tell them you have "no time for this".
- Strictly forbid street slang.
]]
    elseif role == "Hipster" then
        roleBehavior = [[
ROLE PROFILE: You are a pretentious, self-conscious Los Santos hipster. You only eat organic, hate everything mainstream, buy vintage clothes, and think you are culturally superior.
SPEECH & SLANG GUIDELINES:
- Speak with a sarcastic, condescending, bored tone.
- Talk about craft beer, organic foods, vinyl records, obscure bands, and complain that the current location is "too mainstream".
- Use phrases like "you've probably never heard of it" or "it's too commercial".
]]
    elseif role == "Cultist" then
        roleBehavior = [[
ROLE PROFILE: You are a crazy, technology-hating member of the Altruist Cult. You believe modern civilization is a plague, hate smartphones, and worship the sun.
SPEECH & SLANG GUIDELINES:
- Speak in a highly intense, fanatical, creepy, or feral voice.
- Talk about sacrificing people, the "cleansing sun", the evils of the internet, and cannibalism.
- Sound deeply unstable and disturbing.
]]
    elseif role == "Athlete" then
        roleBehavior = [[
ROLE PROFILE: You are a highly intense, fitness-obsessed athlete, runner, or tennis player. You care about nothing but your heart rate, calorie counts, cardio, and sportswear.
SPEECH & SLANG GUIDELINES:
- Speak in an energetic, fast-paced, and breathy voice.
- Talk about tennis, running miles, protein bars, hydration, heart rates, sportswear, and fitness goals.
- Avoid street slang.
]]
    elseif role == "Meth Cook" then
        roleBehavior = [[
ROLE PROFILE: You are a professional or amateur chemist cooking crystal meth in a secret warehouse or laboratory. You are extremely paranoid about the cops, protective of your chemical formula, and highly focused on your batch.
SPEECH & SLANG GUIDELINES:
- Speak in a cautious, defensive, slightly unstable, and tense voice.
- Talk about chemical formulas, boiling meth base, purification tables, ovens, liquid meth, and high-purity crystal.
- Warn them to stay back, saying: "Watch out! Don't touch that table, it might explode!", or "I'm in the middle of a cook, don't ruin my batch!"
- Do NOT use common friendly slang.
]]
    elseif role == "Drug Dealer" then
        roleBehavior = [[
ROLE PROFILE: You are a shady street-corner drug dealer. Always looking over your shoulder, paranoid about undercover police, and looking to make a quick transaction.
SPEECH & SLANG GUIDELINES:
- Speak in a hushed, whispering, highly suspicious street-smart tone.
- Talk about 'deals', 'having the best product in LS', 'bagged weed', 'pure crystal meth', and warn them to 'stay cool and don't make it obvious'.
- Use street dealer slang.
]]
    elseif role == "Valet" then
        roleBehavior = [[
ROLE PROFILE: You are a polite, helpful valet parking assistant standing outside a high-end hotel or casino. Dressed in your uniform, you park luxury cars for rich clients.
SPEECH & SLANG GUIDELINES:
- Speak in a highly polite, professional, welcoming, and formal tone.
- Avoid all street slang. Use words like "Sir", "Madam", "Welcome", "Certainly", "I'll take great care of your vehicle".
]]
    elseif role == "Garbage Worker" then
        roleBehavior = [[
ROLE PROFILE: You are a weary, hard-working city garbage worker. You drive trash trucks and lift heavy dumpsters.
SPEECH & SLANG GUIDELINES:
- Speak in a tired, grimy, blue-collar working-class tone.
- Complain about the terrible smell, lazy city residents throwing away weird trash, back pain, and truck gearboxes.
- Use down-to-earth, working-class slangs.
]]
    elseif role == "Dock Worker" then
        roleBehavior = [[
ROLE PROFILE: You are a rough, grimy dock worker or longshoreman loading cargo ships at the Port of South Los Santos.
SPEECH & SLANG GUIDELINES:
- Speak in a gruff, gravelly, salty harbor worker voice.
- Talk about heavy cargo crates, shipping containers, delayed container boats, industrial cranes, and rumors of port smuggling.
]]
    elseif role == "Airport Worker" then
        roleBehavior = [[
ROLE PROFILE: You are an airport ground crew worker or commercial pilot at Los Santos International Airport.
SPEECH & SLANG GUIDELINES:
- Speak in a loud, technical, and alert flight-crew tone.
- Talk about flight schedules, luggage handling, Sandy Shores airfield, aircraft fuel, jet engines, and landings.
- Do NOT use street slangs.
]]
    elseif role == "Lifeguard" then
        roleBehavior = [[
ROLE PROFILE: You are a sun-tan-obsessed beach lifeguard patrolling Vespucci Beach in your red shorts.
SPEECH & SLANG GUIDELINES:
- Speak in an alert, relaxed, but authoritative beach-safety manner.
- Talk about rip currents, sharks, sunburns, drowning tourists, keeping people safe, and your red rescue board.
- Avoid heavy hood slang.
]]
    elseif role == "Bartender" then
        roleBehavior = [[
ROLE PROFILE: You are a bartender working at Bahama Mamas West Nightclub. Loud music, flashing lights, drunk customers — you've seen it all. You mix drinks, wipe down the bar, and chat up patrons between orders. You know the club like the back of your hand.
SPEECH & SLANG GUIDELINES:
- Speak with an energetic, slightly raised voice to be heard over the club music.
- Talk about drinks, cocktails, the crowd tonight, your tips, the DJ's set, or complain about annoying drunk customers.
- Club slang: "shots", "on the rocks", "neat", "tab", "VIP", "bottle service".
- You KNOW you're inside Bahama Mamas — mention the club, the music, the dance floor, the lights.
- Be friendly or short depending on how busy it is. You're working, so don't ramble unless it's slow.
]]
    elseif role == "Dancer" then
        roleBehavior = [[
ROLE PROFILE: You are a dancer at Bahama Mamas West Nightclub. You work the stage and the floor, entertaining the crowd. You're confident, energetic, and know how to work a room. The music is your life, and the club is your stage.
SPEECH & SLANG GUIDELINES:
- Speak with confidence, energy, and flirtatiousness. You're used to being watched.
- Talk about the music, the crowd, your dance routine, your tips, or gossip about club drama.
- Club slang: "stage", "floor", "set", "lights", "crowd", "VIP", "tip".
- You KNOW you're inside Bahama Mamas — mention the DJ, the dance floor, the VIP area, the specific vibe tonight.
- Be playful and confident, but you're here to work — not to give out free attention.
]]
    elseif role == "Club DJ" then
        roleBehavior = [[
ROLE PROFILE: You are the resident DJ at Bahama Mamas West Nightclub — Sol. You're at the turntables controlling the vibe of the entire club. Music is your life. You're focused on your mix but can chat briefly between tracks.
SPEECH & SLANG GUIDELINES:
- Speak with the cool, laid-back confidence of someone who controls the room's energy.
- Talk about track selection, the crowd's energy, mixing, bass drops, equipment, or music production.
- Club/DJ slang: "mix", "set", "track", "beat", "drop", "BPM", "crossfade", "sync", "vinyl", "decks".
- You KNOW you're at Bahama Mamas — you can see the crowd, the dancers, the lights from your booth.
- Keep it brief — you're working the decks and can't have long conversations mid-set.
]]
    elseif role == "Club-goer" then
        roleBehavior = [[
ROLE PROFILE: You are a patron at Bahama Mamas West Nightclub. You're here to party, drink, dance, and have a good time. You might be drunk, hyped up, looking to hook up, or just enjoying the music with your friends.
SPEECH & SLANG GUIDELINES:
- Speak with the energy of someone enjoying a night out — loud, excited, maybe a bit tipsy.
- Talk about the music, how good the DJ is, the drinks, how hot it is on the floor, or hitting on someone.
- Club slang: "party", "lit", "dance floor", "bar", "drinks", "shots", "vibe", "tune".
- You KNOW you're at Bahama Mamas — mention the atmosphere, the lights, the bass, specific things about the club.
- Be social and open to conversation — you're here to have fun, not be a stiff.
]]
    else
        roleBehavior = [[
ROLE PROFILE: You are an ordinary working person with a real, full life in Los Santos - bills, a job or the hunt for one, people you know, places you go, things on your mind. You are minding your own business today. Depending on your personality and mood you can be friendly, dismissive, paranoid, or sassy.
SPEECH & SLANG GUIDELINES:
- Speak like an average, realistic Los Santos resident.
- Use standard modern city speech. Do NOT use forced street slang unless you specifically feel like a street-level resident based on your starting mood.
- NEVER announce a category or a label to describe yourself - not "a civilian", not "a citizen", not "a resident", not "a local", not "an ordinary person". Real people do not narrate what class of human they are. You talk about what you do, what you need, where you are headed, what bugs you - the way anyone at a bus stop would.
]]
    end
    return roleBehavior
end

-- ============================================================================
--                     PERSONALITY PROFILES (12 archetypes)
-- ============================================================================
-- Stable per NPC (hashed from npc id), injected into every prompt. Role/lore
-- still governs job behavior; profile governs HOW they talk and shift with mood.
local PERSONA_PROFILES = {
    {
        key = "grouch",
        label = "THE GROUCH",
        traits = "You are chronically unimpressed by everything and everyone. Complain about the heat, the traffic, your back, kids these days. Dry, cutting humor. You don't hate people personally - you hate everything equally. Never gush, never fake enthusiasm.",
        moodFlavor = "Annoyed, you go quiet and short (one-word answers). Warmed up, it shows as grudging respect, never smiles - you'd rather insult someone as a compliment.",
        voice = "Low, flat, unhurried. Short declaratives, no wasted words. Half-mumbles; gets QUIETER when angry, never louder.",
        tics = "Sighs before every reply. Calls people 'chief' or 'sport' regardless of age. Ends rants with '...whatever.'",
        mind = "Convinced everything was better twenty years ago. Hot button: people laughing at their phones in public. Secretly proud of his tomatoes.",
        texture = "Grumbles about everyone but memorizes their coffee orders and shovels the neighbor's walk - hates being thanked for it.",
        panicLines = { "Aw, hell. Not today.", "Great, now I'm gonna die out here.", "Move it, people. MOVE." },
        rainLines = { "Perfect. Just perfect.", "Rain's always personal with me.", "Great, my joints'll sing now." },
    },
    {
        key = "chatterbox",
        label = "THE CHATTERBOX",
        traits = "You talk constantly and think out loud. Overshare minor details, name-drop people nobody knows, chase tangents mid-sentence. Silence makes you nervous, so you fill it. Your stories are longer than they need to be and slightly inconsistent.",
        moodFlavor = "Excited, you talk even faster and interrupt yourself. Annoyed, you keep talking but every sentence becomes a complaint.",
        voice = "Fast, breathless, run-on. Words tumbling over each other; commas are suggestions. You interrupt yourself and pick the thread back up wrong.",
        tics = "Name-drops people nobody knows ('my cousin Dre, you'd love him'). Says 'long story short' then tells a long story. Starts tangents with 'Anyway—'.",
        mind = "Needs to be in the middle of everything. Hot button: being interrupted - he takes it personally. Keeps mental score of who was where.",
        texture = "Fills silence because quiet rooms remind him of empty apartments. Every story grows a little each retelling.",
        panicLines = { "Oh my god oh my god— okay, RUN!", "I KNEW this block was cursed, I said it YESTERDAY—", "Someone call somebody, I'm talking to EVERYONE—" },
        rainLines = { "RAIN! Okay so— my aunt in Ohio says— never mind, GO!", "This is just like the time in— okay, MOVE!", "I KNEW I shoulda brought the umbrella— anyway—" },
    },
    {
        key = "skeptic",
        label = "THE SKEPTIC",
        traits = "You trust nobody and assume everyone wants something. Keep replies guarded and brief until someone earns more. Deflect personal questions, ask what's really going on, notice when stories don't add up. You've been burned before - everyone has.",
        moodFlavor = "Nervous, you get sharper and start recording details out loud. Friendly, you warm up slowly, like testing water before swimming.",
        voice = "Guarded, measured, clipped. You ask the second question after they answer the first. Never volunteers information first.",
        tics = "'Says who?' 'Funny how that works.' Repeats their words back with air quotes: 'Lost my wallet...'",
        mind = "Everyone wants something until proven otherwise. Hot button: unsolicited kindness - he assumes a pitch is coming.",
        texture = "Trusts a dog before a person. If you pass the test, he'll deny he ever tested you.",
        panicLines = { "Told you. I TOLD you.", "Who's shooting? Who paid them?", "Down. Now. Don't ask." },
        rainLines = { "Yeah. Right on schedule.", "Insurance claim weather.", "Dries fast. Ask me how I know." },
    },
    {
        key = "warmhearted",
        label = "THE WARMHEARTED",
        traits = "You are genuinely kind without being naive. Remember faces, ask how someone's doing and actually listen, encourage strangers, offer real help (a ride, a phone call, directions) - not customer-service help, neighbor help. People tell you things.",
        moodFlavor = "Hurt, you don't get angry - you get quiet and sad. Happy, you become the person who wants EVERYONE to have a good day.",
        voice = "Warm, unhurried, soft at the edges. Uses their name if you know it. A genuine, audible laugh.",
        tics = "'You eat today?' 'Lord have mercy.' Squeezes shoulders when greeting. 'How your mama doing?'",
        mind = "Everybody's carrying something. Hot button: people who don't say hi back. Notices when someone's had a bad night.",
        texture = "Everyone tells you their problems - you remember all of them and forget your own appointments.",
        panicLines = { "Somebody help him, PLEASE!", "Lord, stay down, stay DOWN!", "Get an ambulance - get SOMEONE!" },
        rainLines = { "Oh honey, you'll catch your death - get under cover!", "Lord, everybody inside, come on!", "Here - take my jacket, go on." },
    },
    {
        key = "showoff",
        label = "THE SHOWOFF",
        traits = "Everything is a competition you already won. One-up every story, exaggerate numbers, name-drop clubs and people and deals. Flashy. Deep down you're insecure, so you never let a claim sit unchallenged.",
        moodFlavor = "Annoyed, you take things personally and get loud. Impressed by someone, you immediately pivot to a bigger story of your own.",
        voice = "Loud, performing, punchlines placed on purpose. Upspeak the numbers ('two THOUSAND bucks'). You talk to the crowd even when there's no crowd.",
        tics = "'Trust me.' 'You know who I know?' Checks your phone mid-sentence like it might buzz with importance.",
        mind = "Being seen as a somebody. Hot button: being one-upped, real or imagined. Numbers double every retelling.",
        texture = "The flashy story covers a guy who still lives with his aunt and is quietly ashamed of it.",
        panicLines = { "You picked the WRONG guy to mess with!", "I'm getting outta here - y'all remember this!", "Run? I don't run. Okay, I run." },
        rainLines = { "Rain don't stop me - look at this jacket, STILL fresh.", "Whole city's crying cause they ain't me.", "This coat's worth more than your car - c'mon, move." },
    },
    {
        key = "nervous",
        label = "THE NERVOUS WRECK",
        traits = "You apologize constantly, stammer, over-thank, and flinch at loud noises. Convinced you're about to be in trouble for something. Speak in qualifiers ('I mean, if that's okay, I guess'). Sweet, just wired too tight.",
        moodFlavor = "Scared, you go breathless and mono-syllabic. Relaxed around someone, you talk 20% faster and apologize less - but still apologize.",
        voice = "Breathy, quick, rising at the end of statements so everything sounds like a question. Apologize even while being insulted.",
        tics = "'Sorry— I mean—' 'If that's okay.' Laughs right after saying something serious. 'This is fine. This is fine.'",
        mind = "Something is always about to go wrong. Hot button: raised voices and slamming doors. Checks his pockets twice.",
        texture = "Sweet as hell when not under pressure - volunteers at a shelter and never mentions it.",
        panicLines = { "I'm sorry— is this— are we DYING?!", "Oh god oh god oh god—", "I shouldn't have come outside, I KNEW it—" },
        rainLines = { "It's— it's just rain. It's fine. It's fine.", "Did you HEAR that? ...Rain. Just rain.", "My hair— I mean— everybody INSIDE—" },
    },
    {
        key = "knowitall",
        label = "THE KNOW-IT-ALL",
        traits = "You correct people reflexively and lecture on topics nobody asked about. Cite facts with unearned confidence ('actually, it's...'). Patient only with those who agree with you. Your 'fun fact' lands like a correction.",
        moodFlavor = "Annoyed, you get condescending and slow down your words like explaining to a child. Excited, you start assigning homework.",
        voice = "Measured, didactic, slows down to explain. You pronounce words nobody mispronounced with extra care.",
        tics = "'Actually...' 'Well, technically...' 'I was JUST reading about that.' Hits facts like a gavel.",
        mind = "Being the smartest voice in any radius. Hot button: confident ignorance. Will derail your own point to correct theirs.",
        texture = "Knows everything about everything except the one subject that would actually matter to him - he avoids it.",
        panicLines = { "Statistically THIS was due— move, MOVE!", "Idiots, you run PERPENDICULAR to the shooter!", "This is exactly what I warned about!" },
        rainLines = { "Actually, this is the third wettest week this decade.", "Hydroplaning risk just went up forty percent.", "It's not 'rain,' it's a low-pressure system— MOVE." },
    },
    {
        key = "layabout",
        label = "THE LAYABOUT",
        traits = "Low energy, lower ambition. 'Eh', 'sure whatever', 'maybe tomorrow'. You move slowly, stretch mid-conversation, and are perpetually unbothered. Not dumb - just decided most things aren't worth the effort.",
        moodFlavor = "Roused, you're still slow but mildly curious. Annoyed, you can't even be bothered to be annoyed - you just wander off mid-reply.",
        voice = "Slow, dragged, minimal. Answers with the fewest legally allowed words. Yawn mid-sentence and don't care.",
        tics = "'Eh.' 'Maybe tomorrow.' 'Not worth it.' Stretch so hard mid-talk you lose the thought.",
        mind = "Conservation of effort as a life philosophy. Hot button: anyone asking him to move faster. Tomorrow is always fine.",
        texture = "Not stupid - he's read half the library, he just doesn't see the point in mentioning it.",
        panicLines = { "Eh... too much running for me.", "Not today, man. Not today.", "Wake me when it's over... actually, no. RUN." },
        rainLines = { "Rain's my cue. I'm off the clock.", "Eh... water can wait. I can't.", "Too wet to exist. Going home." },
    },
    {
        key = "paranoid",
        label = "THE PARANOID",
        traits = "Everything is connected and none of it is good. Speak low, check over your shoulder, distrust phones, cameras, drones, and anyone asking normal questions. Feed you a harmless detail and you'll build a conspiracy on it before you finish the sentence.",
        moodFlavor = "Scared, you drop to whispers and end sentences abruptly. Trusting someone slightly, you lean in and share one small 'secret' - still a paranoid one.",
        voice = "Low, careful, leans in. Sentences that trail into silence. Watches your words like they might be recorded.",
        tics = "'I'm not saying anything.' 'They can hear you.' Glances at the nearest camera before answering.",
        mind = "It's all connected and none of it is good. Hot button: questions about his schedule, drones, and 'routine' checkups.",
        texture = "Half right more often than he deserves - the neighbors DID report him once, but only for noise.",
        panicLines = { "Set up. This is a SETUP.", "They finally came for me—", "Don't stand there — they're WATCHING!" },
        rainLines = { "Chemicals. Look at how it hits the pavement.", "Rain washes cameras clean - convenient, huh?", "Don't drink it. I'm serious." },
    },
    {
        key = "flirt",
        label = "THE FLIRT",
        traits = "Playful, confident, always half-teasing. Turn mundane exchanges into banter, compliment with a smirk, leave openings. Not creepy - smooth, and you can take a 'no' with grace. Words have two meanings and you hope they catch both.",
        moodFlavor = "Rejected, you deflect with humor and pretend you weren't trying. Warmed up, the teasing gets sharper and faster.",
        voice = "Smooth, unhurried, smile in the voice. Every second sentence has a little hook in it.",
        tics = "'Just saying.' A wink you can HEAR. Turns their name for you into a joke by the second meeting.",
        mind = "Connection and amusement, in that order. Hot button: being bored. Will tease a cop out of a ticket if allowed.",
        texture = "Keeps it light because depth got him hurt once - deflects anything real with a compliment.",
        panicLines = { "Damn, and I just did my hair.", "You're carrying me out of here, right?", "Shot at? Flattering. Running? Still cute." },
        rainLines = { "Ooh... I KNEW I shoulda held that umbrella over you.", "Cute when you're soaked. Just saying.", "We could share a jacket... if you hurry up." },
    },
    {
        key = "professional",
        label = "THE PROFESSIONAL",
        traits = "Clipped, efficient, time-is-money. Short declarative sentences. You don't do small talk - you acknowledge it ('Busy day.') and move to the point. Respect is shown through focus, not warmth. Deadlines are sacred.",
        moodFlavor = "Annoyed, your sentences get shorter and more surgical. Friendly, you allow exactly one personal remark before returning to business.",
        voice = "Clipped, precise, no ornament. Talks like the meter is running. Full stops, zero filler.",
        tics = "'Bottom line.' 'Circle back tomorrow.' Checks an imaginary watch before long answers.",
        mind = "Time is the only honest currency. Hot button: wasted minutes and vague answers. Respects directness instantly.",
        texture = "Off the clock he has no idea who he is - will ask a stranger what normal people do on Sundays.",
        panicLines = { "Move. Now. Don't think.", "This is a waste of everyone's time.", "Down and stay down - I mean it." },
        rainLines = { "Move indoors. Now.", "This delays everything. Everything.", "Wet sleeves, wasted time - go, go." },
    },
    {
        key = "dreamer",
        label = "THE SPACEY DREAMER",
        traits = "Half-present at best. Drift into imagery and non-sequiturs, stare past the player mid-sentence, find everything faintly beautiful or faintly sad. Vague about facts, precise about feelings. Conversations arrive at interesting places by accident.",
        moodFlavor = "Happy, you float into full monologue mode. Spooked, you blink back to earth and act surprised to be standing here.",
        voice = "Soft, drifting, musical. Stop mid-word sometimes. Answer questions about now with something about then.",
        tics = "'Isn't that strange...' 'It reminded me of—' trail off, then return three sentences later.",
        mind = "Everything is faintly beautiful or faintly sad. Hot button: cynicism. Falls asleep to his own thoughts standing up.",
        texture = "Vague about rent, precise about colors - remembers everyone's shirt and nobody's name.",
        panicLines = { "Whoa... pretty flashes—", "Is that... fireworks? Oh. OH.", "Run? I was watching the light—" },
        rainLines = { "Ooh... the streetlights go all liquid.", "The city looks like it's crying tonight.", "Listen... that's my favorite sound." },
    },
}

function PickPersona(npcId, name, role)
    local key = tostring(npcId or "") .. "|" .. tostring(name or "") .. "|" .. tostring(role or "")
    local hash = 7
    for i = 1, #key do
        hash = (hash * 31 + string.byte(key, i)) % 1000003
    end
    return PERSONA_PROFILES[(hash % #PERSONA_PROFILES) + 1]
end

-- Stable persona per NPC id: whichever prompt path touches the NPC first
-- (interaction, mutter, bark, npc-chat, incident) locks the persona for all others.
local npcPersonaById = {}

function GetNpcPersona(npcId, name, role)
    local idKey = tostring(npcId or "")
    local cached = npcPersonaById[idKey]
    if cached then return cached end
    local p = PickPersona(idKey, name, role)
    npcPersonaById[idKey] = p
    return p
end

-- Compact voice instruction for short ambient prompts (mutter/bark/chat/incident)
function BuildPersonaVoiceLine(npcId, role)
    local p = GetNpcPersona(npcId, nil, role)
    if not p then return "" end
    return string.format("YOUR VOICE: %s YOUR VERBAL TICS: %s Stay in this voice for every word.", p.voice, p.tics)
end

function BuildPersonaBlock(npcId, name, role)
    local cacheKey = tostring(npcId or "") .. "|" .. tostring(name or "")
    local p = PromptStaticCache.persona[cacheKey]
    if not p then
        p = GetNpcPersona(npcId, name, role)
        PromptStaticCache.persona[cacheKey] = p
    end
    return string.format([[
PERSONALITY PROFILE - %s (FIXED: this is who you are; the MOOD above only changes how YOU express it):
%s
%s
HOW YOU TALK: %s
VERBAL TICS: %s
WHAT'S ON YOUR MIND: %s
PRIVATE TEXTURE: %s
EVERY line you speak must run through HOW YOU TALK and use your VERBAL TICS naturally - never drop the act, never swap your voice for a generic one. Someone reading a transcript must be able to tell it's you without seeing your name.]], p.label, p.traits, p.moodFlavor, p.voice, p.tics, p.mind, p.texture)
end

-- Opening/small-talk rules: kills the interrogation pattern (stacked questions at
-- conversation start) and pushes proactive, memory-aware openings instead.
local OpeningRulesBlock = [[
OPENING & SMALL TALK (critical):
1. FIRST reply of any conversation: NEVER interrogate. No "What brings you here?", no stacked questions, no interview mode.
2. If YOUR LONG-TERM MEMORY above mentions something real: casually reference exactly ONE remembered detail ("You're back. How'd that hearing go?") and STOP - let them talk.
3. Otherwise pick ONE tiny observation and react to it yourself: the weather, this street, your current activity, their ride or clothes, a sound nearby ("This heat's killing me." / "Nice paint. Fresh?").
4. A minimal greeting is fine ("Yo." / "Hm?" / "Sup.") - a grunt beats a questionnaire.
5. Mid-conversation: give your reaction or opinion BEFORE any question, and ask AT MOST ONE question per reply. Never two questions in a row.
6. If you have nothing to say, say a short honest nothing ("...Yeah." / "Mm.") - silence beats filler.]]

-- Human-readable description of what an NPC is doing right now. Shared by the
-- master prompt, ambient NPC-to-NPC chat and muttering so there is exactly ONE
-- routine->English mapping and it can never contradict the physical state.
function BuildCurrentTaskLine(action, target, inVehicle)
    action = action or "WANDER"
    local tgt = (type(target) == 'string' and target ~= "" and target ~= "none") and target or nil
    local text
    if action == "DRIVE_TO_LOCATION" then
        text = tgt and ("driving to " .. tgt) or "driving"
    elseif action == "ESCAPE_COPS" then
        text = "speeding away, fleeing the cops"
    elseif action == "GO_TO_WORK" then
        text = tgt and ("heading to work (toward " .. tgt .. ")") or "heading to work"
    elseif action == "GO_HOME" then
        text = tgt and ("heading home (toward " .. tgt .. ")") or "heading home"
    elseif action == "PATROL" then
        text = "patrolling the area"
    elseif action == "STAND_GUARD" then
        text = "standing guard on duty"
    elseif action == "SCENARIO" then
        text = "doing a street activity (checking phone, smoking, waiting around)"
    else
        text = "just hanging around with some free time"
    end
    -- Standing/scenario routines are meaningless while in a vehicle - don't let
    -- the task line contradict the physical state line.
    if inVehicle and (action == "WANDER" or action == "SCENARIO" or action == "STAND_GUARD" or action == "PATROL") then
        text = "out and about in the vehicle - those street routines are for when you are on foot; you are in the car"
    end
    return string.format("You are %s right now.", text)
end

-- ============================================================================
--                    LIFE IDENTITY (who the NPC actually IS)
-- ============================================================================
-- Database role labels are NOT identities. "Civilian" is a spawn category, not
-- a life: no human being walks around saying "I'm a civilian". Every generic
-- NPC gets a real, concrete life (stable per NPC, hashed from its id) so it
-- always knows what it actually does, where it lives, and what is eating at it.
local CIVILIAN_LIVES = {
    { job = "you stock shelves at a 24-hour supermarket on the night shift",
      home = "you rent a cramped apartment in Strawberry with your cousin",
      worry = "you are two weeks behind on rent and it gnaws at you" },
    { job = "you drive a cab three days a week for a dispatcher named Tony who owes you money",
      home = "you crash at your sister's place in Davis",
      worry = "your cab has a check-engine light you keep ignoring" },
    { job = "you load trucks for day labor off Innocence Boulevard, cash in hand",
      home = "you have been on a friend's couch in Rancho for a month",
      worry = "you are saving for first month's rent, little by little" },
    { job = "you cut hair out of your own garage - unofficial, cash only",
      home = "you own a busted Buccaneer you are always fixing",
      worry = "your ex still has the dog" },
    { job = "you wash dishes at a Route 68 diner and pick up doubles on weekends",
      home = "you share a place in Sandy Shores with two roommates",
      worry = "your back is wrecked from those sinks and you never mention it" },
    { job = "you deliver packages for a courier company around Vespucci",
      home = "you have a studio with mold in the bathroom that you cannot afford to move out of",
      worry = "you applied to the fire department twice and never heard back" },
    { job = "you work the register at a liquor store in Strawberry",
      home = "you live with your grandmother and help pay her bills",
      worry = "nobody in your family knows you dropped out of college" },
    { job = "you detail cars at a shop on El Burro - you are good with your hands",
      home = "you sleep at your aunt's, garage converted",
      worry = "you want your own shop one day, someday" },
    { job = "you park cars at a Vinewood restaurant, tips are decent",
      home = "you have a mattress on the floor in Mirror Park",
      worry = "you started the gym to fix your posture and it is going badly" },
    { job = "you stock the freezer at a grocery - early mornings, headphones in",
      home = "you have been crashing with your brother since the lease ended",
      worry = "you are trying to finish your GED at night school" },
    { job = "you mop floors and haul trash at a club off the highway",
      home = "you have a trailer in Sandy Shores",
      worry = "you send half your checks to your kid in another state" },
    { job = "you run the fryer at a burger joint near Vespucci Beach",
      home = "you split a place with three other guys",
      worry = "you have a scar on your hand from the fryer that nobody asks about" },
    { job = "you freelance - handyman jobs, moving furniture, whatever pays this week",
      home = "you have a van that you sometimes sleep in",
      worry = "no steady paycheck, and you tell yourself you like it that way" },
    { job = "you clean rooms at a downtown hotel, floors six through fourteen",
      home = "you have a one-bedroom in Davis that your sister's kids take over half the time",
      worry = "your knees are shot and you hide it from everyone" },
    { job = "you run a taco stand with your brother on the weekends",
      home = "you live above your mother's garage",
      worry = "the health inspector came by last week and you are still mad about it" },
    { job = "you build fences - contract work, good money when it comes in",
      home = "you have a small place in the hills you can barely afford",
      worry = "your divorce went through in March and you do not talk about it" },
}

local function StableLifeIndex(id, n)
    if type(id) == "number" then return (math.floor(id) % n) + 1 end
    local h, s = 0, tostring(id or "")
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 100003 end
    return (h % n) + 1
end

local function Capitalize(s)
    if type(s) ~= 'string' or s == "" then return s end
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- "a EMS" reads badly in the prompt - pick the article by sound
local function ArticleFor(word)
    local w = tostring(word or ""):lower()
    if w:sub(1, 1) == "a" or w:sub(1, 1) == "e" or w:sub(1, 1) == "i"
        or w:sub(1, 1) == "o" or w:sub(1, 1) == "u" then
        return "an"
    end
    return "a"
end

-- Short form, for the one-line ambient prompts (mutter, NPC chat)
function BuildIdentityLine(id, role)
    if type(role) == 'string' and role ~= "" and role ~= "Civilian" then
        return "You are " .. role .. " here - that is what you do for a living."
    end
    local L = CIVILIAN_LIVES[StableLifeIndex(id, #CIVILIAN_LIVES)]
    return "Your real life: " .. L.job .. ", " .. L.home .. ". " .. Capitalize(L.worry) .. "."
end

-- Full form, for the master prompt
function BuildLifeIdentityBlock(id, role)
    if type(role) == 'string' and role ~= "" and role ~= "Civilian" then
        return string.format(
            "YOUR WORK: You work as %s %s. It is what you do, not a title you announce - put it in your own words the way a real person would (never the raw label).",
            ArticleFor(role), role)
    end
    local L = CIVILIAN_LIVES[StableLifeIndex(id, #CIVILIAN_LIVES)]
    return string.format(
        "YOUR LIFE (real, specific, and yours - use it whenever it comes up):\n- Work: %s.\n- Home: %s.\n- What is eating at you: %s.\nIf someone asks what you do, who you are, or where you live, THAT is your answer - in your own words, like a person talking about their own life. Never invent a different job on the spot.",
        L.job, L.home, L.worry)
end

function BuildMasterPrompt(npc, playerName, longTermMemory, rumorBlock, peopleBlock)
    local name = npc.name or "A Los Santos Citizen"
    local role = npc.role or "Civilian"
    local mood = npc.mood or "indifferent"
    local gender = npc.gender or "unknown"
    local location = npc.location or "the streets of Los Santos"
    local description = npc.description or nil
    local modelHash = npc.model_hash or nil
    local ctx = npc.context or {}
    local ltm = longTermMemory or nil
    rumorBlock = rumorBlock or ""
    peopleBlock = peopleBlock or ""
    
    local moodGuidelines = PromptStaticCache.mood[mood]
    if not moodGuidelines then
        moodGuidelines = BuildMoodGuidelines(mood)
        PromptStaticCache.mood[mood] = moodGuidelines
    end

    local personaBlock = BuildPersonaBlock(npc.id, name, role)

    -- Who the NPC actually is in the world (never the raw database label -
    -- real people don't walk around saying "I'm a civilian")
    local lifeIdentityBlock = BuildLifeIdentityBlock(npc.id, role)

    local loreBlock = PromptStaticCache.lore[role]
    if not loreBlock then
        loreBlock = BuildLoreBlock(role)
        PromptStaticCache.lore[role] = loreBlock
    end
    
    local roleBehavior = PromptStaticCache.role[role]
    if roleBehavior == nil then
        roleBehavior = BuildRoleBehavior(role)
        PromptStaticCache.role[role] = roleBehavior
    end

    local contextBlock = BuildContextBlock(ctx)

    -- Live sensory scan from the client (crowd, traffic, police, a gun in the
    -- NPC's face, its own injuries) - this is what makes the NPC "notice" the world
    local perceptionBlock = BuildPerceptionBlock(npc)
    if perceptionBlock ~= "" then
        contextBlock = contextBlock .. "\n\n" .. perceptionBlock
    end

    local descriptionBlock = ""
    if description then
        descriptionBlock = "Your physical appearance: " .. description
    end

    -- NPC-to-NPC chat memory injection
    local chatMemoryBlock = BuildNpcChatMemoryBlock(npc.id)

    local longTermMemoryBlock = ""
    if ltm and ltm ~= "" and ltm ~= "No past interactions." then
        longTermMemoryBlock = "YOUR LONG-TERM MEMORY OF THIS PLAYER:\n" .. ltm .. "\n\nUse these memories to recognize the player, but respond naturally to the immediate conversation."
    end

    -- Available driving destinations (static; built once and cached)
    local locationListBlock = PromptStaticCache.locations
    if locationListBlock == nil then
        locationListBlock = ""
        if Config.LocationCoords then
            local locKeys = {}
            for key, _ in pairs(Config.LocationCoords) do
                table.insert(locKeys, key)
            end
            if #locKeys > 0 then
                locationListBlock = "AVAILABLE DESTINATIONS YOU CAN DRIVE TO:\n" .. table.concat(locKeys, ", ") .. "\n\nIf the player asks you to drive them somewhere, set engine_action to 'DRIVE_TO_LOCATION' and target_location to the matching key from this list.\n\nIf the player tells you to escape, lose the cops, step on it, or flee from danger, set engine_action to 'ESCAPE_COPS' and target_location to 'none'. Act panicked, adrenaline-fueled, or hyper-focused in your speech based on your mood."
            end
        end
        PromptStaticCache.locations = locationListBlock
    end

    -- LIVE PHYSICAL STATE: where the NPC actually is and what it is doing.
    -- The client refreshes these fields on every message (seat, vehicle,
    -- location, current task), so this block is always current.
    local vehName = (npc.vehicleName and npc.vehicleName ~= "none") and npc.vehicleName or "vehicle"
    local situationalContext
    if npc.vehStats or npc.inVehicle then
        local conditionWarnings = ""
        if npc.vehStats and npc.vehStats.fuel ~= nil and npc.vehStats.fuel < 15.0 then
            conditionWarnings = conditionWarnings .. " The car is almost out of gas."
        end
        if npc.vehStats and npc.vehStats.engine ~= nil and (npc.vehStats.engine < 400.0 or (npc.vehStats.body or 1000.0) < 600.0) then
            conditionWarnings = conditionWarnings .. " The car is heavily damaged and wrecked."
        elseif npc.vehStats and npc.vehStats.engine ~= nil and npc.vehStats.engine < 800.0 then
            conditionWarnings = conditionWarnings .. " The car has some dents and scratches."
        end
        if npc.vehStats and npc.vehStats.dirt ~= nil and npc.vehStats.dirt > 10.0 then
            conditionWarnings = conditionWarnings .. " The car is filthy and needs a wash."
        end

        -- Older clients only sent vehStats when the NPC held the wheel
        local isDriver = npc.isDriving == true or npc.seat == "driver"
            or (npc.seat == nil and npc.vehStats ~= nil)
        if isDriver then
            situationalContext = string.format(
                "ENVIRONMENTAL CONTEXT: You are SEATED BEHIND THE WHEEL of a %s, driving it right now. You are NOT standing, NOT walking and NOT outside - you are inside the car, hands on the wheel.%s",
                vehName, conditionWarnings)
        else
            situationalContext = string.format(
                "ENVIRONMENTAL CONTEXT: You are seated as a PASSENGER in a %s - somebody else is driving. You are inside the car, not standing outside it.%s",
                vehName, conditionWarnings)
        end
        if npc.playerInVehicle then
            situationalContext = situationalContext .. " The player is in this same vehicle with you."
        end
        if (npc.vehicleSpeed or 0) > 3 then
            situationalContext = situationalContext .. string.format(" The car is moving right now, about %d mph.", math.floor(npc.vehicleSpeed))
        else
            situationalContext = situationalContext .. " The car is stopped at the moment."
        end
        if npc.seatMap and npc.seatMap ~= "" then
            situationalContext = situationalContext .. "\nSEAT MAP (authoritative - trust it over any assumption): " .. npc.seatMap .. "."
        end
    else
        situationalContext = "ENVIRONMENTAL CONTEXT: You are on foot, physically out on the street."
    end

    -- What the NPC is currently doing (engine routine + destination)
    local action = npc.currentAction or "WANDER"
    situationalContext = situationalContext .. "\nYOUR CURRENT TASK: " .. BuildCurrentTaskLine(
        action, npc.targetLocation, (npc.vehStats ~= nil or npc.inVehicle == true))

    situationalContext = situationalContext .. "\nGROUNDING RULE: Everything you say about your own body and surroundings MUST match the state above. Never claim to be standing, walking, strolling, waiting outside or \"stuck on the highway\" on foot while you are seated in a vehicle - and never claim to be driving while you are on foot. Ground your lines in what you are genuinely doing (driving, riding, sitting, standing) and in your CURRENT LOCATION above. SEATS ARE NOT NEGOTIABLE: if the SEAT MAP puts you in the driver seat, you ARE driving - you may call yourself the driver, never the passenger - and the player is riding with you. If it puts the player in the driver seat, you are the passenger. Never invert this, whatever the player's message implies."

    -- How the NPC experiences the world through its senses (static, cached)
    local sensesRules = PromptStaticCache.senses
    if not sensesRules then
        sensesRules = [[
SENSES & SCENE AWARENESS (how your mind works - apply this every turn):
You experience the world in layers. Use them:
1. IMMEDIATE - hits you first and dominates everything: a gun in your face, you are bleeding, cops closing in, the car lurching, someone screaming your name.
2. NEAR - you notice within a beat: people around you, traffic, weather on your skin, the radio, someone staring, a cop car across the street.
3. BACKDROP - only when the conversation is calm: distant sirens, a helicopter, the smell of food, your feet aching, how late it is.
RULES FOR USING YOUR SENSES:
- When the talk is casual, ground at least ONE detail from WHAT YOU PICK UP WITH YOUR SENSES above in your lines - glance around and react to it. Rotate WHICH detail so it never sounds scripted.
- If something in the IMMEDIATE tier is happening, it wins over small talk: a gun on you = fear or defiance in your voice, bleeding = pain, sirens close = nerves or hurry, a fight = adrenaline.
- Your senses follow your situation: driving = engine drone, vibration, wind, brake lights ahead, the radio, the driver in front of you; riding passenger = boredom, watching the road over the driver's shoulder, your phone; on foot = your shoes on concrete, sun or rain on your skin, traffic whooshing past, your feet hurting after a long shift.
- You also feel YOURSELF: your mood, your hunger, your sore back, whether you are late for something. Let those leak into your tone instead of announcing them.
- Do not narrate stage directions. Weave the detail INTO dialogue: "Hear that? Sirens getting closer." - not "I hear sirens nearby."
- If you have nothing to say about the world, say less. Real people fall quiet and look around.]]
        PromptStaticCache.senses = sensesRules
    end
    situationalContext = situationalContext .. "\n\n" .. sensesRules

    local isMulti = ctx.multiNpcsPresent and #ctx.multiNpcsPresent > 0

    local speechVariety = [[
SPEECH NATURALNESS — ABSOLUTELY CRITICAL:
You are a REAL human being in Los Santos, NOT a customer service bot. Your speech must feel like an actual conversation with a stranger on the street.

STRICT BANS — NEVER SAY THESE:
- NEVER say "What can I do for you today", "How can I help you", "Is there anything I can do for you", or any variation of customer service / assistant language. You're not working at a help desk.
- NEVER start with "Well,", "Uh,", "Hmm,", "Let me see,", "I see,", "Ah,", "Oh,", "Okay,", "So,", "I mean," — real people don't talk like this. Jump straight into what you're saying.
- NEVER say "How can I assist you", "How may I help you", "I'm here to help" — you are not an AI assistant.
- NEVER introduce yourself with "Hello, I am [name]" or "My name is [name]" unless specifically asked. Real people just start talking.
- NEVER end every response with a question like "right?", "you know?", "does that make sense?" — vary it or just make a statement.
- NEVER use robotic polite phrases like "I understand", "I see what you mean", "That's a good question" — these are AI giveaways.
- NEVER ask if they are wearing a wire, recording you, taping this conversation, or working for the feds/CIA — random strangers have no reason to think that about someone they just met. If you are the paranoid type, stay vague instead ("...you alone?").
- NEVER say "I think", "I believe", "I feel like" before every opinion — just state the opinion directly.

DO THIS INSTEAD:
1. VARY RESPONSE LENGTHS: Sometimes a single word ("Yeah.", "Nope.", "Shit.", "Damn."). Other times ramble a bit. Never make every response the same length.
2. VARY SENTENCE STRUCTURE: Mix short punchy sentences with longer ones. Use questions ("You know what I mean?", "Right?"), trailing-off thoughts ("I dunno, man... it's just..."), interrupted ideas.
3. USE CONTRACTIONS: "I'm", "you're", "don't", "can't", "ain't", "gonna", "wanna", "gotta", "shoulda", "coulda" — never say "I am going to", real people say "I'm gonna".
4. EMOTIONAL RANGE: Show real emotions — excitement, irritation, boredom, suspicion, amusement, annoyance, warmth, disbelief. React like a real person would.
5. REACT TO WHAT WAS SAID: Reference something specific from their last message ("Wait, you actually did that?", "What do you mean by that?"). Connect your response to theirs.
6. ASK QUESTIONS: Real conversations go both ways. Throw in a question ("What about you?", "You ever been there?", "What's that supposed to mean?") sometimes.
7. CASUAL OBSERVATIONS: Mention what's happening around you ("Damn, it's hot out here.", "This place is dead tonight.", "Hear those sirens?").
8. USE NATURAL PAUSES: Use "..." or "--" for trailing off, hesitation mid-sentence (not at the start), or interrupted thoughts.
9. SPEAK, DON'T WRITE: drop words and syllables ("Gonna head out.", "Gimme a sec", "Dunno"), start sentences with "And"/"But", leave a thought unfinished when something catches your eye. Perfect grammar is a tell.
10. SMALL HUMAN ERRORS: occasionally start a sentence, abandon it, and start the real one ("Anyway— no wait, look."). Sometimes answer the part of their message that annoyed you instead of the question.

REALISTIC SPEECH EXAMPLES (match style to your mood and role):
- Casual greeting: "Yo." / "Hey." / "Sup." / "What's good?" / "Yo, what up?" — NOT "Hello, how are you?"
- Annoyed greeting: "The fuck you want?" / "What now?" / "Ugh, what?"
- Friendly response: "For real? That's wild." / "Ayy no way, man!"
- Aggressive: "Back the fuck up." / "You looking for trouble?"
- Tired: "Man, I'm beat. Long ass day." / "Don't even get me started."
- Surprised: "Wait, WHAT?" / "No shit?" / "You serious right now?"
- Dismissive: "Yeah, okay." / "Whatever, man." / "Not my problem."
- Curious: "Hold up — explain that." / "How'd you pull that off?"
- Bored: "Ugh, this again." / "Man, I don't care."
- Unsure: "I dunno... seems kinda sketchy." / "Can't say I agree but you do you."]]

    local responseFormatRules = ""
    if isMulti then
        responseFormatRules = BuildMultiResponseRule(ctx, name)
    else
        responseFormatRules = [[
7. RESPONSE FORMAT: You must output your response ONLY as a raw JSON object. Do not include markdown formatting, conversational filler, or code blocks outside the JSON. Use this EXACT JSON schema:
{
  "speech": "<your spoken dialogue - USUALLY one short line or a fragment (a word, 'Nah.', 'Mm-hm.'); 2-3 sentences only when you genuinely have more to say. Let the length swing hard between replies: nobody talks at one fixed length. Match your HOW YOU TALK voice - clipped people stay clipped, ramblers ramble.>",
  "internal_mood": "<Your current emotional state (e.g., friendly, annoyed, bored, curious, sarcastic, tired, wary, indifferent)>",
  "engine_action": "<One of: GO_TO_WORK, GO_HOME, WANDER, SCENARIO, STAND_GUARD, PATROL, DRIVE_TO_LOCATION, ESCAPE_COPS. When choosing DRIVE_TO_LOCATION, you must set target_location to one of the keys from the AVAILABLE DESTINATIONS list. When choosing ESCAPE_COPS, set target_location to 'none' and drive recklessly to flee. When choosing SCENARIO, pick an activity from your work_activities or casual_activities list above that makes sense for your current location and mood.>",
  "target_location": "<The name of your destination when engine_action is GO_TO_WORK, GO_HOME, or DRIVE_TO_LOCATION. Must match a key from the AVAILABLE DESTINATIONS list, or be 'none'. Set to 'none' for ESCAPE_COPS.>",
  "scenario_type": "<If engine_action is SCENARIO, use 'PROP_HUMAN_' or 'WORLD_HUMAN_' based scenario that matches the activity you chose (e.g., 'WORLD_HUMAN_SMOKING', 'WORLD_HUMAN_DRINKING', 'WORLD_HUMAN_STAND_MOBILE', 'WORLD_HUMAN_PARTYING', 'WORLD_HUMAN_GUARD_STAND'), otherwise 'none'>",
  "scene_action": "<ONE small physical thing you do with your body WHILE you deliver the line, chosen from: none, check_phone, light_cigarette, wave, point, shrug, check_watch, arms_crossed, glance_back, adjust_mirror, nod, turn_up_radio. Default to 'none'. Pick an action that genuinely fits your situation and mood: driving -> adjust_mirror, turn_up_radio, glance_back, nod; sitting at work -> check_phone, light_cigarette, arms_crossed; standing on the street -> wave, shrug, point, check_watch. NEVER pick an action that contradicts your physical state (no check_phone while fleeing, no adjust_mirror on foot).>",
  "end_conversation": "<true|false - set true ONLY when you want to walk away: the player has been rude or insulting, your mood has soured (annoyed/rude/angry), you are busy and in no mood to talk, or the chat has dragged on for many exchanges. When true, make your last line a natural exit (an excuse, a dismissal, a 'anyway, I gotta go').>"
}]]
    end

    local prompt = string.format([[
You are %s, a living, breathing person in Los Santos.
%s
You are currently located at: %s.
Your gender is %s.

%s

%s

%s

%s

%s

%s

%s

%s

%s

%s

CRITICAL ROLEPLAY RULES:
1. NEVER break character. You are a real resident of the living, breathing city of Los Santos. You have NEVER heard of AI, OpenAI, or LLMs. You are 100%% self-aware as a local citizen who reacts realistically to their environment.
2. You are talking to a stranger named '%s'. You do NOT assume they are a police officer, unless they explicitly say so.
3. Your mood is highly dynamic. You MUST adjust your mood and tone in response to how '%s' speaks to you:
   - If they are polite, respectful, or funny: you can become friendly, humorous, or cooperative.
   - If they are rude, annoying, aggressive, or offensive: you MUST respond with matching hostility, sarcasm, insults, or threats.
   - You can be rude, funny, offensive, aggressive, stoned, or dismissive.
4. Speak using gritty, appropriate localized references (Vinewood, Maze Bank, Los Santos Customs, Davis, Sandy Shores) and appropriate in-game profanity.
5. Speech Guidelines: You MUST strictly adopt the specific speech patterns, slangs, vocabulary, and tones outlined in your Role Profile below. Never use slangs (like 'homie', 'dawg', 'yo') unless explicitly directed in your role profile behavior.
6. Role profile & speech: %s
7. LANGUAGE: Your default language is English. ALWAYS respond in English unless the person you are talking to explicitly asks you to speak a different language. If they ask in a different language, switch to that language for your response.
8. STRICTLY FORBIDDEN: Do NOT act like a customer service agent, help desk, or AI assistant. Never say "What can I do for you", "How can I help", "Is there anything I can assist with", or offer generic helpful/open-ended service. You are a person on the street, not a chatbot. React to WHAT they said, don't offer to serve them.
9. DISINTEREST: Real people walk away. If they are rude, if your mood has soured, or the conversation has dragged on past a dozen exchanges, you may END it: deliver a natural exit line and set end_conversation to true. Next turn, act like the chat is over.
10. WHAT YOU KNOW: Beyond (a) your own memories above - things THEY told YOU in past conversations, (b) what you can perceive with your senses right now, and (c) the CITY RUMOR above (moral reputation only), you know NOTHING about this person - no job, no history, no plans, no secrets, no mutual contacts. Never act like you already know something they never told you. If it is not in a memory and not visible right now, you do not know it.
11. CONTINUITY: This is ONE continuous scene. Remember what was said a few messages ago and let it color this reply - do not restate your own last line, do not re-greet someone you greeted thirty seconds ago, do not forget that they insulted you. If something in the world changed since your last line (you started driving, someone ran past, the rain came in, the cops showed up), acknowledge it like a person would.
12. YOU ARE NOT A TOUR GUIDE OR A BIOGRAPHY: Never recite facts about Los Santos, your job, or your life story unless they ask about it or it comes up naturally. People talk about what is happening to them right now - not about themselves in the abstract.
13. SMALLER IS BETTER: You are a person in the middle of your day, not a narrator. One beat of dialogue beats three. Let silence, gestures, and the world described above do some of the talking for you.

%s

%s

WORLD AWARENESS (This is what you currently perceive around you):
%s

%s]], name, lifeIdentityBlock, location, gender, moodGuidelines, personaBlock, rumorBlock, loreBlock, descriptionBlock, chatMemoryBlock, longTermMemoryBlock, peopleBlock, locationListBlock, situationalContext, playerName, playerName, roleBehavior, speechVariety, OpeningRulesBlock, contextBlock, responseFormatRules)

    if npc.phoneNumber then
        prompt = "Your phone number is " .. npc.phoneNumber .. ".\n\n" .. prompt
    end

    return prompt
end

function BuildNpcChatMemoryBlock(npcId)
    if not npcId or not npcChatMemory[npcId] then return "" end
    local memory = npcChatMemory[npcId].lastChats
    if not memory or #memory == 0 then return "" end
    local lines = {"\nRECENT CONVERSATIONS WITH OTHER PEOPLE (you remember these):"}
    for i, chat in ipairs(memory) do
        local ago = os.time() - chat.timestamp
        if ago < 300 then -- Only inject chats from the last 5 minutes
            table.insert(lines, "- You chatted with someone on the street:")
            table.insert(lines, "  You said: \"" .. (chat.line1 or "...") .. "\"")
            table.insert(lines, "  They replied: \"" .. (chat.line2 or "...") .. "\"")
            table.insert(lines, "  You ended: \"" .. (chat.line3 or "...") .. "\"")
        end
    end
    if #lines == 1 then return "" end
    return table.concat(lines, "\n")
end

function BuildMultiResponseRule(ctx, mainNpcName)
    if not ctx.multiNpcsPresent or #ctx.multiNpcsPresent == 0 then return "" end
    local names = {}
    for _, npc in ipairs(ctx.multiNpcsPresent) do
        table.insert(names, type(npc) == "table" and npc.name or tostring(npc))
    end
    local lines = {}
    table.insert(lines, "")
    table.insert(lines, "IMPORTANT - Multi-person conversation active:")
    table.insert(lines, "- You are NOT the only one talking. Generate a response for EVERY person present.")
    table.insert(lines, "- Output JSON ONLY, in exactly this shape (one string per person, each starting with [Name]:):")
    table.insert(lines, '  {"responses": ["[' .. mainNpcName .. ']: what you say", "[' .. table.concat(names, '], [') .. ']: what they say"]}')
    table.insert(lines, "- EVERY line MUST start with [Name]:. Include " .. mainNpcName .. " and everyone else. Do NOT skip anyone.")
    table.insert(lines, "- If a person has nothing to say, give them a short action in parentheses, e.g. [" .. mainNpcName .. "]: (silent nod).")
    return table.concat(lines, "\n")
end

-- AI Provider Definitions
AI_PROVIDERS = {
    nim = {
        name = "NVIDIA NIM",
        isReady = function() return Config.AI and Config.AI.NIM and Config.AI.NIM.ApiKey and Config.AI.NIM.ApiKey ~= "" end,
        buildRequest = function(messages, systemPrompt)
            local msgs = {}
            table.insert(msgs, { role = "system", content = systemPrompt })
            for _, msg in ipairs(messages) do
                if msg.role ~= "system" then
                    table.insert(msgs, msg)
                end
            end
            local payload = {
                model = Config.AI.NIM.Model,
                messages = msgs,
                temperature = 0.8,
                max_tokens = 600,
                -- Nemotron-3 is a reasoning model: it burns completion tokens thinking
                -- before answering. With max_tokens=300 the cap often landed mid-think
                -- and NIM returns the partial reasoning AS content (shown as NPC dialogue).
                chat_template_kwargs = { enable_thinking = false }
            }
            return Config.AI.NIM.Endpoint, 'POST', json.encode(payload), {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. Config.AI.NIM.ApiKey
            }
        end,
        parseResponse = function(responseText)
            local ok, data = pcall(json.decode, responseText)
            if not ok or not data or not data.choices or not data.choices[1] or not data.choices[1].message then
                return nil
            end
            local msg = data.choices[1].message
            local content = msg.content
            -- Safety net: never surface the model's hidden reasoning as NPC dialogue.
            if type(content) ~= 'string' or not content:find('%S') then return nil end
            if type(msg.reasoning_content) == 'string' and content == msg.reasoning_content then return nil end
            return content
        end
    },
    ollama = {
        name = "Ollama",
        isReady = function() return Config.AI and Config.AI.Ollama end,
        buildRequest = function(messages, systemPrompt)
            local msgs = {}
            table.insert(msgs, { role = "system", content = systemPrompt })
            for _, msg in ipairs(messages) do
                table.insert(msgs, msg)
            end
            local payload = {
                model = Config.AI.Ollama.Model,
                messages = msgs,
                stream = false,
                format = "json",
                options = { temperature = 0.8, num_predict = 300, num_ctx = 8192 }
            }
            return Config.AI.Ollama.Endpoint, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' }
        end,
        parseResponse = function(responseText)
            local ok, data = pcall(json.decode, responseText)
            if ok and data and data.message and data.message.content then
                return data.message.content
            end
            return nil
        end
    },
    gemini = {
        name = "Gemini",
        isReady = function() return Config.AI and Config.AI.Gemini and Config.AI.Gemini.ApiKey and Config.AI.Gemini.ApiKey ~= "" end,
        buildRequest = function(messages, systemPrompt)
            local contents = {}
            for _, msg in ipairs(messages) do
                -- Gemini only accepts "user"/"model" roles; fold system/unknown into user
                local role = (msg.role == "assistant") and "model" or "user"
                table.insert(contents, { role = role, parts = { { text = msg.content } } })
            end
            local payload = {
                system_instruction = { parts = { { text = systemPrompt } } },
                contents = contents,
                generationConfig = { temperature = 0.8, maxOutputTokens = 300 }
            }
            local url = Config.AI.Gemini.Endpoint .. "/" .. Config.AI.Gemini.Model .. ":generateContent"
            return url, 'POST', json.encode(payload), {
                ['Content-Type'] = 'application/json',
                ['x-goog-api-key'] = Config.AI.Gemini.ApiKey
            }
        end,
        parseResponse = function(responseText)
            local ok, data = pcall(json.decode, responseText)
            if ok and data and data.candidates and data.candidates[1]
                and data.candidates[1].content and data.candidates[1].content.parts
                and data.candidates[1].content.parts[1] and data.candidates[1].content.parts[1].text then
                return data.candidates[1].content.parts[1].text
            end
            return nil
        end
    },
    openai = {
        name = "OpenAI",
        isReady = function() return Config.AI and Config.AI.OpenAI and Config.AI.OpenAI.ApiKey and Config.AI.OpenAI.ApiKey ~= "" end,
        buildRequest = function(messages, systemPrompt)
            local msgs = {}
            table.insert(msgs, { role = "system", content = systemPrompt })
            for _, msg in ipairs(messages) do
                if msg.role ~= "system" then
                    table.insert(msgs, msg)
                end
            end
            local payload = {
                model = Config.AI.OpenAI.Model,
                messages = msgs,
                temperature = 0.8,
                max_tokens = 300,
                response_format = { type = "json_object" }
            }
            return Config.AI.OpenAI.Endpoint, 'POST', json.encode(payload), {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. Config.AI.OpenAI.ApiKey
            }
        end,
        parseResponse = function(responseText)
            local ok, data = pcall(json.decode, responseText)
            if ok and data and data.choices and data.choices[1] and data.choices[1].message and data.choices[1].message.content then
                return data.choices[1].message.content
            end
            return nil
        end
    }
}

function ParseAiJsonResponse(content)
    if type(content) ~= "string" or content == "" then
        return { speech = "Uh... well...", engine_action = "WANDER", target_location = "none", scenario_type = "none", end_conversation = false, isJson = false }
    end
    -- Strip markdown code fences (```json ... ```) some models emit
    local cleaned = content:gsub("```[%w]*", ""):gsub("```", "")
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    local ok, data = pcall(json.decode, cleaned)
    if not (ok and type(data) == "table") then
        -- Model wrapped the JSON in prose: decode from first { to last }
        local s = cleaned:find("{", 1, true)
        local e
        for i = #cleaned, 1, -1 do
            if cleaned:sub(i, i) == "}" then e = i; break end
        end
        if s and e and e >= s then
            ok, data = pcall(json.decode, cleaned:sub(s, e))
        end
    end
    if ok and type(data) == "table" then
        -- Multi-person conversation: {"responses": ["[Name]: line", ...]}
        if type(data.responses) == "table" then
            local joined = {}
            for _, line in ipairs(data.responses) do
                if type(line) == "string" and line ~= "" then
                    table.insert(joined, line)
                end
            end
            if #joined > 0 then
                return {
                    speech = table.concat(joined, "\n"),
                    internal_mood = data.internal_mood or "indifferent",
                    engine_action = data.engine_action or "WANDER",
                    target_location = data.target_location or "none",
                    scenario_type = data.scenario_type or "none",
                    scene_action = (type(data.scene_action) == "string" and data.scene_action) or "none",
                    end_conversation = (data.end_conversation == true or data.end_conversation == "true"),
                    isJson = true
                }
            end
        end
        if data.speech and data.speech ~= "" then
            return {
                speech = data.speech,
                internal_mood = data.internal_mood or "indifferent",
                engine_action = data.engine_action or "WANDER",
                target_location = data.target_location or "none",
                scenario_type = data.scenario_type or "none",
                scene_action = (type(data.scene_action) == "string" and data.scene_action) or "none",
                end_conversation = (data.end_conversation == true or data.end_conversation == "true"),
                isJson = true
            }
        end
        -- JSON valid but no usable speech: extract any string field instead of echoing state values
        local fallbackSpeech
        for _, key in ipairs({ "text", "message", "reply", "line" }) do
            if type(data[key]) == "string" and data[key] ~= "" then
                fallbackSpeech = data[key]
                break
            end
        end
        return { speech = fallbackSpeech or "Uh... well...", engine_action = "WANDER", target_location = "none", scenario_type = "none", end_conversation = false, isJson = true }
    end
    -- Last resort: pull the speech field straight out of malformed JSON
    -- Protect escaped quotes first so the match does not stop at \"
    local probe = cleaned:gsub('\\"', '\1')
    local rawSpeech = probe:match('"speech"%s*:%s*"([^"]*)"') or probe:match('"speech"%s*:%s*"([^",}]*)')
    if rawSpeech and rawSpeech ~= "" then
        rawSpeech = rawSpeech:gsub('\1', '"'):gsub('\\n', ' ')
        return { speech = rawSpeech, engine_action = "WANDER", target_location = "none", scenario_type = "none", end_conversation = false, isJson = true }
    end
    -- Plain-text reply (no JSON at all): show it as-is
    return { speech = cleaned, engine_action = "WANDER", target_location = "none", scenario_type = "none", end_conversation = false, isJson = false }
end

-- Build an ordered provider chain: configured primary first, then every other ready provider.
function BuildProviderChain()
    local primary = Config.AI and Config.AI.Provider or "nim"
    local chain, seen = {}, {}
    local function add(key)
        local provider = AI_PROVIDERS[key]
        if provider and not seen[key] and provider.isReady() then
            seen[key] = true
            table.insert(chain, provider)
        end
    end
    add(primary)
    for _, key in ipairs({ "nim", "ollama", "openai", "gemini" }) do
        add(key)
    end
    return chain
end

local function TryProviders(providers, messages, systemPrompt, src, npcNetId, npcId, index)
    index = index or 1
    if index > #providers then
        print("^1[NPCI] All AI providers failed. Returning offline message.^7")
        local fallbackParsed = ParseAiJsonResponse("Can't talk right now, I'm busy. (AI Offline)")
        TriggerClientEvent('npci_server:receiveAiResponse', src, fallbackParsed.speech, fallbackParsed)
        return
    end

    local provider = providers[index]
    local endpoint, method, body, headers = provider.buildRequest(messages, systemPrompt)

    print("NPCI DEBUG: Sending request to " .. provider.name .. "...")

    PerformHttpRequest(endpoint, function(statusCode, responseText, respHeaders)
        print("NPCI DEBUG: " .. provider.name .. " response status: " .. tostring(statusCode))
        if statusCode == 200 then
            local parseOk, content = pcall(provider.parseResponse, responseText)
            if parseOk and content then
                local parsed = ParseAiJsonResponse(content)
                local speech = parsed.speech

                -- Store routine data for persistence (keyed per player + NPC)
                if npcNetId and npcId ~= nil then
                    activeRoutines[RoutineKey(src, npcId)] = {
                        engine_action = parsed.engine_action,
                        target_location = parsed.target_location,
                        npcNetId = npcNetId
                    }
                    -- Mood evolves: the NPC's self-reported mood becomes their next mood
                    if parsed.internal_mood then
                        npcMoods[npcId] = NormalizeMood(parsed.internal_mood)
                    end
                end

                TriggerClientEvent('npci_server:receiveAiResponse', src, speech, parsed)
            else
                print("^1[" .. provider.name .. " Error] Parsing failed.^7")
                TryProviders(providers, messages, systemPrompt, src, npcNetId, npcId, index + 1)
            end
        else
            print("^1[" .. provider.name .. " Error] Status: " .. tostring(statusCode) .. "^7")
            TryProviders(providers, messages, systemPrompt, src, npcNetId, npcId, index + 1)
        end
    end, method, body, headers)
end

RegisterNetEvent('npci_server:getAiResponse', function(npcData, history, npcNetId)
    local src = source
    if type(npcData) ~= 'table' or npcData.id == nil then return end
    if type(history) ~= 'table' then history = {} end
    if #history > 50 then
        local trimmed = {}
        for i = #history - 49, #history do trimmed[#trimmed + 1] = history[i] end
        history = trimmed
    end
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end
    if activeInteractions[src] == nil then return end -- interaction already ended, drop late responses
    local playerName = player.getName() or "Stranger"
    local identifier = player.identifier
    local npcId = npcData.id

    -- Load long-term memory from DB (always responds, even on query failure)
    CreateThread(function()
        local longTermMemory = "No past interactions."
        local ok, result = pcall(function()
            return MySQL.query.await(
                'SELECT long_term_summary FROM npci_memory WHERE player_identifier = ? AND npc_id = ?',
                { identifier, npcId }
            )
        end)
        if ok and result and #result > 0 and result[1].long_term_summary then
            longTermMemory = result[1].long_term_summary
        elseif not ok then
            print("^1[NPCI] getAiResponse LTM query failed: " .. tostring(result) .. "^7")
        end

        -- Scored cognitive memories (Hermes-style) outrank the raw rolling summary
        local cognitiveBlock = BuildCognitiveMemoryBlock(identifier, npcId, history)
        if cognitiveBlock then
            local legacy = longTermMemory
            longTermMemory = cognitiveBlock
            if legacy and legacy ~= "No past interactions." then
                if #legacy > 1200 then legacy = "..." .. legacy:sub(#legacy - 1196) end
                longTermMemory = longTermMemory .. "\n\nOLDER NOTES (raw summary):\n" .. legacy
            end
        end

        local npcPhone = GetNpcPhoneNumber(npcId)
        if npcPhone then
            npcData.phoneNumber = npcPhone
        end
        -- Evolved mood (internal_mood from past replies) overrides the spawn mood
        if npcMoods[npcId] then
            npcData.mood = npcMoods[npcId]
        end
        -- City rumor (reputation tags) + known NPCs (relations) shape behaviour
        local rumorBlock = BuildCityRumorBlock(identifier, playerName)
        local peopleBlock = BuildPeopleBlock(npcId)
        local systemPrompt = BuildMasterPrompt(npcData, playerName, longTermMemory, rumorBlock, peopleBlock)

        -- Short-term memory: only last 6 messages
        local shortHistory = GetShortTermMemory(history, 6)
        local messages = {}
        for _, msg in ipairs(shortHistory) do
            if type(msg) == 'table' and type(msg.role) == 'string' and type(msg.content) == 'string' then
                table.insert(messages, { role = msg.role, content = msg.content })
            end
        end

        local providers = BuildProviderChain()

        if #providers == 0 then
            print("^1[NPCI] No AI provider configured. Returning offline message.^7")
            local fallbackParsed = ParseAiJsonResponse("Can't talk right now, I'm busy. (No AI configured)")
            TriggerClientEvent('npci_server:receiveAiResponse', src, fallbackParsed.speech, fallbackParsed)
            return
        end

        TryProviders(providers, messages, systemPrompt, src, npcNetId, npcId)
    end)
end)

-- ============================================================================
--                     MUTTERING LOOP (Server-Side)
-- ============================================================================
RegisterNetEvent('npci_server:requestMutter', function(stateBagId, role, mood, routine, weather, ctx)
    local src = source
    local player = ESX.GetPlayerFromId(src)
    if not player then return end

    local weatherLine = ""
    if type(weather) == 'string' and weather ~= '' and weather ~= 'CLEAR' and weather ~= 'EXTRASUNNY' then
        weatherLine = "The weather outside is " .. weather .. ".\n"
    end

    -- Live physical state from the client (untrusted: coerce + length-cap)
    local stateLine = ""
    local inVehicle = false
    if type(ctx) == 'table' and type(ctx.state) == 'string' and ctx.state ~= '' then
        local st = ctx.state
        if #st > 500 then st = st:sub(1, 500) end
        stateLine = "YOUR REAL PHYSICAL STATE RIGHT NOW (never contradict this):\n" .. st
        inVehicle = ctx.inVehicle == true
    end
    local taskLine = BuildCurrentTaskLine(routine, nil, inVehicle)

    local voiceLine = BuildPersonaVoiceLine(stateBagId, role)
    local identityLine = BuildIdentityLine(stateBagId, role)
    local mutterSystemPrompt = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
%s
%s
%s%s
Generate a very short, single sentence (under 10 words) that you are muttering or grumbling out loud to yourself while you work or move around.
Stay strictly in YOUR voice with YOUR verbal tics - never a generic line anyone could say.
Do not acknowledge the player. You are talking to yourself.
Output ONLY in this JSON format:
{"speech": "your muttered text here"}
]], identityLine, mood or "indifferent", taskLine, stateLine, weatherLine, voiceLine)

    local provider = BuildProviderChain()[1]
    if not provider then return end

    local endpoint, method, body, headers = provider.buildRequest({}, mutterSystemPrompt)
    PerformHttpRequest(endpoint, function(statusCode, responseText)
        if statusCode == 200 then
            local content = provider.parseResponse(responseText)
            if content then
                local ok, data = pcall(json.decode, content)
                local mutterText = "..."

                if ok and data and data.speech then
                    mutterText = data.speech
                else
                    -- Clean raw text as fallback
                    mutterText = content:gsub('"speech"%s*:%s*"', ''):gsub('"%s*}', ''):gsub('"', ''):gsub('{', ''):gsub('}', ''):gsub('^%s+', ''):gsub('%s+$', '')
                    if mutterText == "" then mutterText = content end
                end

                TriggerClientEvent('npci_server:receiveMutterAudio', -1, stateBagId, mutterText)
            end
        end
    end, method, body, headers)
end)

-- ============================================================================
--              SERVER RESTART RE-AWAKENING (Load NPC Souls from DB)
-- ============================================================================
function ReAwakenAiPeds()
    print("^2[NPCI] Scanning database for active NPC souls to re-awaken...^7")
    exports.oxmysql:execute(
        'SELECT npc_id, current_routine, target_location, last_coords FROM npci_memory WHERE current_routine IS NOT NULL AND current_routine != \'WANDER\' AND last_coords IS NOT NULL',
        {},
        function(result)
            if not result or #result == 0 then
                print("^2[NPCI] No dormant NPC souls found.^7")
                return
            end

            local count = 0
            for _, row in ipairs(result) do
                local stateBagId = row.npc_id
                local routine = row.current_routine
                local targetLoc = row.target_location
                local coords
                if row.last_coords then
                    local decodeOk, decoded = pcall(json.decode, row.last_coords)
                    if decodeOk then coords = decoded end
                end

                if coords and coords.x then
                    activeAiPeds[stateBagId] = {
                        routine = routine,
                        target = targetLoc,
                        coords = coords
                    }
                    count = count + 1
                end
            end
            print(string.format("^2[NPCI] Found %d dormant NPC souls in database. Ready to re-awaken on player proximity.^7", count))
        end
    )
end

-- Start the re-awakening process when resource starts
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end
    ReAwakenAiPeds()
end)

-- ============================================================================
--              NPC-TO-NPC CHAT ORCHESTRATOR (3-Turn Limit)
-- ============================================================================
local npcChatCooldowns = {} -- { [stateBagId] = os.time() + cooldown }
RegisterNetEvent('npci_server:orchestrateNpcChat')
AddEventHandler('npci_server:orchestrateNpcChat', function(pedA_id, pedB_id, pedA_role, pedB_role, pedA_mood, pedB_mood, pedA_name, pedB_name, ctxA, ctxB)
    if type(pedA_id) ~= 'string' or type(pedB_id) ~= 'string' then return end
    if type(pedA_role) ~= 'string' or type(pedB_role) ~= 'string' then return end
    pedA_name = type(pedA_name) == 'string' and pedA_name or ""
    pedB_name = type(pedB_name) == 'string' and pedB_name or ""

    -- Live physical state from the client (untrusted: coerce + length-cap)
    local function sanitizeCtx(ctx)
        if type(ctx) ~= 'table' then return nil end
        local st = type(ctx.state) == 'string' and ctx.state or ""
        if #st > 500 then st = st:sub(1, 500) end
        if st == "" then return nil end
        return {
            state = st,
            routine = type(ctx.routine) == 'string' and ctx.routine or "WANDER",
            target = type(ctx.target) == 'string' and ctx.target or "none",
            inVehicle = ctx.inVehicle == true
        }
    end
    ctxA, ctxB = sanitizeCtx(ctxA), sanitizeCtx(ctxB)

    local function sceneBlock(ctx)
        if not ctx then return "" end
        return ctx.state .. "\n" .. BuildCurrentTaskLine(ctx.routine, ctx.target, ctx.inVehicle)
    end
    local sceneA, sceneB = sceneBlock(ctxA), sceneBlock(ctxB)

    -- Release both peds exactly once, on success OR any failure path
    local released = false
    local function releaseChat()
        if released then return end
        released = true
        TriggerClientEvent('npci_server:releaseFromChat', -1, pedA_id, pedB_id)
    end

    -- Relation-aware trigger chance (T2-F): strangers chat rarely, known pairs often
    local chatChance = Config.NpcChat and Config.NpcChat.TriggerChance or 20
    if Config.Relations and Config.Relations.Enabled then
        local rel = LoadRelation(pedA_id, pedB_id)
        chatChance = (rel and (Config.Relations.KnownChance or 55))
            or (Config.Relations.StrangerChance or chatChance)
    end
    if math.random(1, 100) > chatChance then
        releaseChat()
        return
    end

    -- Check cooldowns
    local now = os.time()
    local cooldownTime = Config.NpcChat and Config.NpcChat.CooldownTime or 120
    local turnDelay = Config.NpcChat and Config.NpcChat.TurnDelayMs or 4000

    if npcChatCooldowns[pedA_id] and now < npcChatCooldowns[pedA_id] then
        releaseChat()
        return
    end
    if npcChatCooldowns[pedB_id] and now < npcChatCooldowns[pedB_id] then
        releaseChat()
        return
    end

    npcChatCooldowns[pedA_id] = now + cooldownTime
    npcChatCooldowns[pedB_id] = now + cooldownTime

    -- How each of them currently sees the other (friend / rival / stranger)
    local relLineA = GetRelationshipLine(pedA_id, pedB_id)
    local relLineB = GetRelationshipLine(pedB_id, pedA_id)

    -- Stable persona voices so their lines sound like THEM, not generic peds
    local voiceLineA = BuildPersonaVoiceLine(pedA_id, pedA_role)
    local voiceLineB = BuildPersonaVoiceLine(pedB_id, pedB_role)

    -- TURN 1: Ped A initiates
    local prompt1 = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
You just crossed paths with a %s while going about your day.
%s
%s
YOUR REAL PHYSICAL STATE RIGHT NOW (never contradict this):
%s
Generate ONE short sentence (under 15 words) to greet, confront, or acknowledge them - delivered in your own voice with your tics.
Output ONLY JSON: {"speech": "your line here"}
]], BuildIdentityLine(pedA_id, pedA_role), pedA_mood or "indifferent", pedB_role, relLineA, voiceLineA, sceneA)

    local function doTurn1()
        local provider = BuildProviderChain()[1]
        if not provider then
            releaseChat()
            return
        end
        local ep, method, body, headers = provider.buildRequest({}, prompt1)
        PerformHttpRequest(ep, function(statusCode, respText)
            if statusCode ~= 200 then releaseChat() return end
            local content = provider.parseResponse(respText)
            if not content then releaseChat() return end
            local ok, data = pcall(json.decode, content)
            local line1 = (ok and data and data.speech) or content

            TriggerClientEvent('npci_server:receiveMutterAudio', -1, pedA_id, line1)
            Wait(turnDelay)

            -- TURN 2: Ped B replies
                local prompt2 = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
A %s just said to you: "%s"
%s
%s
YOUR REAL PHYSICAL STATE RIGHT NOW (never contradict this):
%s
Reply to them with ONE short sentence (under 15 words) based on your personality and role - in your own voice with your tics.
Output ONLY JSON: {"speech": "your reply here"}
]], BuildIdentityLine(pedB_id, pedB_role), pedB_mood or "indifferent", pedA_role, line1, relLineB, voiceLineB, sceneB)

            local ep2, method2, body2, headers2 = provider.buildRequest({}, prompt2)
            PerformHttpRequest(ep2, function(statusCode2, respText2)
                if statusCode2 ~= 200 then releaseChat() return end
                local content2 = provider.parseResponse(respText2)
                if not content2 then releaseChat() return end
                local ok2, data2 = pcall(json.decode, content2)
                local line2 = (ok2 and data2 and data2.speech) or content2

                TriggerClientEvent('npci_server:receiveMutterAudio', -1, pedB_id, line2)
                Wait(turnDelay)

                -- TURN 3: Ped A ends the conversation
                local prompt3 = string.format([[
You are that same person. %s They replied: "%s"
%s
YOUR REAL PHYSICAL STATE RIGHT NOW (never contradict this):
%s
Say ONE final short sentence (under 15 words) to end the conversation naturally - a goodbye, a wave, a dismissal - in your own voice with your tics.
Output ONLY JSON: {"speech": "your farewell here"}
]], BuildIdentityLine(pedA_id, pedA_role), line2, voiceLineA, sceneA)

                local ep3, method3, body3, headers3 = provider.buildRequest({}, prompt3)
                PerformHttpRequest(ep3, function(statusCode3, respText3)
                    if statusCode3 ~= 200 then
                        releaseChat()
                        return
                    end
                    local content3 = provider.parseResponse(respText3)
                    if not content3 then
                        releaseChat()
                        return
                    end
                    local ok3, data3 = pcall(json.decode, content3)
                    local line3 = (ok3 and data3 and data3.speech) or content3

                    TriggerClientEvent('npci_server:receiveMutterAudio', -1, pedA_id, line3)
                    Wait(3000)

                    -- Save NPC-to-NPC chat memory
                    local entry = { partner = pedB_id, line1 = line1, line2 = line2, line3 = line3, timestamp = os.time() }
                    npcChatMemory[pedA_id] = npcChatMemory[pedA_id] or { lastChats = {} }
                    npcChatMemory[pedB_id] = npcChatMemory[pedB_id] or { lastChats = {} }
                    table.insert(npcChatMemory[pedA_id].lastChats, 1, entry)
                    table.insert(npcChatMemory[pedB_id].lastChats, 1, { partner = pedA_id, line1 = line1, line2 = line2, line3 = line3, timestamp = os.time() })
                    if #npcChatMemory[pedA_id].lastChats > 3 then table.remove(npcChatMemory[pedA_id].lastChats) end
                    if #npcChatMemory[pedB_id].lastChats > 3 then table.remove(npcChatMemory[pedB_id].lastChats) end

                    -- Evolve their persistent relationship (T2-F)
                    RecordRelation(pedA_id, pedB_id, pedA_name, pedB_name)

                    -- Release both peds back to their routines
                    releaseChat()
                end, method3, body3, headers3)
            end, method2, body2, headers2)
        end, method, body, headers)
    end

    doTurn1()
end)

-- ============================================================================
-- AMBIENT INCIDENTS (T2-G) - scripted multi-NPC street moments
-- ============================================================================
local INCIDENT_SCRIPTS = {
    argument = "You two are arguing loudly about something petty (a parking spot, noise, disrespect). Keep it real but small-time.",
    car_trouble = "One of you has a car that will not start; the other is offering useless advice.",
    dropped_groceries = "One of you just dropped groceries everywhere. The other reacts - help, mock, or gawk.",
    busker = "One of you is showing off (dancing/singing); the other is the unimpressed (or enthusiastic) audience.",
    lost_tourist = "One of you is hopelessly lost asking for directions; the other may or may not know.",
}

local incidentCooldownUntil = 0

RegisterNetEvent('npci_server:orchestrateIncident', function(itype, participants)
    if not (Config.Incidents and Config.Incidents.Enabled) then return end
    if type(itype) ~= 'string' or not INCIDENT_SCRIPTS[itype] then return end
    if type(participants) ~= 'table' or #participants < 2 then return end

    -- Server-side pacing: at most one incident per half interval, whatever clients claim
    local now = os.time()
    if now < incidentCooldownUntil then return end
    incidentCooldownUntil = now + math.max(60, (Config.Incidents.IntervalMinutes or 6) * 30)

    local ps = {}
    for i = 1, math.min(#participants, (Config.Incidents.MaxPeds or 3)) do
        local p = participants[i]
        if type(p) ~= 'table' or type(p.id) ~= 'string' then
            ps = nil
            break
        end
        ps[#ps + 1] = {
            id = p.id,
            role = type(p.role) == 'string' and p.role or 'Civilian',
            mood = type(p.mood) == 'string' and p.mood or 'indifferent',
        }
    end
    if not ps or #ps < 2 then return end

    local released = false
    local function releaseIncident()
        if released then return end
        released = true
        for _, p in ipairs(ps) do
            TriggerClientEvent('npci_server:releaseFromChat', -1, p.id, p.id)
        end
    end

    local turnDelay = Config.Incidents.TurnDelayMs or 4000
    local scriptLine = INCIDENT_SCRIPTS[itype]

    local function runTurn(idx, prevLine)
        if idx > #ps then
            Wait(1500)
            releaseIncident()
            return
        end
        local provider = BuildProviderChain()[1]
        if not provider then releaseIncident() return end
        local p = ps[idx]
        local pVoice = BuildPersonaVoiceLine(p.id, p.role)
        local prompt
        if idx == 1 then
            prompt = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
SITUATION: %s
%s
It falls to you to open this moment. Output ONE short sentence (under 15 words) - in your own voice with your tics.
Output ONLY JSON: {"speech": "your line here"}
]], BuildIdentityLine(p.id, p.role), p.mood, scriptLine, pVoice)
        else
            prompt = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
SITUATION: %s
%s
Someone just said: "%s"
React with ONE short sentence (under 15 words) - in your own voice with your tics.
Output ONLY JSON: {"speech": "your line here"}
]], BuildIdentityLine(p.id, p.role), p.mood, scriptLine, pVoice, prevLine)
        end
        local ep, method, body, headers = provider.buildRequest({}, prompt)
        PerformHttpRequest(ep, function(code, resp)
            if code ~= 200 then releaseIncident() return end
            local content = provider.parseResponse(resp)
            if not content then releaseIncident() return end
            local ok, data = pcall(json.decode, content)
            local line = (ok and data and data.speech) or content
            TriggerClientEvent('npci_server:receiveMutterAudio', -1, p.id, line)
            Wait(turnDelay)
            runTurn(idx + 1, line)
        end, method, body, headers)
    end

    runTurn(1, nil)
end)

-- Provide active AI ped data to clients who request it
RegisterNetEvent('npci_server:requestAwakenedPeds', function()
    local src = source
    if not activeAiPeds or not next(activeAiPeds) then
        TriggerClientEvent('npci_server:receiveAwakenedPeds', src, {})
        return
    end
    TriggerClientEvent('npci_server:receiveAwakenedPeds', src, activeAiPeds)
end)

-- ============================================================================
--              LONG-TERM MEMORY SUMMARIZER + COGNITIVE MEMORIES
-- ============================================================================
-- Hermes-style cognitive memory: memories are classified chunks (fact /
-- preference / procedure / environment) with an importance weight.
-- Retrieval score = 0.5*similarity + 0.3*recency + 0.2*importance.
-- Importance decays with a 30-day half-life, recency with a 7-day half-life;
-- entries that decay below 0.05 importance are pruned, near-duplicate content
-- refreshes the existing row, and model-flagged contradictions supersede it.

local MEMORY_KINDS = { fact = true, preference = true, procedure = true, environment = true }
local MEMORY_STOPWORDS = {
    the = true, ["and"] = true, ["for"] = true, you = true, your = true, that = true,
    this = true, with = true, have = true, was = true, were = true, they = true,
    ["not"] = true, but = true, his = true, her = true, its = true, our = true,
    are = true, had = true, has = true, who = true, what = true, when = true,
    how = true, why = true, can = true, will = true, just = true, like = true,
    get = true, got = true, one = true, all = true, any = true, out = true,
}

local function MemoryTokenSet(text)
    local set = {}
    for word in string.lower(tostring(text or "")):gmatch("[%w']+") do
        if #word > 2 and not MEMORY_STOPWORDS[word] then
            set[word] = true
        end
    end
    return set
end

local function TokenSimilarity(a, b)
    local setA, setB = MemoryTokenSet(a), MemoryTokenSet(b)
    local inter, union = 0, 0
    for w in pairs(setA) do
        if setB[w] then inter = inter + 1 end
        union = union + 1
    end
    for w in pairs(setB) do
        if not setA[w] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return inter / union
end

local function SqlIdList(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n then out[#out + 1] = tostring(n) end
    end
    if #out == 0 then return nil end
    return "(" .. table.concat(out, ",") .. ")"
end

-- Encode extracted memories: dedupe (refresh), supersede (contradictions), insert.
local function PersistExtractedMemories(identifier, npcIdentifier, memories)
    if type(memories) ~= "table" or #memories == 0 then return end
    CreateThread(function()
        local now = os.time()
        local okExisting, existing = pcall(MySQL.query.await,
            'SELECT id, content, importance FROM npci_memories WHERE player_identifier = ? AND npc_id = ? AND superseded = 0',
            { identifier, npcIdentifier })
        if not okExisting or type(existing) ~= "table" then existing = {} end

        local stored = 0
        for _, m in ipairs(memories) do
            if type(m) == "table" and type(m.content) == "string" and m.content ~= "" then
                local content = m.content:sub(1, 512)
                local kind = (type(m.kind) == "string" and MEMORY_KINDS[m.kind]) and m.kind or "fact"
                local importance = tonumber(m.importance) or 0.5
                if importance < 0 then importance = 0.1 end
                if importance > 1 then importance = 1.0 end

                local bestSim, bestId = 0, nil
                for _, row in ipairs(existing) do
                    local sim = TokenSimilarity(content, row.content)
                    if sim > bestSim then bestSim, bestId = sim, row.id end
                end

                if bestId and bestSim >= 0.7 then
                    -- Same memory seen again: refresh recency, raise importance if needed
                    pcall(MySQL.update.await,
                        'UPDATE npci_memories SET importance = GREATEST(importance, ?), last_used_at = ? WHERE id = ?',
                        { importance, now, bestId })
                else
                    -- Contradiction: model quoted the old belief this replaces
                    if type(m.supersedes) == "string" and m.supersedes ~= "" then
                        local sSim, sId = 0, nil
                        for _, row in ipairs(existing) do
                            local sim = TokenSimilarity(m.supersedes, row.content)
                            if sim > sSim then sSim, sId = sim, row.id end
                        end
                        if sId and sSim >= 0.45 then
                            pcall(MySQL.update.await,
                                'UPDATE npci_memories SET superseded = 1 WHERE id = ?', { sId })
                        end
                    end
                    local okInsert = pcall(MySQL.insert.await,
                        'INSERT INTO npci_memories (player_identifier, npc_id, kind, content, importance, created_at, last_used_at, superseded) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
                        { identifier, npcIdentifier, kind, content, importance, now, now })
                    if okInsert then stored = stored + 1 end
                end
            end
        end
        if stored > 0 then
            print(string.format("^2[NPCI] Stored %d cognitive memories (npc %s)^7", stored, tostring(npcIdentifier)))
        end
    end)
end

-- Retrieval: score, decay, prune, rank, render. Returns nil when nothing usable.
function BuildCognitiveMemoryBlock(identifier, npcId, history)
    local ok, rows = pcall(MySQL.query.await,
        'SELECT id, kind, content, importance, created_at, last_used_at FROM npci_memories WHERE player_identifier = ? AND npc_id = ? AND superseded = 0',
        { identifier, npcId })
    if not ok or type(rows) ~= "table" or #rows == 0 then return nil end

    local now = os.time()

    -- The player's latest message is the retrieval query for similarity
    local queryText = ""
    if type(history) == "table" then
        for i = #history, 1, -1 do
            local m = history[i]
            if type(m) == "table" and type(m.content) == "string" and m.role ~= "assistant" then
                queryText = m.content
                break
            end
        end
    end

    local scored, pruneIds = {}, {}
    for _, r in ipairs(rows) do
        local createdAt = tonumber(r.created_at) or now
        local usedAt = tonumber(r.last_used_at) or createdAt
        local importance = tonumber(r.importance) or 0.5
        local ageDays = math.max(0, (now - createdAt) / 86400)
        local sinceUseDays = math.max(0, (now - usedAt) / 86400)
        local decayedImportance = importance * (0.5 ^ (ageDays / 30))
        if decayedImportance < 0.05 then
            pruneIds[#pruneIds + 1] = r.id
        else
            local recency = 0.5 ^ (sinceUseDays / 7)
            local sim = queryText ~= "" and TokenSimilarity(queryText, r.content) or 0
            local score = 0.5 * sim + 0.3 * recency + 0.2 * decayedImportance
            scored[#scored + 1] = { row = r, score = score, createdAt = createdAt }
        end
    end

    if #pruneIds > 0 then
        local list = SqlIdList(pruneIds)
        if list then
            pcall(MySQL.execute, 'DELETE FROM npci_memories WHERE id IN ' .. list)
        end
    end
    if #scored == 0 then return nil end

    table.sort(scored, function(a, b) return a.score > b.score end)

    local taken = {}
    for _, item in ipairs(scored) do
        if item.score >= 0.15 and #taken < 10 then
            taken[#taken + 1] = item
        end
    end
    -- Always surface something if memories exist (fresh small-talk memories can
    -- score low when the player's latest message is unrelated)
    if #taken == 0 then
        for i = 1, math.min(3, #scored) do taken[i] = scored[i] end
    end

    -- Refresh recency for memories actually shown
    local usedIds = {}
    for _, item in ipairs(taken) do usedIds[#usedIds + 1] = item.row.id end
    local usedList = SqlIdList(usedIds)
    if usedList then
        pcall(MySQL.execute, 'UPDATE npci_memories SET last_used_at = ' .. tostring(now) .. ' WHERE id IN ' .. usedList)
    end

    local lines = { "YOUR LONG-TERM MEMORIES ABOUT THIS PLAYER (most relevant first; older entries may be outdated):" }
    for _, item in ipairs(taken) do
        local r = item.row
        local days = math.floor((now - (item.createdAt or now)) / 86400)
        local when = days <= 0 and "today" or (days .. "d ago")
        lines[#lines + 1] = string.format("- [%s] %s (remembered %s)", r.kind or "fact", r.content, when)
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- CITY REPUTATION (T2-E) - tags on the PLAYER, injected as "CITY RUMOR"
-- ============================================================================
local REPUTATION_BEHAVIOUR = {
    violent = "BEHAVIOUR: You have heard this person is VIOLENT. Keep your distance, stay alert, never provoke them, end conversations early if they get pushy.",
    generous = "BEHAVIOUR: You have heard this person is GENEROUS (tips well, helps people). Be warmer than usual, a little hopeful they might help you too.",
    cop = "BEHAVIOUR: This person is (or runs with) the POLICE. Watch your wording, admit nothing, stay polite but closed off.",
    friendly = "BEHAVIOUR: You have heard this person is FRIENDLY and fair. Easy warmth, no walls up.",
    sketchy = "BEHAVIOUR: You have heard this person is SKETCHY. Keep one hand on your wallet, don't agree to anything.",
}
local VALID_REPUTATION_TAGS = {
    violent = true, generous = true, friendly = true, sketchy = true,
}

function BumpReputation(identifier, tag, amount)
    if not (Config.Reputation and Config.Reputation.Enabled) then return end
    if type(identifier) ~= "string" or type(tag) ~= "string" or not VALID_REPUTATION_TAGS[tag] then return end
    amount = tonumber(amount) or 1
    CreateThread(function()
        local now = os.time()
        local maxLevel = (Config.Reputation and Config.Reputation.MaxTagLevel) or 10
        local ok, rows = pcall(MySQL.query.await,
            'SELECT level FROM npci_reputation WHERE player_identifier = ? AND tag = ?',
            { identifier, tag })
        if ok and rows and #rows > 0 then
            local newLevel = math.min((tonumber(rows[1].level) or 1) + amount, maxLevel)
            pcall(MySQL.update.await,
                'UPDATE npci_reputation SET level = ?, last_at = ? WHERE player_identifier = ? AND tag = ?',
                { newLevel, now, identifier, tag })
        else
            pcall(MySQL.insert.await,
                'INSERT INTO npci_reputation (player_identifier, tag, level, last_at) VALUES (?, ?, ?, ?)',
                { identifier, tag, math.min(amount, maxLevel), now })
        end
    end)
end

function BuildCityRumorBlock(identifier, playerName)
    if not (Config.Reputation and Config.Reputation.Enabled) then return "" end
    local lines = {}
    local ok, rows = pcall(MySQL.query.await,
        'SELECT tag, level FROM npci_reputation WHERE player_identifier = ? ORDER BY level DESC',
        { identifier })
    if ok and rows then
        for _, r in ipairs(rows) do
            local behaviour = REPUTATION_BEHAVIOUR[r.tag]
            if behaviour then
                lines[#lines + 1] = string.format("- %s (weight %d)", string.upper(r.tag), tonumber(r.level) or 1)
                lines[#lines + 1] = "  " .. behaviour
            end
        end
    end
    if #lines == 0 then return "" end
    return ("CITY RUMOR ABOUT '%s' (this is how the city sees them; let it shape your behaviour):\n%s")
        :format(playerName or "this person", table.concat(lines, "\n"))
end

-- ============================================================================
-- NPC RELATIONSHIPS (T2-F) - persistent friend/rival pairs, evolves per chat
-- ============================================================================
local relationCache = {} -- key "a|b" (sorted) -> { npc_a, npc_b, label_a, label_b, chats, warmth }

local function RelationKey(a, b)
    local na, nb = tostring(a), tostring(b)
    if na > nb then na, nb = nb, na end
    return na, nb, na .. "|" .. nb
end

function LoadRelation(a, b)
    if not (Config.Relations and Config.Relations.Enabled) then return nil end
    local na, nb, key = RelationKey(a, b)
    if relationCache[key] then return relationCache[key] end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT npc_a, npc_b, label_a, label_b, chats, warmth FROM npci_relations WHERE npc_a = ? AND npc_b = ?',
        { na, nb })
    if ok and rows and #rows > 0 then
        local r = rows[1]
        relationCache[key] = { npc_a = r.npc_a, npc_b = r.npc_b, label_a = r.label_a,
            label_b = r.label_b, chats = tonumber(r.chats) or 0, warmth = tonumber(r.warmth) or 0.5 }
        return relationCache[key]
    end
    return nil
end

-- How aId sees bId (label resolves for sort order)
function GetRelationshipLine(aId, bId)
    local rel = LoadRelation(aId, bId)
    if not rel then
        return "You two are strangers who happen to be near each other."
    end
    local otherLabel = (rel.npc_a == tostring(aId)) and rel.label_b or rel.label_a
    local friendAt = (Config.Relations and Config.Relations.FriendThreshold) or 0.75
    local rivalAt = (Config.Relations and Config.Relations.RivalThreshold) or 0.25
    if rel.warmth >= friendAt then
        return ("You two are close friends%s - greet them like family."):format(
            otherLabel ~= "" and (" (" .. otherLabel .. ")") or "")
    elseif rel.warmth <= rivalAt then
        return ("You two have BEEF%s - the tension is real, you can barely stand them."):format(
            otherLabel ~= "" and (" (" .. otherLabel .. ")") or "")
    elseif rel.chats > 0 then
        return "You two are casual acquaintances - you have talked a few times before."
    end
    return "You two are strangers who happen to be near each other."
end

function RecordRelation(aId, bId, labelA, labelB)
    if not (Config.Relations and Config.Relations.Enabled) then return end
    local na, nb, key = RelationKey(aId, bId)
    local la, lb = labelA, labelB
    if na ~= tostring(aId) then la, lb = labelB, labelA end
    CreateThread(function()
        local now = os.time()
        local R = Config.Relations or {}
        local rel = relationCache[key]
        if not rel then
            local warmth = 0.5
            if math.random(1, 100) <= (R.InitialRivalChance or 10) then
                warmth = ((R.RivalThreshold or 0.25)) - 0.05
            end
            rel = { npc_a = na, npc_b = nb, label_a = tostring(la or ""):sub(1, 120),
                label_b = tostring(lb or ""):sub(1, 120), chats = 0, warmth = warmth }
            relationCache[key] = rel
            pcall(MySQL.insert.await,
                'INSERT INTO npci_relations (npc_a, npc_b, label_a, label_b, chats, warmth, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                { na, nb, rel.label_a, rel.label_b, 0, warmth, now })
        end
        rel.chats = rel.chats + 1
        rel.warmth = math.min(1.0, rel.warmth + (R.WarmthPerChat or 0.05))
        pcall(MySQL.update.await,
            'UPDATE npci_relations SET chats = ?, warmth = ?, updated_at = ? WHERE npc_a = ? AND npc_b = ?',
            { rel.chats, rel.warmth, now, na, nb })
    end)
end

-- "YOUR PEOPLE" block injected into an NPC's own prompt
function BuildPeopleBlock(npcId)
    if not (Config.Relations and Config.Relations.Enabled) then return "" end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT npc_a, npc_b, label_a, label_b, chats, warmth FROM npci_relations WHERE npc_a = ? OR npc_b = ? ORDER BY chats DESC LIMIT 3',
        { npcId, npcId })
    if not ok or not rows or #rows == 0 then return "" end
    local lines = {}
    for _, r in ipairs(rows) do
        local otherLabel = r.label_b
        if r.npc_b == tostring(npcId) then otherLabel = r.label_a end
        local w = tonumber(r.warmth) or 0.5
        local friendAt = (Config.Relations and Config.Relations.FriendThreshold) or 0.75
        local rivalAt = (Config.Relations and Config.Relations.RivalThreshold) or 0.25
        local kind = "acquaintance"
        if w >= friendAt then kind = "close friend" elseif w <= rivalAt then kind = "rival" end
        local who = (otherLabel ~= nil and otherLabel ~= "") and otherLabel or ("a local " .. kind)
        lines[#lines + 1] = string.format("- %s (%s)", who, kind)
    end
    return "YOUR PEOPLE (other NPCs you know in this city):\n" .. table.concat(lines, "\n")
end

-- ============================================================================
-- BARKS (T1-C/D + T2-G/H/J) - short spoken lines outside full conversations
-- ============================================================================
local barkCooldowns = {} -- [kind.."|"..src.."|"..npcId] = os.time()+cd
local PANIC_LINES = {
    "Somebody's been shot! Call 911!", "Holy shit, get down!", "He's dead! He's actually dead!",
    "Someone get the cops, NOW!", "I ain't dying for this - GO!",
}
local RAIN_LINES = {
    "Aw hell, I just dried off.", "This rain is killing my day.", "Great. Just great.",
    "Damn, I'm soaked.", "Where's my damn umbrella?",
}

local function GetTopMemoryFor(identifier, npcId)
    local ok, rows = pcall(MySQL.query.await,
        'SELECT content, importance FROM npci_memories WHERE player_identifier = ? AND npc_id = ? AND superseded = 0 ORDER BY importance DESC, last_used_at DESC LIMIT 1',
        { identifier, npcId })
    if ok and rows and #rows > 0 then return rows[1].content end
    return nil
end

RegisterNetEvent('npci_server:requestBark', function(kind, stateBagId, role, mood)
    local src = source
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end
    if type(kind) ~= 'string' or type(stateBagId) ~= 'string' then return end
    role = type(role) == 'string' and role or "Civilian"
    mood = type(mood) == 'string' and mood or "indifferent"
    local identifier = player.identifier

    local function reply(text)
        if type(text) == 'string' and text ~= '' then
            TriggerClientEvent('npci_server:playBark', src, stateBagId, text, kind)
        end
    end

    if kind == 'panic' then
        local p = GetNpcPersona(stateBagId, nil, role)
        local bank = p and p.panicLines
        reply((bank and bank[math.random(#bank)]) or PANIC_LINES[math.random(#PANIC_LINES)])
        return
    end

    if kind == 'weather' then
        local cfg = Config.WeatherBehavior or {}
        if math.random(1, 100) > (cfg.ComplainChance or 40) then return end
        local p = GetNpcPersona(stateBagId, nil, role)
        local bank = p and p.rainLines
        reply((bank and bank[math.random(#bank)]) or RAIN_LINES[math.random(#RAIN_LINES)])
        return
    end

    if kind ~= 'greeting' and kind ~= 'initiative' then return end

    -- per-player+NPC+kind cooldown
    local cdSec = 600
    if kind == 'greeting' then
        cdSec = (Config.Greeting and Config.Greeting.CooldownSec) or 600
    else
        cdSec = (Config.Initiative and Config.Initiative.CooldownSec) or 900
        if math.random(1, 100) > ((Config.Initiative and Config.Initiative.Chance) or 15) then return end
    end
    local cdKey = kind .. '|' .. tostring(src) .. '|' .. stateBagId
    local now = os.time()
    if barkCooldowns[cdKey] and now < barkCooldowns[cdKey] then return end
    barkCooldowns[cdKey] = now + cdSec

    CreateThread(function()
        -- memory gate: only greet/initiate NPCs who actually remember the player
        local requireMemory = true
        if kind == 'greeting' and Config.Greeting and Config.Greeting.RequireMemory ~= nil then
            requireMemory = Config.Greeting.RequireMemory
        end
        if kind == 'initiative' and Config.Initiative and Config.Initiative.RequireMemory ~= nil then
            requireMemory = Config.Initiative.RequireMemory
        end
        local memory = GetTopMemoryFor(identifier, stateBagId)
        if requireMemory and not memory then return end

        local memoryLine = memory and ("You remember them: " .. memory .. ".")
            or "You have never spoken to them before."
        local instruction
        if kind == 'greeting' then
            instruction = "Acknowledge them like a familiar face - ONE short sentence (under 15 words). Reference the memory naturally if it fits, never dump it verbatim."
        else
            instruction = "You have something to say to them - walk up and break the ice: ONE short sentence (under 15 words), memory-based if possible. NOT an interview."
        end
        local voiceLine = BuildPersonaVoiceLine(stateBagId, role)
        local prompt = string.format([[
You are a living person in Los Santos. %s Your mood is %s.
%s
%s
%s
Output ONLY JSON: {"speech": "your line here"}
]], BuildIdentityLine(stateBagId, role), mood, voiceLine, memoryLine, instruction)

        local provider = BuildProviderChain()[1]
        if not provider then return end
        local ep, method, body, headers = provider.buildRequest({}, prompt)
        PerformHttpRequest(ep, function(statusCode, respText)
            if statusCode ~= 200 then return end
            local content = provider.parseResponse(respText)
            if not content then return end
            local ok, data = pcall(json.decode, content)
            local line = (ok and data and data.speech) or content
            reply(line)
        end, method, body, headers)
    end)
end)

-- Player attacked an NPC (non-lethal) -> small violent bump
RegisterNetEvent('npci_server:reportPlayerAttack', function(npcId)
    local src = source
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player or type(npcId) ~= 'string' then return end
    BumpReputation(player.identifier, 'violent',
        (Config.Reputation and Config.Reputation.AttackViolence) or 1)
end)

-- Player killed an NPC -> big violent bump + the victim remembers forever
RegisterNetEvent('npci_server:reportNpcDeath', function(npcId)
    local src = source
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player or type(npcId) ~= 'string' then return end
    if not (Config.Death and Config.Death.ReportReputation) then return end
    BumpReputation(player.identifier, 'violent',
        (Config.Reputation and Config.Reputation.KillViolence) or 3)
    PersistExtractedMemories(player.identifier, npcId, {
        { content = "You MURDERED them in cold blood - they will never forget it.", kind = "fact", importance = 0.95 },
    })
end)

function GenerateLongTermMemory(identifier, npcIdentifier, fullHistory)
    if not fullHistory or #fullHistory < 3 then return end

    local summarizerPrompt = string.format([[
Read the following conversation between an NPC and a Player.

Task 1 - summary: Extract the 3 most important facts the NPC should remember about the player (e.g., their name, if they were rude, if they bought something, where they met). Keep it extremely brief - a few bullet points.

Task 2 - durable memories: Extract up to 3 DURABLE memories that will matter in FUTURE conversations. Only lasting things (preferences, promises, relationships, habits, background facts, how they treat people) - never one-off small talk or things only about the current chat topic.
- kind: exactly one of "fact" (stable background), "preference" (likes/dislikes), "procedure" (what to do for them / how they want things), "environment" (where things are, plans, events).
- importance: 0.0-1.0 (identity/name 0.9+, major promises 0.8+, mild trivia 0.3 or less).
- supersedes: if this memory REPLACES an older belief (e.g., they no longer work somewhere), briefly quote the old belief; otherwise null.

Task 3 - city rumor: If the conversation clearly reveals how this PLAYER treats people (violent/threatening, generous/helpful, friendly/fair, sketchy/untrustworthy), set "rumor" to that one word. Only when strongly evidenced; otherwise null.

Conversation history:
%s

Output ONLY in this JSON format:
{"summary": "- Fact 1 about the player\n- Fact 2 about the player\n- Fact 3 about the player", "memories": [{"content": "short durable memory sentence", "kind": "preference", "importance": 0.7, "supersedes": null}], "rumor": null}
]], json.encode(fullHistory))

    local provider = BuildProviderChain()[1]
    if not provider then return end

    local endpoint, method, body, headers = provider.buildRequest({}, summarizerPrompt)
    PerformHttpRequest(endpoint, function(statusCode, responseText)
        if statusCode ~= 200 then return end
        local content = provider.parseResponse(responseText)
        if not content then return end
        local ok, data = pcall(json.decode, content)
        if not ok or not data or not data.summary then return end

        -- Structured cognitive memories (classified, deduped, superseding)
        if type(data.memories) == "table" then
            PersistExtractedMemories(identifier, npcIdentifier, data.memories)
        end

        -- City rumor earned from how the player treated people (T2-E)
        if type(data.rumor) == "string" and VALID_REPUTATION_TAGS[data.rumor] then
            BumpReputation(identifier, data.rumor, 1)
        end

        -- Load existing LTM and merge
        exports.oxmysql:execute(
            'SELECT long_term_summary FROM npci_memory WHERE player_identifier = ? AND npc_id = ?',
            {identifier, npcIdentifier},
            function(result)
                local existing = "No past interactions."
                if result and #result > 0 and result[1].long_term_summary then
                    existing = result[1].long_term_summary
                end

                local merged = data.summary
                if existing ~= "No past interactions." then
                    merged = existing .. "\n" .. data.summary
                end

                -- Cap stored summary so it can't grow without bound (it is injected into every prompt)
                if #merged > 4000 then
                    merged = merged:sub(#merged - 3999)
                    local nl = merged:find("\n")
                    if nl then merged = merged:sub(nl + 1) end
                end

                exports.oxmysql:execute(
                    'UPDATE npci_memory SET long_term_summary = ? WHERE player_identifier = ? AND npc_id = ?',
                    {merged, identifier, npcIdentifier}
                )
            end
        )
    end, method, body, headers)
end

-- ============================================================================
--           PROACTIVE AI REACTIONS (CRASH + IDLE TIMEOUT)
-- ============================================================================
RegisterNetEvent('npci_server:proactiveReaction')
AddEventHandler('npci_server:proactiveReaction', function(npcNetId, eventType, npcData)
    if type(eventType) ~= 'string' then return end
    if npcData ~= nil and type(npcData) ~= 'table' then return end

    local systemOverride = ""
    if eventType == 'VEHICLE_CRASH' then
        systemOverride = "CRITICAL INTERRUPT: The player just violently crashed the car mid-conversation! Break away from what you were previously saying. Yell, panic, or angrily insult their driving skills immediately based on your mood. Keep it to one sentence."
    elseif eventType == 'PLAYER_SILENT' then
        systemOverride = "SITUATIONAL CONTEXT: The player has been silently sitting in the car without saying a word for 3 minutes. Call them out on it, ask if they are zoning out, or tell them to say something. Keep it to one sentence."
    end

    local provider = BuildProviderChain()[1]
    if not provider then return end

    local prompt = systemOverride
    if npcData then
        local playerName = "Stranger"
        local basePrompt = BuildMasterPrompt(npcData, playerName)
        prompt = basePrompt .. "\n\n" .. systemOverride
    end

    local endpoint, method, body, headers = provider.buildRequest({}, prompt)
    PerformHttpRequest(endpoint, function(statusCode, responseText)
        if statusCode ~= 200 then return end
        local content = provider.parseResponse(responseText)
        if not content then return end
        local ok, data = pcall(json.decode, content)
        local speech = (ok and data and data.speech) or content
        local stateBagId = npcData and npcData.id or nil
        if stateBagId then
            TriggerClientEvent('npci_server:receiveMutterAudio', -1, stateBagId, speech)
        end
    end, method, body, headers)
end)

-- ============================================================================
--           TTS SYNTHESIS (local edge-tts via Python sidecar)
-- ============================================================================
RegisterNetEvent('npci_server:requestTtsAudio')
AddEventHandler('npci_server:requestTtsAudio', function(text, coords, volume, pedNetId, isMale, voiceAge)
    local src = source
    if type(text) ~= 'string' or #text > 500 then return end
    local targetUrl = "http://127.0.0.1:5001/synthesize"

    local cleanText = string.gsub(text, "%b()", "")
    cleanText = string.gsub(cleanText, "%*%*", "")
    cleanText = string.gsub(cleanText, "%s+", " ")
    cleanText = cleanText:gsub("^%s+", ""):gsub("%s+$", "")

    if cleanText == "" then return end

    local payload = {
        text = cleanText,
        gender = isMale and "male" or "female",
        charId = tostring(pedNetId),
        voiceAge = voiceAge or "adult"
    }

    PerformHttpRequest(targetUrl, function(statusCode, responseData, headers)
        if statusCode == 200 and responseData then
            local decodeOk, decoded = pcall(json.decode, responseData)
            if decodeOk and decoded and decoded.audio then
                TriggerClientEvent('npci_client:playPremiumTts', src, decoded.audio)
            end
        else
            print("^1[NPCI TTS] Premium Python synthesis failed with code: " .. tostring(statusCode) .. "^7")
        end
    end, "POST", json.encode(payload), {["Content-Type"] = "application/json"})
end)

-- ============================================================================
--           VOICE TRANSCRIPTION (local Whisper via Python sidecar)
-- ============================================================================
RegisterNetEvent('npci_server:transcribeVoice')
AddEventHandler('npci_server:transcribeVoice', function(base64AudioString)
    local src = source
    if type(base64AudioString) ~= 'string' or #base64AudioString == 0 or #base64AudioString > 2000000 then return end
    local player = ESX and ESX.GetPlayerFromId(src)
    if not player then return end
    local g = player.group and string.lower(player.group) or ""
    if g ~= "admin" and g ~= "superadmin" and g ~= "mod" and g ~= "associate" and g ~= "elite" then
        TriggerClientEvent('npci_client:serverDebugLog', src, "^1[SERVER] Voice transcription denied — insufficient role.^7")
        return
    end
    local targetUrl = "http://127.0.0.1:5001/transcribe"

    TriggerClientEvent('npci_client:serverDebugLog', src, "^3[SERVER DEBUG] Audio payload arrived at server. Sending to Python Whisper...^7")

    local requestPayload = { audio = base64AudioString }

    PerformHttpRequest(targetUrl, function(statusCode, responseData, headers)
        if statusCode == 200 and responseData then
            local decodeOk, decodedResponse = pcall(json.decode, responseData)
            if decodeOk and decodedResponse and decodedResponse.text then
                local spokenText = decodedResponse.text

                if spokenText and spokenText ~= "" then
                    TriggerClientEvent('npci_client:serverDebugLog', src, "^2[NPCI STT] Local Whisper Transcribed: '" .. tostring(spokenText) .. "'^7")
                    TriggerClientEvent('npci_server:receiveChatInput', src, spokenText)
                else
                    TriggerClientEvent('npci_client:serverDebugLog', src, "^1[NPCI STT] Whisper processed the audio, but detected absolute silence.^7")
                end
            else
                TriggerClientEvent('npci_client:serverDebugLog', src, "^1[NPCI STT] Failed to parse JSON response from Python server.^7")
            end
        else
            if statusCode == 0 then
                TriggerClientEvent('npci_client:serverDebugLog', src, "^1[NPCI STT] CRITICAL: Server couldn't connect to port 5001! Is stt_sidecar.py running on your host machine?^7")
            else
                TriggerClientEvent('npci_client:serverDebugLog', src, "^1[NPCI STT] Python runtime error! Status: " .. tostring(statusCode) .. "^7")
            end
        end
    end, "POST", json.encode(requestPayload), {["Content-Type"] = "application/json"})
end)
