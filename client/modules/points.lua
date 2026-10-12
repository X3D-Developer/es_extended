local points = {}

-- OPTIMIZATION: Helper to calculate squared distance (avoids sqrt)
local function getDistanceSquared(coords1, coords2)
    local dx = coords1.x - coords2.x
    local dy = coords1.y - coords2.y
    local dz = coords1.z - coords2.z
    return dx * dx + dy * dy + dz * dz
end

function ESX.CreatePointInternal(coords, distance, hidden, enter, leave)
    local point = {
        coords = coords,
        distance = distance,
        distanceSq = distance * distance,  -- Pre-calculate squared distance
        hidden = hidden,
        enter = enter,
        leave = leave,
        resource = GetInvokingResource()
    }
    local handle = ESX.Table.SizeOf(points) + 1
    points[handle] = point
    return handle
end

function ESX.RemovePointInternal(handle)
    points[handle] = nil
end

function ESX.HidePointInternal(handle, hidden)
    if points[handle] then
        points[handle].hidden = hidden
    end
end

function StartPointsLoop()
    CreateThread(function()
        while ESX.PlayerLoaded do
            local ped = ESX.PlayerData.ped
            local nearbyCount = 0
            local sleepTime = 500

            -- OPTIMIZATION: Skip if ped doesn't exist
            if DoesEntityExist(ped) then
                local coords = GetEntityCoords(ped)

                for handle, point in pairs(points) do
                    -- OPTIMIZATION: Skip hidden points entirely (no distance calc)
                    if point.hidden then
                        if point.nearby then
                            points[handle].nearby = false
                            point.leave()
                        end
                    else
                        -- OPTIMIZATION: Use squared distance (avoids sqrt)
                        local distSq = getDistanceSquared(coords, point.coords)

                        if distSq <= point.distanceSq then
                            nearbyCount = nearbyCount + 1
                            if not point.nearby then
                                points[handle].nearby = true
                                point.enter()
                            end
                        elseif point.nearby then
                            points[handle].nearby = false
                            point.leave()
                        end
                    end
                end

                -- OPTIMIZATION: Dynamic sleep based on nearby points
                sleepTime = nearbyCount > 0 and 250 or 500
            else
                sleepTime = 1000
            end

            Wait(sleepTime)
        end
    end)
end


AddEventHandler('onResourceStop', function(resource)
	for handle, point in pairs(points) do
		if point.resource == resource then
			points[handle] = nil
		end
	end
end)