ESX.Streaming = {}

---@param modelHash number | string
---@param cb? function
---@return number | nil
function ESX.Streaming.RequestModel(modelHash, cb)
    modelHash = type(modelHash) == "number" and modelHash or joaat(modelHash)

    if not IsModelInCdimage(modelHash) then return end

	RequestModel(modelHash)
	local start = GetGameTimer()

	while not HasModelLoaded(modelHash) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(modelHash) or modelHash
end

---@param textureDict string
---@param cb? function
---@return string | nil
function ESX.Streaming.RequestStreamedTextureDict(textureDict, cb)
	RequestStreamedTextureDict(textureDict, false)

	local start = GetGameTimer()

	while not HasStreamedTextureDictLoaded(textureDict) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(textureDict) or textureDict
end

---@param assetName string
---@param cb? function
---@return string | nil
function ESX.Streaming.RequestNamedPtfxAsset(assetName, cb)
	RequestNamedPtfxAsset(assetName)

	local start = GetGameTimer()

	while not HasNamedPtfxAssetLoaded(assetName) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(assetName) or assetName
end

---@param animSet string
---@param cb? function
---@return string | nil
function ESX.Streaming.RequestAnimSet(animSet, cb)
	RequestAnimSet(animSet)

	local start = GetGameTimer()

	while not HasAnimSetLoaded(animSet) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(animSet) or animSet
end

---@param animDict string
---@param cb? function
---@return string | nil
function ESX.Streaming.RequestAnimDict(animDict, cb)
	RequestAnimDict(animDict)

	local start = GetGameTimer()

	while not HasAnimDictLoaded(animDict) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(animDict) or animDict
end

---@param weaponHash number | string
---@param cb? function
---@return string | number | nil
function ESX.Streaming.RequestWeaponAsset(weaponHash, cb)
	RequestWeaponAsset(weaponHash, 31, 0)

	local start = GetGameTimer()

	while not HasWeaponAssetLoaded(weaponHash) do
		if (GetGameTimer() - start) >= 5000 then
			return
		end

		Wait(0)
	end

	return cb and cb(weaponHash) or weaponHash
end
