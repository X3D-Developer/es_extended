local esxVersion = "v1.13.3"

Core.Migrations = Core.Migrations or {}
Core.Migrations[esxVersion] = Core.Migrations[esxVersion] or {}

if GetResourceKvpInt(("esx_migration:%s"):format(esxVersion)) == 1 then
  return
end

---@return boolean restartRequired
Core.Migrations[esxVersion].ssn = function()
  print(ESX.Q("^4[esx_migration:v.1.13.3:ssn]^7 Adding SSN column to {users} table."))
  local col = MySQL.scalar.await([[
    SELECT COUNT(*)
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = ?
      AND COLUMN_NAME = 'ssn'
]], { Config.Tables.users })

  local idx = MySQL.scalar.await([[
    SELECT COUNT(*)
    FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = ?
      AND INDEX_NAME = 'unique_ssn'
]], { Config.Tables.users })

  if col == 0 and idx == 0 then
    MySQL.update.await(ESX.Q([[
        ALTER TABLE `{users}`
            ADD COLUMN `ssn` VARCHAR(11) NULL DEFAULT NULL AFTER `identifier`,
            ADD UNIQUE KEY `unique_ssn` (`ssn`)
    ]]))
  elseif col == 0 then
    MySQL.update.await(ESX.Q("ALTER TABLE `{users}` ADD COLUMN `ssn` VARCHAR(11) NULL DEFAULT NULL AFTER `identifier`"))
  elseif idx == 0 then
    MySQL.update.await(ESX.Q("ALTER TABLE `{users}` ADD UNIQUE KEY `unique_ssn` (`ssn`)"))
  end


  local Result = MySQL.query.await(ESX.Q("SELECT `identifier` FROM `{users}` WHERE `ssn` IS NULL"))
  if #Result == 0 then
    print("^4[esx_migration:v.1.13.3:ssn]^7 No users found without SSN, migration not needed.")
    return false
  end

  print("^4[esx_migration:v.1.13.3:ssn]^7 Generating SSN for existing users.")
  local GeneratedSSNs = {}
  local Parameters = {}
  for i = 1, #Result do
    local ssn
    repeat
      ssn = Core.generateSSN(true)
    until not GeneratedSSNs[ssn]

    GeneratedSSNs[ssn] = true
    Parameters[i] = { ssn, Result[i].identifier }
  end

  print("^4[esx_migration:v.1.13.3:ssn]^7 Updating users with generated SSN. This may take a minute...")
  MySQL.prepare.await(ESX.Q("UPDATE `{users}` SET `ssn` = ? WHERE `identifier` = ?"), Parameters)

  print("^4[esx_migration:v.1.13.3:ssn]^7 Removing SSN default value.")
  MySQL.update.await(ESX.Q("ALTER TABLE `{users}` MODIFY `ssn` VARCHAR(11) NOT NULL"))

  print(("^4[esx_migration:v.1.13.3:ssn]^7 Successfully migrated %d users."):format(#Parameters))

  return true
end
