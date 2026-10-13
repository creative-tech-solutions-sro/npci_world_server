-- ============================================================================
-- phone_bridge.lua — NPC AI Phone & SMS Integration Bridge (ESX Edition)
-- Integrates npci_world_server with AndroDriss / gcphone-next
-- ============================================================================

local NpcPhoneRegistry = {} -- [npcPhoneNumber] = { id, name, role, gender, model_hash }
local NpcPhoneById = {} -- [npcId] = npcPhoneNumber (reverse lookup)

-- Global lookup for other modules (BuildMasterPrompt etc.)
function GetNpcPhoneNumber(npcId)
    if not npcId then return nil end
    return NpcPhoneById[npcId]
end

-- ============================================================================
-- GENERATE A UNIQUE NPC PHONE NUMBER (async callback-based)
-- ============================================================================
local function GenerateNpcPhoneNumber(callback)
    local attempts = 0
    local maxAttempts = 50
    local function tryGenerate()
        if attempts >= maxAttempts then
            callback(nil)
            return
        end
        attempts = attempts + 1
        local firstPart = tostring(math.random(300, 399))
        local secondPart = tostring(math.random(1000, 9999))
        local number = firstPart .. "-" .. secondPart
        if not NpcPhoneRegistry[number] then
            exports.oxmysql:single('SELECT id FROM phone_contacts WHERE number = ? LIMIT 1',
                { number },
                function(existing)
                    if not existing then
                        callback(number)
                    else
                        tryGenerate()
                    end
                end
            )
        else
            tryGenerate()
        end
    end
    tryGenerate()
end

-- ============================================================================
-- CHECK AND ADD NPC CONTACT (called when player starts interacting)
-- ============================================================================
RegisterNetEvent('npci_bridge:checkAndAddContact')
AddEventHandler('npci_bridge:checkAndAddContact', function(npcData)
    local src = source
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end

    local identifier = xPlayer.getIdentifier and xPlayer.getIdentifier() or xPlayer.identifier
    local npcName = npcData.name or "Unknown"
    local contactName = "N " .. npcName

    exports.oxmysql:execute('SELECT number FROM phone_contacts WHERE identifier = ? AND display = ? LIMIT 1', {
        identifier, contactName
    }, function(result)
        if #result > 0 then
            -- Already have this contact; ensure registry is populated
            local num = result[1].number
            if not NpcPhoneRegistry[num] then
                NpcPhoneRegistry[num] = {
                    id = npcData.id,
                    name = npcName,
                    role = npcData.role or "Civilian",
                    gender = npcData.gender or "unknown",
                    model_hash = npcData.model_hash or nil,
                    phoneNumber = num
                }
                NpcPhoneById[npcData.id] = num
            end
            -- Refresh phone contacts UI so player sees the contact immediately
            exports.oxmysql:query(
                'SELECT id, number, display, avatar, favorite FROM phone_contacts WHERE identifier = ? ORDER BY favorite DESC, display ASC LIMIT 500',
                { identifier },
                function(contacts)
                    TriggerClientEvent('gcphone:contactsUpdated', src, contacts or {})
                end
            )
            return
        end

        -- Generate new NPC phone number (async)
        GenerateNpcPhoneNumber(function(npcPhoneNumber)
            if not npcPhoneNumber then
                print("^1[NPCI PHONE] Failed to generate unique phone number for NPC: " .. npcName .. "^7")
                return
            end

            -- Register in memory
            NpcPhoneRegistry[npcPhoneNumber] = {
                id = npcData.id,
                name = npcName,
                role = npcData.role or "Civilian",
                gender = npcData.gender or "unknown",
                model_hash = npcData.model_hash or nil,
                phoneNumber = npcPhoneNumber
            }
            NpcPhoneById[npcData.id] = npcPhoneNumber

            -- Insert into phone_contacts table
            exports.oxmysql:update('INSERT INTO phone_contacts (identifier, number, display) VALUES (?, ?, ?)', {
                identifier, npcPhoneNumber, contactName
            }, function(rowsChanged)
                if rowsChanged and rowsChanged > 0 then
                    print(("^2[NPCI PHONE] Saved contact: %s (%s) for %s^7"):format(contactName, npcPhoneNumber, identifier))
                    TriggerClientEvent('npci_client:serverDebugLog', src,
                        ("^2[NPCI] ^7%s saved as contact: ^3%s^7"):format(npcName, npcPhoneNumber))

                    -- Refresh phone contacts UI so player sees the new contact immediately
                    exports.oxmysql:query(
                        'SELECT id, number, display, avatar, favorite FROM phone_contacts WHERE identifier = ? ORDER BY favorite DESC, display ASC LIMIT 500',
                        { identifier },
                        function(contacts)
                            TriggerClientEvent('gcphone:contactsUpdated', src, contacts or {})
                        end
                    )
                end
            end)
        end)
    end)
end)

