local function log (msg)
end

local function extractactargs (args)
	local t = {}
	for idx, arginfo in pairs(args) do
		t[arginfo.name] = arginfo.value
	end
	return t
end

local function getgenericstatuschecker_selfserv_1arg (argname, varname)

	local function handler (a)
		assert(a.action)
		assert(a.service)
		local devno = assert(tonumber(a.device))
		if not luup.devices[devno] then
			return false
		end
		local args = extractactargs(a.arguments)
		if args[argname] then
			local curval = luup.variable_get(a.service, varname, devno)
			if curval == args[argname] then
				return true
			else
				return false
			end
		else
			return true
		end
	end

	return handler
end

local function getgenericstatuschecker_selfserv_num_1arg (argname, varname)

	local function handler (a)
		assert(a.action)
		assert(a.service)
		local devno = assert(tonumber(a.device))
		if not luup.devices[devno] then
			return false
		end
		local args = extractactargs(a.arguments)
		if args[argname] then
			local curval = luup.variable_get(a.service, varname, devno)
			if tonumber(curval)
			and tonumber(curval) == tonumber(args[argname])
			then
				return true
			else
				return false
			end
		else
			return true
		end
	end

	return handler
end

local generic = {} -- SECTION

function generic.SetTarget (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.newTargetValue then
		local curval = luup.variable_get(a.service, "Status", devno)
		if curval ~= nil
		and tonumber(curval) ~= tonumber(args.newTargetValue)
		then
			return false
		else
			return true
		end
	else
		return true
	end
end

function generic.SetLoadLevelTarget (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.newLoadlevelTarget then
		local curval = luup.variable_get(a.service, "LoadLevelStatus", devno)
		if curval ~= nil
		and tonumber(curval) ~= tonumber(args.newLoadlevelTarget)
		then
			return false
		else
			return true
		end
	else
		return true
	end
end

function generic.SetCurrentSetpoint (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.NewCurrentSetpoint then
		local curval = luup.variable_get(a.service, "CurrentSetpoint", devno)
		if curval ~= nil
		and tonumber(curval) ~= tonumber(args.NewCurrentSetpoint)
		then
			return false
		else
			return true
		end
	else
		return true
	end
end

function generic.alwaysOk ()
	return true
end

local media = {} -- SECTION

function media.Stop (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local curval = luup.variable_get("urn:upnp-org:serviceId:AVTransport",
			"TransportState", devno)
	if curval ~= "STOPPED" then
		return false
	else
		return true
	end
end

function media.Pause (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local curval = luup.variable_get("urn:upnp-org:serviceId:AVTransport",
			"TransportState", devno)
	if curval ~= "PAUSED_PLAYBACK" then
		return false
	else
		return true
	end
end

function media.Play (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local curval = luup.variable_get("urn:upnp-org:serviceId:AVTransport",
			"TransportState", devno)
	if curval ~= "PLAYING" then
		return false
	else
		return true
	end
end

function media.SetPlayMode (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.NewPlayMode then
		local curval = luup.variable_get("urn:upnp-org:serviceId:AVTransport",
				"CurrentPlayMode", devno)
		if curval == args.NewPlayMode then
			return true
		else
			return false
		end
	else
		return true
	end
end

function media.ctrlableStop (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local ping_status = luup.variable_get(a.service, "PingStatus", devno)
	local player_status = luup.variable_get(a.service, "PlayerStatus", devno)
	if ping_status == "up"
	and player_status == "--"
	then
		return true
	else
		return false
	end
end

local AC = {} -- SECTION Air Conditioning

function AC.SetModeTarget (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.NewModeTarget then
		local curval = luup.variable_get(a.service, "ModeStatus", devno)
		if curval == args.NewModeTarget then
			return true
		else
			return false
		end
	else
		return true
	end
end

function AC.SetCurrentSetpoint (a)
	assert(a.action)
	assert(a.service)
	local devno = assert(tonumber(a.device))
	if not luup.devices[devno] then
		return false
	end
	local args = extractactargs(a.arguments)
	if args.NewCurrentSetpoint then
		local curval = luup.variable_get(a.service, "CurrentSetpoint", devno)
		if curval == args.NewCurrentSetpoint then
			return true
		else
			return false
		end
	else
		return true
	end
end

local r = {

	["urn:upnp-org:serviceId:SwitchPower1"] = {
		SetTarget = generic.SetTarget,
	},

	["urn:micasaverde-com:serviceId:DoorLock1"] = {
		SetTarget = generic.SetTarget,
	},

	["urn:rts-services-com:serviceId:DayTime"] = {
		SetTarget = generic.SetTarget,
	},

	["urn:upnp-org:serviceId:VSwitch1"] = {
		SetTarget = generic.SetTarget,
	},

	["urn:upnp-org:serviceId:Dimming1"] = {
		SetLoadLevelTarget = generic.SetLoadLevelTarget,
	},

	["urn:upnp-org:serviceId:TemperatureSetpoint1_Cool"] = {
		SetCurrentSetpoint = generic.SetCurrentSetpoint,
	},

	["urn:upnp-org:serviceId:TemperatureSetpoint1_Heat"] = {
		SetCurrentSetpoint = generic.SetCurrentSetpoint,
	},

	["urn:upnp-org:serviceId:TemperatureSetpoint1"] = {
		SetCurrentSetpoint = generic.SetCurrentSetpoint,
	},

	["urn:rboer-com:serviceId:HarmonyDevice1"] = {
		SendDeviceCommand = generic.alwaysOk,
	},

	["urn:micasaverde-com:serviceId:MediaNavigation1"] = {
		Stop = media.Stop,
		Pause = media.Pause,
		Play = media.Play,
	},

        ["urn:upnp-org:serviceId:ctrlableAndroidTVSonyBravia1"] = {
		Netflix = generic.alwaysOk,
	},

        ["urn:micasaverde-com:serviceId:InputSelection1"] = {
                DiscreteinputDVD = generic.alwaysOk,
                DiscreteinputCable = generic.alwaysOk,
                DiscreteinputCD1 = generic.alwaysOk,
                DiscreteinputCD2 = generic.alwaysOk,
                DiscreteinputPC = generic.alwaysOk,
                DiscreteinputDVI = generic.alwaysOk,
                DiscreteinputTV = generic.alwaysOk,
        },

        ["urn:micasaverde-com:serviceId:DiscretePower1"] = {
                On = generic.alwaysOk,
                Off = generic.alwaysOk,
        },

	["urn:upnp-org:serviceId:AVTransport"] = {
		SetPlayMode = media.SetPlayMode,
	},

	["urn:upnp-org:serviceId:ctrlableCheckPlugin1"] = {
		ctrlableStop = media.ctrlableStop,
	},

	["urn:upnp-org:serviceId:HVAC_UserOperatingMode1"] = {
		SetModeTarget = AC.SetModeTarget,
	},

	["urn:upnp-org:serviceId:TemperatureSetpoint1"] = {
		SetCurrentSetpoint = AC.SetCurrentSetpoint,
	},

	["urn:micasaverde-com:serviceId:Color1"] = {
		SetColorRGB = getgenericstatuschecker_selfserv_1arg("newColorRGBTarget",
				"CurrentColor"),
		SetColorTemp = getgenericstatuschecker_selfserv_1arg("newColorTempTarget",
				"CurrentColor"),
		SetColor = getgenericstatuschecker_selfserv_1arg("newColorTarget",
				"CurrentColor"),
	},

	["urn:micasaverde-com:serviceId:SecuritySensor1"] = {
		SetArmed = getgenericstatuschecker_selfserv_num_1arg("newArmedValue",
				"Armed"),
	},

}

-- Set action_checks that should be OK always
local always_ok_actions = {

	["urn:upnp-org:serviceId:RenderingControl"] = {
		"SetMute",
		"SetRelativeVolume",
	},

	["urn:upnp-org:serviceId:AVTransport"] = {
		"Previous",
		"Next",
    "GetTransportSettings",
    "SetRecordQualityMode", -- TODO?
    "Play",
    "GetCurrentTransportActions",
    "SetAVTransportURI", -- TODO?
    "SetNextAVTransportURI", -- TODO?
    "GetDeviceCapabilities",
    "GetMediaInfo",
    "Stop", -- TODO
    "GetTransportInfo",
    "Record", -- TODO
    "Seek",
    "Pause", -- TODO
    "GetPositionInfo",
	},

	["urn:micasaverde-com:serviceId:MediaNavigation1"] = {
		"FastForward",
		"Rewind",
	},

	["urn:micasaverde-com:serviceId:SqueezeBoxPlayer1"] = {
		"Say",
    "AddFileToPlay",
    "AddTracks",
    "LoadAlbum",
    "SetFileToPlay", -- TODO
    "Sync",
    "Command",
    "RandomPlay",
    "AddAlbum",
    "LoadTracks",
	},
}

for servid, actions in pairs(always_ok_actions) do
	for actionidx, actionname in pairs(actions) do
		r[servid] = r[servid] or {}
		r[servid][actionname] = generic.alwaysOk
	end
end

return r


