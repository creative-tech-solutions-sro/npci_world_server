-- npci_memory.sql
-- Reference schema for the npci_memory table.
-- NOTE: The authoritative creation/migration logic lives in server/sv_setupdatabase.lua
-- and runs automatically on resource start. Keep this file in sync with it.

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

-- Cognitive memories: classified chunks with importance, decay and supersession.
-- Retrieval score = 0.5*similarity + 0.3*recency + 0.2*importance (see main.lua).
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

-- City reputation: tags attached to a PLAYER, injected as "CITY RUMOR".
CREATE TABLE IF NOT EXISTS `npci_reputation` (
    `player_identifier` VARCHAR(60) NOT NULL,
    `tag` VARCHAR(20) NOT NULL,
    `level` INT NOT NULL DEFAULT 1,
    `last_at` INT NOT NULL DEFAULT 0,
    PRIMARY KEY (`player_identifier`, `tag`)
) ENGINE=InnoDB;

-- Persistent NPC-to-NPC relationships, evolved by observed chats.
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