-- ============================================================================
-- RESOLVE NPC IDENTITY FROM PHONE NUMBER (async callback-based)
-- ============================================================================
function GetNpcIdentityByPhone(phoneNumber, playerIdentifier, callback)
    if not phoneNumber then callback(nil); return end
    local entry = NpcPhoneRegistry[phoneNumber]
    if entry then
        entry.phoneNumber = phoneNumber
        callback(entry)
        return
    end

    -- Fallback: query DB contacts for the display name
    if playerIdentifier then
        exports.oxmysql:single(
            'SELECT display FROM phone_contacts WHERE number = ? AND identifier = ? LIMIT 1',
            { phoneNumber, playerIdentifier },
            function(result)
                if result and result.display then
                    local npcName = result.display:gsub("^N ", "")
                    local npcIdentity = { name = npcName, role = "Civilian", gender = "unknown", phoneNumber = phoneNumber }
                    NpcPhoneRegistry[phoneNumber] = npcIdentity
                    callback(npcIdentity)
                else
                    callback(nil)
                end
            end
        )
    else
        callback(nil)
    end
end

-- ============================================================================
-- BUILD SMS SYSTEM PROMPT
-- ============================================================================
local function BuildSmsSystemPrompt(npcIdentity, playerName)
    local name = npcIdentity.name or "Marcus"
    local role = npcIdentity.role or "Civilian"
    local gender = npcIdentity.gender or "unknown"
    local phoneNumber = npcIdentity.phoneNumber or nil

    -- The NPC texts as a person with a life, never as a database label like
    -- "Civilian" (nobody texts "I'm a civilian")
    local identityLine = BuildIdentityLine(phoneNumber or name, role)

    local phoneLine = ""
    if phoneNumber then
        phoneLine = "Your cell phone number is " .. phoneNumber .. ". "
    end

    return string.format([[%sYou are %s, a living person in Los Santos. %s You are receiving an SMS text message on your cell phone from %s.

SYSTEM NOTICE:
- Respond naturally via text message as if you are reading and replying on your phone.
- Vary your responses — sometimes a few words, sometimes a couple sentences. Don't make every text the same length.
- NEVER start texts with "Well,", "Uh,", "Hmm,", "I mean,", "Ah," — real people don't text like that.
- NEVER announce what class of human you are — no "I'm a civilian", no "just a citizen", no "a local". You text about what you are doing, what you need, and what is going on with you, like anybody texting a friend.
- Do NOT use action asterisks (*) or parentheses ().
- Do NOT describe physical actions or gestures — this is a text message conversation.
- Be in-character based on your personality and your life.
- You already know %s well and consider them a friend. Be friendly, casual, and familiar — like texting a buddy.
- Use natural texting style — abbreviations ("gonna", "wanna", "lol"), occasional lowercase, no forced punctuation. Keep it authentic.
- Ask questions sometimes, react to what they said, reference inside jokes if you've talked before.
- Emojis are fine if they fit your character's texting style, but don't overdo it.
- Respond with ONLY the message text, no formatting or prefixes. No "NPC:" or "Character:" labels.]], phoneLine, name, identityLine, playerName, playerName)
end

