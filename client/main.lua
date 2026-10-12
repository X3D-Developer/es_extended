Core = {}
Core.Input = {}
Core.Events = {}

ESX.PlayerData = {}
ESX.PlayerLoaded = false
ESX.playerId = PlayerId()
ESX.serverId = GetPlayerServerId(ESX.playerId)

ESX.UI = {}
ESX.UI.Menu = {}
ESX.UI.Menu.RegisteredTypes = {}
ESX.UI.Menu.Opened = {}
ESX.UI.Menu.OpenedByKey = {}  -- OPTIMIZATION: Lookup table for O(1) access

ESX.Game = {}
ESX.Game.Utils = {}

CreateThread(function()
    while not Config.Multichar do
        Wait(100)

        if NetworkIsPlayerActive(ESX.playerId) then
            ESX.DisableSpawnManager()
            Core.FreezePlayer(true)
            DoScreenFadeOut(0)
            Wait(500)
            TriggerServerEvent("esx:onPlayerJoined")
            break
        end
    end
end)
