-- sv_setupdatabase.lua
-- Creates the npci_memory table if missing and migrates older schemas.

local CREATE_SQL = [[
    CREATE TABLE IF NOT EXISTS `npci_memory` (
        `id` INT AUTO_INCREMENT PRIMARY KEY,
        `player_identifier` VARCHAR(60) NOT NULL,
        `npc_id` VARCHAR(100) NOT NULL,
        `conversation_history` LONGTEXT DEFAULT NULL,
        `current_routine` VARCHAR(50) DEFAULT 'WANDER',
        `target_location` VARCHAR(100) DEFAULT NULL,
        `last_coords` VARCHAR(255) DEFAULT NULL,
        `long_term_summary` LONGTEXT DEFAULT 'No past interactions.',
        UNIQUE KEY `unique_interaction` (`player_identifier`, `npc_id`)
    ) ENGINE=InnoDB;
]]

-- Cognitive memories (Hermes-style): classified chunks with importance, decay,
-- supersession and score-based retrieval (see BuildCognitiveMemoryBlock).
local CREATE_MEMORIES_SQL = [[
    CREATE TABLE IF NOT EXISTS `npci_memories` (
        `id` INT AUTO_INCREMENT PRIMARY KEY,
        `player_identifier` VARCHAR(60) NOT NULL,
        `npc_id` VARCHAR(100) NOT NULL,
        `kind` VARCHAR(20) NOT NULL DEFAULT 'fact',
        `content` VARCHAR(512) NOT NULL,
        `importance` FLOAT NOT NULL DEFAULT 0.5,
        `created_at` INT NOT NULL DEFAULT 0,
        `last_used_at` INT NOT NULL DEFAULT 0,
        `superseded` TINYINT(1) NOT NULL DEFAULT 0,
        KEY `idx_mem_pair` (`player_identifier`, `npc_id`, `superseded`)
    ) ENGINE=InnoDB;
]]

-- City reputation: tags attached to a PLAYER (violent/generous/cop/...),
-- injected into NPC prompts as "CITY RUMOR" and shaping behaviour.
local CREATE_REPUTATION_SQL = [[
    CREATE TABLE IF NOT EXISTS `npci_reputation` (
        `player_identifier` VARCHAR(60) NOT NULL,
        `tag` VARCHAR(20) NOT NULL,
        `level` INT NOT NULL DEFAULT 1,
        `last_at` INT NOT NULL DEFAULT 0,
        PRIMARY KEY (`player_identifier`, `tag`)
    ) ENGINE=InnoDB;
]]

-- Persistent NPC-to-NPC relationships (friend/rival/acquaintance), evolved by
-- observed chats and injected into chat + player prompts.
local CREATE_RELATIONS_SQL = [[
    CREATE TABLE IF NOT EXISTS `npci_relations` (
        `npc_a` VARCHAR(100) NOT NULL,
        `npc_b` VARCHAR(100) NOT NULL,
        `label_a` VARCHAR(120) NOT NULL DEFAULT '',
        `label_b` VARCHAR(120) NOT NULL DEFAULT '',
        `chats` INT NOT NULL DEFAULT 0,
        `warmth` FLOAT NOT NULL DEFAULT 0.5,
        `updated_at` INT NOT NULL DEFAULT 0,
        PRIMARY KEY (`npc_a`, `npc_b`)
    ) ENGINE=InnoDB;
]]

local MIGRATION_SQL = [[
    ALTER TABLE `npci_memory`
        ADD COLUMN IF NOT EXISTS `long_term_summary` LONGTEXT DEFAULT 'No past interactions.';
]]

local function SetupDatabase()
    local okCreate, errCreate = pcall(function()
        MySQL.query.await(CREATE_SQL)
    end)
    if not okCreate then
        print("^1[npci_server] Database table 'npci_memory' FAILED to create: " .. tostring(errCreate) .. "^7")
        return
    end

    local okMem, errMem = pcall(function()
        MySQL.query.await(CREATE_MEMORIES_SQL)
    end)
    if not okMem then
        print("^1[npci_server] Database table 'npci_memories' FAILED to create: " .. tostring(errMem) .. "^7")
    end

    local okRep, errRep = pcall(function()
        MySQL.query.await(CREATE_REPUTATION_SQL)
    end)
    if not okRep then
        print("^1[npci_server] Database table 'npci_reputation' FAILED to create: " .. tostring(errRep) .. "^7")
    end

    local okRel, errRel = pcall(function()
        MySQL.query.await(CREATE_RELATIONS_SQL)
    end)
    if not okRel then
        print("^1[npci_server] Database table 'npci_relations' FAILED to create: " .. tostring(errRel) .. "^7")
    end

    -- Migrate pre-existing tables created by older schemas (missing long_term_summary)
    local okMigrate, errMigrate = pcall(function()
        MySQL.update.await(MIGRATION_SQL)
    end)
    if not okMigrate then
        -- Non-fatal: column may already exist (MariaDB < 10.0.2 has no IF NOT EXISTS for ADD COLUMN)
        print("^3[npci_server] npci_memory migration skipped: " .. tostring(errMigrate) .. "^7")
    end

    print("^2[npci_server] Database table 'npci_memory' verified/created.^7")
end

-- Run automatically on resource start
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end
    CreateThread(function()
        SetupDatabase()
    end)
end)