-- ============================================================================
-- SEND SMS TEXT REQUEST TO AI (plain text, no JSON mode)
-- ============================================================================
local function SendSmsToAi(messages, systemPrompt, callback)
    -- Try the configured primary first (NIM), then ready fallbacks
    local providers = BuildProviderChain()

    if #providers == 0 then
        callback("Sorry, I can't text right now. I'm busy.")
        return
    end

    local function TrySmsProvider(providerIndex)
        if providerIndex > #providers then
            callback("Sorry, I can't text right now. I'm busy.")
            return
        end

        local provider = providers[providerIndex]
        local msgs = {}
        table.insert(msgs, { role = "system", content = systemPrompt })
        for _, msg in ipairs(messages) do
            table.insert(msgs, msg)
        end

        -- Build request WITHOUT format=json for plain text SMS responses
        local endpoint, method, body, headers
        if provider.name == "NVIDIA NIM" then
            local payload = {
                model = Config.AI.NIM.Model,
                messages = msgs,
                temperature = 0.8,
                max_tokens = 400,
                -- Nemotron-3 reasons by default; disable it or SMS replies come back
                -- as the model's thinking instead of the text message.
                chat_template_kwargs = { enable_thinking = false }
            }
            endpoint = Config.AI.NIM.Endpoint
            method = 'POST'
            body = json.encode(payload)
            headers = {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. Config.AI.NIM.ApiKey
            }
        elseif provider.name == "Ollama" then
            local payload = {
                model = Config.AI.Ollama.Model,
                messages = msgs,
                stream = false,
                options = { temperature = 0.8, num_predict = 200 }
            }
            endpoint = Config.AI.Ollama.Endpoint
            method = 'POST'
            body = json.encode(payload)
            headers = { ['Content-Type'] = 'application/json' }
        elseif provider.name == "Gemini" then
            local contents = {}
            for _, msg in ipairs(messages) do
                local role = msg.role == "assistant" and "model" or msg.role
                table.insert(contents, { role = role, parts = { { text = msg.content } } })
            end
            local payload = {
                system_instruction = { parts = { { text = systemPrompt } } },
                contents = contents,
                generationConfig = { temperature = 0.8, maxOutputTokens = 200 }
            }
            endpoint = Config.AI.Gemini.Endpoint .. "/" .. Config.AI.Gemini.Model .. ":generateContent?key=" .. Config.AI.Gemini.ApiKey
            method = 'POST'
            body = json.encode(payload)
            headers = { ['Content-Type'] = 'application/json' }
        elseif provider.name == "OpenAI" then
            local payload = {
                model = Config.AI.OpenAI.Model,
                messages = msgs,
                temperature = 0.8,
                max_tokens = 200
            }
            endpoint = Config.AI.OpenAI.Endpoint
            method = 'POST'
            body = json.encode(payload)
            headers = {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. Config.AI.OpenAI.ApiKey
            }
        else
            TrySmsProvider(providerIndex + 1)
            return
        end

        PerformHttpRequest(endpoint, function(statusCode, responseText, respHeaders)
            if statusCode == 200 then
                local content = provider.parseResponse(responseText)
                if content then
                    -- Strip any JSON wrappers if the AI wrapped text in JSON
                    local cleaned = content:gsub('^%s*{"[^"]+"%s*:%s*"', ''):gsub('"%s*}%s*$', ''):gsub('\\"', '"')
                    callback(cleaned)
                else
                    TrySmsProvider(providerIndex + 1)
                end
            else
                TrySmsProvider(providerIndex + 1)
            end
        end, method, body, headers)
    end

    TrySmsProvider(1)
end

