-- Helper function to process paycheck (reduces code duplication)
local function processPaycheck(playerId, playerName, salary, jobLabel, logType)
    -- Verify player still exists before processing
    local xPlayer = ESX.GetPlayerFromId(playerId)
    if not xPlayer then
        if Config.EnableDebug then
            print(("[^3WARNING^7] Paycheck skipped: Player %s no longer connected"):format(playerId))
        end
        return false
    end

    xPlayer.addAccountMoney("bank", salary, "Paycheck")

    if Config.LogPaycheck then
        ESX.DiscordLogFields("Paycheck", "Paycheck - " .. logType, "green", {
            { name = "Player", value = playerName, inline = true },
            { name = "ID", value = playerId, inline = true },
            { name = "Amount", value = salary, inline = true },
        })
    end

    return true
end

-- Helper function to send paycheck notification
local function sendPaycheckNotification(playerId, message, isError)
    if not GetPlayerName(playerId) then return end -- Player disconnected

    if isError then
        TriggerClientEvent("ESX:Notify", playerId, "error", 5000, message, TranslateCap("bank"))
    else
        local icon = ESX.GetMoneyIcon("bank", 0)
        TriggerClientEvent("ESX:Notify", playerId, "success", 5000, message, TranslateCap("received_paycheck"), nil, icon)
    end
end

function StartPayCheck()
    CreateThread(function()
        while true do
            Wait(Config.PaycheckInterval)

            for playerId, xPlayer in pairs(ESX.Players) do
                -- Capture values before async operations (prevents issues if player disconnects)
                local playerName = xPlayer.name
                local jobName = xPlayer.job.name
                local jobLabel = xPlayer.job.label
                local jobGradeName = xPlayer.job.grade_name
                local onDuty = xPlayer.job.onDuty
                local gradeSalary = xPlayer.job.grade_salary
                local paycheckEnabled = xPlayer.paycheckEnabled

                local salary = (jobGradeName == "unemployed" or onDuty)
                    and gradeSalary
                    or ESX.Math.Round(gradeSalary * Config.OffDutyPaycheckMultiplier)

                if paycheckEnabled and salary > 0 and jobGradeName ~= "unemployed" then
                    if Config.EnableSocietyPayouts then
                        -- Society job - need to check society account
                        local success, err = pcall(function()
                            TriggerEvent("esx_society:getSociety", jobName, function(society)
                                if society ~= nil then
                                    -- Verified society - check shared account
                                    local success2, err2 = pcall(function()
                                        TriggerEvent("esx_addonaccount:getSharedAccount", society.account, function(account)
                                            if not account then
                                                if Config.EnableDebug then
                                                    print(("[^3WARNING^7] Society account not found for job: %s"):format(jobName))
                                                end
                                                return
                                            end

                                            if account.money >= salary then
                                                if processPaycheck(playerId, playerName, salary, jobLabel, jobLabel) then
                                                    account.removeMoney(salary)
                                                    sendPaycheckNotification(playerId, TranslateCap("received_salary", salary), false)
                                                end
                                            else
                                                sendPaycheckNotification(playerId, TranslateCap("company_nomoney"), true)
                                            end
                                        end)
                                    end)

                                    if not success2 and Config.EnableDebug then
                                        print(("[^1ERROR^7] Paycheck addon account error for %s: %s"):format(playerName, tostring(err2)))
                                    end
                                else
                                    -- Not a society - direct payment
                                    if processPaycheck(playerId, playerName, salary, jobLabel, jobLabel) then
                                        sendPaycheckNotification(playerId, TranslateCap("received_salary", salary), false)
                                    end
                                end
                            end)
                        end)

                        if not success and Config.EnableDebug then
                            print(("[^1ERROR^7] Paycheck society error for %s: %s"):format(playerName, tostring(err)))
                        end

                    else
                        -- Generic job - direct payment
                        if processPaycheck(playerId, playerName, salary, jobLabel, "Generic") then
                            sendPaycheckNotification(playerId, TranslateCap("received_salary", salary), false)
                        end
                    end
                end
            end
        end
    end)
end
