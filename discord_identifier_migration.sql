-- Migration script to update existing database for Discord identifier format
-- This script should be run on existing databases to support the new discord:discordid format

USE `es_extended`;

-- Update the identifier column to support longer Discord identifiers
ALTER TABLE `users` MODIFY COLUMN `identifier` VARCHAR(100) NOT NULL COMMENT 'Supports discord:discordid format';

-- Note: If you have existing data with short identifiers (just numbers), 
-- you may need to manually update them to the full discord:discordid format
-- Example: UPDATE users SET identifier = CONCAT('discord:', identifier) WHERE identifier NOT LIKE 'discord:%';

-- Remove multicharacter related tables if they exist
DROP TABLE IF EXISTS `multicharacter_slots`;

COMMIT;