-- ============================================================================
-- PROCESS SMS AI QUERY (entry point from phone script interception)
-- ============================================================================
RegisterNetEvent('npci_server:processSmsAiQuery')
AddEventHandler('npci_server:processSmsAiQuery', function( ... )
    local args = { ... }
    local src, npcNumber, playerMessage, playerCharacterName
    if type(args[1]) == 'number' then
        -- Server-side TriggerEvent (AndroDriss): (playerId, npcNumber, message, characterName)
        src = args[1]
        npcNumber = args[2]
        playerMessage = args[3]
        playerCharacterName = args[4]
    else
        -- Client TriggerServerEvent: source is the player, args = (npcNumber, message, characterName)
        src = source
        npcNumber = args[1]
        playerMessage = args[2]
        playerCharacterName = args[3]
    end
    if type(src) ~= 'number' or src <= 0 or src == 65535 then
        print("^1[NPCI SMS] processSmsAiQuery: no valid player source (got " .. tostring(src) .. ")^7")
        return
    end
    handleIncomingSms(src, npcNumber, playerMessage, playerCharacterName)
end)

function handleIncomingSms(src, npcNumber, playerMessage, playerCharacterName)
    if not src then print("^1[NPCI SMS] No source provided^7"); return end
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then print("^1[NPCI SMS] No xPlayer for source: " .. tostring(src) .. "^7"); return end
    local playerIdentifier = xPlayer.getIdentifier and xPlayer.getIdentifier() or xPlayer.identifier
    print(("^3[NPCI SMS] Received SMS from %s (%s) to %s: %s^7"):format(playerCharacterName or "?", playerIdentifier, npcNumber, playerMessage))
    local myPhoneNumber

    if exports['AndroDriss'] and exports['AndroDriss'].GetPhoneNumber then
        myPhoneNumber = exports['AndroDriss']:GetPhoneNumber(playerIdentifier, src)
    end
    if not myPhoneNumber then
        exports.oxmysql:single(
            'SELECT phone_number FROM users WHERE identifier = ? LIMIT 1',
            { playerIdentifier },
            function(result)
                local resolvedPhone
                if result then
                    resolvedPhone = result.phone_number
                end
                if not resolvedPhone then
                    exports.oxmysql:single(
                        'SELECT phone FROM users WHERE identifier = ? LIMIT 1',
                        { playerIdentifier },
                        function(result2)
                            processSmsMessage(src, playerIdentifier, result2 and result2.phone or "555-0001", npcNumber, playerMessage, playerCharacterName)
                        end
                    )
                else
                    processSmsMessage(src, playerIdentifier, resolvedPhone, npcNumber, playerMessage, playerCharacterName)
                end
            end
        )
    else
        processSmsMessage(src, playerIdentifier, myPhoneNumber, npcNumber, playerMessage, playerCharacterName)
    end
end

-- Location alias map for SMS meetup — maps user-friendly phrases to destination keys
local LocationAliases = {
    { pattern = "vespucci beach", key = "vespucci_beach" },
    { pattern = "vespucci", key = "vespucci_beach" },
    { pattern = "sandy shores", key = "sandy_shores" },
    { pattern = "sandy", key = "sandy_shores" },
    { pattern = "paleto bay", key = "paleto_bay" },
    { pattern = "paleto", key = "paleto_bay" },
    { pattern = "del perro", key = "del_perro_beach" },
    { pattern = "chumash", key = "chumash_beach" },
    { pattern = "paleto beach", key = "paleto_beach" },
    { pattern = "legion square", key = "legion_square" },
    { pattern = "legion", key = "legion_square" },
    { pattern = "diamond casino", key = "diamond_casino" },
    { pattern = "casino", key = "diamond_casino" },
    { pattern = "airport", key = "airport_los_santos" },
    { pattern = "ls airport", key = "airport_los_santos" },
    { pattern = "grove street", key = "grove_street" },
    { pattern = "grove st", key = "grove_street" },
    { pattern = "vinewood", key = "vinewood_sign" },
    { pattern = "observatory", key = "observatory" },
    { pattern = "pier", key = "pier_del_perro" },
    { pattern = "maze bank", key = "maze_bank_arena" },
    { pattern = "maze bank arena", key = "maze_bank_arena" },
    { pattern = "bennys", key = "bennys_motorworks" },
    { pattern = "bennys motorworks", key = "bennys_motorworks" },
    { pattern = "ls customs", key = "ls_customs_burton" },
    { pattern = "ls customs airport", key = "ls_customs_airport" },
    { pattern = "bahama mamas", key = "bahama_mamas" },
    { pattern = "vanilla unicorn", key = "club_vanilla_unicorn" },
    { pattern = "tequi la la", key = "tequi_la_la" },
    { pattern = "burger shot vespucci", key = "burger_shot_vespucci" },
    { pattern = "burger shot downtown", key = "burger_shot_downtown" },
    { pattern = "burger shot rockford", key = "burger_shot_rockford" },
    { pattern = "burger shot morningwood", key = "burger_shot_morningwood" },
    { pattern = "burger shot sandy", key = "burger_shot_sandy" },
    { pattern = "burger shot paleto", key = "burger_shot_paleto" },
    { pattern = "burger shot", key = "burger_shot_downtown" },
    { pattern = "mission row pd", key = "police_station_mission_row" },
    { pattern = "mission row", key = "police_station_mission_row" },
    { pattern = "police station vespucci", key = "police_station_vespucci" },
    { pattern = "police station davis", key = "police_station_davis" },
    { pattern = "police station sandy", key = "police_station_sandy" },
    { pattern = "police station paleto", key = "police_station_paleto" },
    { pattern = "police station rockford", key = "police_station_rockford" },
    { pattern = "police station", key = "police_station_mission_row" },
    { pattern = "central ls hospital", key = "hospital_central_ls" },
    { pattern = "ls hospital", key = "hospital_central_ls" },
    { pattern = "sandy shores hospital", key = "hospital_sandy" },
    { pattern = "sandy hospital", key = "hospital_sandy" },
    { pattern = "paleto bay hospital", key = "hospital_paleto" },
    { pattern = "paleto hospital", key = "hospital_paleto" },
    { pattern = "hospital", key = "hospital_central_ls" },
    { pattern = "fire station ls", key = "fire_station_ls" },
    { pattern = "fire station sandy", key = "fire_station_sandy" },
    { pattern = "fire station paleto", key = "fire_station_paleto" },
    { pattern = "fire station", key = "fire_station_ls" },
    { pattern = "gym vespucci", key = "gym_vespucci" },
    { pattern = "gym sandy", key = "gym_sandy" },
    { pattern = "sandy gym", key = "gym_sandy" },
    { pattern = "bar vespucci", key = "bar_vespucci" },
    { pattern = "bar sandy", key = "bar_sandy" },
    { pattern = "sandy bar", key = "bar_sandy" },
    { pattern = "twenty four seven vespucci", key = "twentyfour_seven_vespucci" },
    { pattern = "twenty four seven sandy", key = "twentyfour_seven_sandy" },
    { pattern = "twenty four seven", key = "twentyfour_seven_vespucci" },
    { pattern = "24/7", key = "twentyfour_seven_vespucci" },
    { pattern = "robs liquor", key = "robs_liquor_vespucci" },
    { pattern = "ammunation vespucci", key = "ammunation_vespucci" },
    { pattern = "ammunation sandy", key = "ammunation_sandy" },
    { pattern = "ammunation", key = "ammunation_vespucci" },
    { pattern = "chamberlain hills", key = "home_chamberlain" },
    { pattern = "chamberlain", key = "home_chamberlain" },
    { pattern = "rancho", key = "home_rancho" },
    { pattern = "rockford hills", key = "home_rockford" },
    { pattern = "davis", key = "home_davis" },
    { pattern = "ballas", key = "ballas_strawberry" },
    { pattern = "strawberry", key = "ballas_strawberry" },
    { pattern = "vagos", key = "vagos_rancho" },
    { pattern = "sandy lost mc", key = "lost_mc_sandy" },
    { pattern = "lost mc", key = "lost_mc_sandy" },
}

-- Detect meetup request in a message and return destination coords + name
local function DetectMeetupRequest(playerMessage)
    local lowerMsg = string.lower(playerMessage or "")
    -- Only trigger if the message is about meeting/coming/going somewhere
    local hasMeetIntent = string.find(lowerMsg, "meet") or string.find(lowerMsg, "come to") or string.find(lowerMsg, "come by") or string.find(lowerMsg, "go to") or string.find(lowerMsg, "head to") or string.find(lowerMsg, "get to")
    if not hasMeetIntent then return nil end
    for _, alias in ipairs(LocationAliases) do
        if string.find(lowerMsg, alias.pattern, 1, true) then
            local loc = Config.LocationCoords[alias.key]
            if loc then
                return { x = loc.x, y = loc.y, z = loc.z, key = alias.key, radius = loc.radius or 5.0 }
            end
        end
    end
    return nil
end

-- Client event to teleport NPC to player's location is handled in client/main.lua

local function processSmsMessage(src, playerIdentifier, myPhoneNumber, npcNumber, playerMessage, playerCharacterName)
    -- Note: Player's message is already saved to DB by the interception in messages.lua
    -- (gcphone:sendMessage handler) along with gcphone:messageSent + gcphone:webSync:messageSent.
    -- Only handle AI processing and response here.

    -- Fetch past chat history for memory context
    exports.oxmysql:execute(
        'SELECT transmitter, receiver, message, time FROM phone_messages WHERE (transmitter = ? AND receiver = ?) OR (transmitter = ? AND receiver = ?) ORDER BY id DESC LIMIT 12',
        { npcNumber, myPhoneNumber, myPhoneNumber, npcNumber },
        function(chatLogs)
            local formattedHistory = {}
            if chatLogs then
                for i = #chatLogs, 1, -1 do
                    local log = chatLogs[i]
                    local role = (log.transmitter == npcNumber) and "assistant" or "user"
                    table.insert(formattedHistory, {
                        role = role,
                        content = log.message
                    })
                end
            end
            print(("^3[NPCI SMS] Retrieved %d chat history messages^7"):format(#formattedHistory))

            -- 2. Resolve NPC identity from phone number
            GetNpcIdentityByPhone(npcNumber, playerIdentifier, function(npcIdentity)
                if not npcIdentity then
                    npcIdentity = { name = "Unknown", role = "Civilian", gender = "unknown", phoneNumber = npcNumber }
                end
                print(("^3[NPCI SMS] Resolved NPC: %s (%s)^7"):format(npcIdentity.name, npcIdentity.role))

                -- 3. Fetch long-term memory from npci_memory for this NPC+player pair
                local npcId = nil
                for num, entry in pairs(NpcPhoneRegistry) do
                    if num == npcNumber then
                        npcId = entry.id
                        break
                    end
                end
                if not npcId then
                    npcId = npcIdentity.name or npcNumber
                end

                exports.oxmysql:single(
                    'SELECT long_term_summary FROM npci_memory WHERE player_identifier = ? AND npc_id = ? LIMIT 1',
                    { playerIdentifier, npcId },
                    function(memRow)
                        local memoryContext = ""
                        if memRow and memRow.long_term_summary and memRow.long_term_summary ~= "No past interactions." then
                            memoryContext = "\n\nPREVIOUS MEMORY:\n" .. memRow.long_term_summary
                            print("^3[NPCI SMS] Including long-term memory in prompt^7")
                        end

                        -- 4. Build SMS prompt with context
                        local senderName = playerCharacterName or "Someone"
                        local systemPrompt = BuildSmsSystemPrompt(npcIdentity, senderName) .. memoryContext

                        -- 5. Send to AI
                        SendSmsToAi(formattedHistory, systemPrompt, function(aiReplyText)
                            if not aiReplyText or aiReplyText == "" then
                                aiReplyText = "Sorry, my phone's acting up. Can you repeat that?"
                            end
                            print(("^2[NPCI SMS] AI reply: %s^7"):format(aiReplyText))

                            -- Command detection — trigger NPC game actions from SMS
                            local cmdLower = string.lower(playerMessage or "")
                            -- lets_race removed in this build (race commands disabled)

                            -- Meetup detection — teleport NPC near player at requested location
                            local meetup = DetectMeetupRequest(playerMessage)
                            if meetup then
                                local entry = NpcPhoneRegistry[npcNumber]
                                local npcId = entry and entry.id
                                local fallbackId = (entry and entry.name) or (npcIdentity and npcIdentity.name) or npcNumber
                                print(("^2[NPCI SMS] Meetup: %s -> %s (npc=%s)^7"):format(playerCharacterName or "?", meetup.key, tostring(npcId or fallbackId)))
                                TriggerClientEvent('npci_client:meetPlayer', src, npcId or fallbackId, meetup.key, meetup.x, meetup.y, meetup.z)
                            end

                            -- 6. Save AI's reply to DB (sender's copy)
                            exports.oxmysql:execute(
                                'INSERT INTO phone_messages (transmitter, receiver, message, owner, is_read, status, delivered_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                                { npcNumber, myPhoneNumber, aiReplyText, 1, 0, 'sent', os.date('%Y-%m-%d %H:%M:%S') }
                            )

                            -- 7. Save AI's reply to DB (receiver's copy) and get insert ID via callback
                            exports.oxmysql:insert(
                                'INSERT INTO phone_messages (transmitter, receiver, message, owner, is_read) VALUES (?, ?, ?, ?, ?)',
                                { npcNumber, myPhoneNumber, aiReplyText, 0, 0 },
                                function(receivedId)
                                    print(("^3[NPCI SMS] Insert returned receivedId: %s^7"):format(tostring(receivedId)))
                                    if receivedId then
                                        exports.oxmysql:single(
                                            'SELECT id, transmitter, receiver, message, media_url, is_read, owner, time, message_type, audio_data, audio_duration, reply_to_id FROM phone_messages WHERE id = ?',
                                            { receivedId },
                                            function(receivedMessage)
                                                if receivedMessage then
                                                    print(("^2[NPCI SMS] Sending gcphone:messageReceived to %d^7"):format(src))
                                                    TriggerClientEvent('gcphone:messageReceived', src, receivedMessage)
                                                    TriggerEvent('gcphone:webSync:messageReceived', receivedMessage)
                                                else
                                                    print("^1[NPCI SMS] receivedMessage not found after insert^7")
                                                end
                                            end
                                        )
                                    else
                                        print("^1[NPCI SMS] receivedId was nil — AI reply not delivered to phone UI^7")
                                    end
                                end
                            )
                        end)
                    end
                )
            end)
        end
    )
end

-- ============================================================================
-- DEBUG EVENT — Look up an NPC phone number
-- ============================================================================
RegisterNetEvent('npci_bridge:lookupNpcPhone')
AddEventHandler('npci_bridge:lookupNpcPhone', function(npcId)
    local src = source
    for number, entry in pairs(NpcPhoneRegistry) do
        if entry.id == npcId then
            TriggerClientEvent('npci_client:serverDebugLog', src,
                ("^2[NPCI PHONE] NPC %s has phone number: %s^7"):format(entry.name, number))
            return
        end
    end
    TriggerClientEvent('npci_client:serverDebugLog', src, "^3[NPCI PHONE] No phone number found for this NPC.^7")
end)

print("^2[NPCI PHONE] NPC Phone Bridge loaded — ready for SMS integration with AndroDriss/gcphone-next.^7")
