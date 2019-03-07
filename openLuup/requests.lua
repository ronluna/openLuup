local ABOUT = {
  NAME          = "openLuup.requests",
  VERSION       = "2018.11.21",
  DESCRIPTION   = "Luup Requests, as documented at http://wiki.mios.com/index.php/Luup_Requests",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2018 AKBooer",
  DOCUMENTATION = "https://github.com/akbooer/openLuup/tree/master/Documentation",
  LICENSE       = [[
  Copyright 2013-2018 AK Booer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}

--
-- openLuup.requests - Luup Requests, as documented at http://wiki.mios.com/index.php/Luup_Requests
--
-- These are all implemented as standard luup.register_handler callbacks with the usual three parameters
--

-- 2016.02.21  correct sdata scenes table - thanks @ronluna
-- 2016.02.22  add short_codes to sdata device table - thanks @ronluna
-- 2016.03.11  ensure that device delete removes all children and any relevant scene actions
-- 2016.03.15  add update for openLuup version downloads
-- 2016.04.10  add scene active and status flags in sdata and status reports
-- 2016.04.25  openLuup update changes
-- 2016.04.29  add actual device status to status response 
-- 2016.05.18  generic update_plugin request for latest version
-- 2016.05.23  fix &id=altui plugin numbering string (thanks @amg0)
-- 2016.06.04  remove luup.reload() from device delete action: AltUI requests reload anyway
-- 2016.06.20  better comments for plugin updates and openLuup-specific requests
-- 2016.06.22  move HTTP request plugin update/delete code to here from plugins
-- 2016.07.14  change 'file' request internal syntax to use server.wget
-- 2016.07.18  better error returns for action request
-- 2016.08.09  even better error returns for action request!
-- 2016.11.02  use startup_list (not job_list) in status response
-- 2016.11.15  only show non-successful startup jobs

-- 2017.01.10  fix non-integer values in live_energy_usage, thanks @reneboer
--             see: http://forum.micasaverde.com/index.php/topic,41249.msg306290.html#msg306290
-- 2017.02.05  add 'test' request (for testing!)
-- 2017.11.08  modify 'test' reporting text

-- 2018.01.29  add &ns=1 parameter option to user_data request to ignore static_data object (new Luup feature?)
-- 2018.02.05  move scheduler callback handler initialisation from init module to here
-- 2018.02.06  add static request and internal static_data() function
-- 2018.02.18  implement lu_invoke (partially)
-- 2018.03.24  use luup.rooms metatable methods
-- 2018.04.03  use jobs info from device for status request
-- 2018.04.05  sdata_devices_table - reflect true state from job status
-- 2018.04.09  add archive_video request
-- 2018.04.22  add &id=lua request (not yet done &DeviceNum=xxx - doesn't seem to work on Vera anyway)
-- 2018.11.21  add &id=actions request (thanks @rigpapa for pointing this out)


local http          = require "openLuup.http"
local json          = require "openLuup.json"
local scheduler     = require "openLuup.scheduler"
local devutil       = require "openLuup.devices"      -- for dataversion
local logs          = require "openLuup.logs"
local scenes        = require "openLuup.scenes"
local timers        = require "openLuup.timers"
local userdata      = require "openLuup.userdata"
local loader        = require "openLuup.loader"       -- for static_data, service_data, and loadtime
local xml           = require "openLuup.xml"          -- for xml.encode()
local shared        = require "openLuup.shared"
local posix         = require "posix"
local socket        = require "socket" -- For request_streaming()

--  local _log() and _debug()
local _log, _debug = logs.register (ABOUT)


-- Utility functions

-- return first found device ID if a device of the given type is present locally
local function device_present (device_type)
  for devNo, d in pairs (luup.devices) do
    if ((d.device_num_parent == 0)      -- local device...
    or  (d.device_num_parent == 2))     -- ...or child of openLuup device
    and (d.device_type == device_type) then
      return devNo
    end
  end
end

  
local function spairs (x, fsort)  -- sorted pairs iterator
  local i = 0
  local I = {}
  local function iterator () i = i+1; return I[i], x[I[i]] end
  
  for n in pairs(x) do I[#I+1] = n end
  table.sort(I, fsort)
  return iterator
end

-----
--
-- LOCAL functions: HTTP request handlers
--

local function categories_table (devices)
  local names = {}
  for _,d in pairs (devices or luup.devices) do       -- first pass to find unique device categories
    if not d.invisible and d.category_num ~= 0 then
      names[d.category_num] = d.category_name        -- could be multiple occurrences, so just overwrite
    end
  end
  local info = {}
  for id,name in pairs (names) do                     -- second loop to return only those categories referenced
    info[#info+1] = {id = id, name = name}
  end
  return info
end

local function rooms_table ()
  local info = {}
  for i, name in pairs (luup.rooms) do
    info[#info+1] = {id = i, name = name, section = 1}
  end
  return info
end

local function sections_table ()
  return { {name = "My Home", id = 1} }
end

local function iprequests_table () 
  local info = {}
  for _,x in pairs (http.iprequests) do
    info[#info + 1] = x
  end
  return info 
end

local function static_data ()
  local sd = {}
  for _, data in pairs (loader.static_data) do    -- bundle up the JSON data for all devices 
    sd[#sd+1] = data
  end
  return sd
end

--
-- non-user Luup HTTP requests
--

-- device
-- This renames or deletes a device. Use action=rename or action=delete. 
-- For rename, you can optionally assign a room by passing either the ID or the name.
--
--   http://ip_address:3480/data_request?id=device&action=rename&device=5&name=Chandelier&room=3
--   http://ip_address:3480/data_request?id=device&action=rename&device=5&name=Chandelier&room=Garage
--   http://ip_address:3480/data_request?id=device&action=delete&device=5
--
-- TODO: add better status messages
local function device (_,p)
  local devNo = tonumber (p.device)
  local dev = luup.devices[devNo]

  local function rename ()
    if p.name then
      dev.description = p.name
      dev.attributes.name = p.name
    end
    if p.room then
      local idx = {}
      for i,room in pairs(luup.rooms) do
        idx[room] = i
      end
      dev.room_num = tonumber(p.room) or idx[p.room] or 0
      dev.attributes.room = tostring(dev.room_num)        -- 2018.07.02
    end
  end
  local function delete ()
    local tag = {}                -- list of devices to delete
    local function tag_children (n)
      tag[#tag+1] = n 
      for i,d in pairs (luup.devices) do
        if d.device_num_parent == n then tag_children (i) end
      end
    end
    tag_children(devNo)           -- find all the children, grand-children, etc...
    for _,j in pairs (tag) do
      luup.devices[j] = nil
    end    
    scenes.verify_all()           -- 2016.03.11 ensure there are no references to these devices in scene actions
    -- AltUI variable watch triggers will have to take care of themselves!
  end
  local function noop () end

  if dev then
    _debug ("device action: " .. (p.action or '?'))
    local valid = {rename = rename, delete = delete};
    (valid[p.action or ''] or noop) ()
    devutil.new_userdata_dataversion ()     -- say something major has changed
  end
  return "OK"       -- seems not to be specific about errors!
end


-- invoke
-- This request shows the list of devices and the actions they support 
-- through the UPnP services specified in their UPnP device description file. 
-- Only the actions with a star (*) preceding their name are implemented.
--
--    http://ip_address:3480/data_request?id=invoke
--    http://ip_address:3480/data_request?id=invoke&DeviceNum=6
--    http://ip_address:3480/data_request?id=invoke&UDN=uuid:4d494342-5342-5645-0002-000000000002 
--
local function invoke (_, p)
  -- produces a page with hot links to each device and scene, or, ...
  -- ...if a device number is given, produces a list of device services and actions
  local hag   = "urn:micasaverde-com:serviceId:HomeAutomationGateway1"
  
  local html    = [[<!DOCTYPE html> <head><title>Remote Control</title></head> <body>%s</body> </html>]]
  local Device  = [[<a href="data_request?id=lu_invoke&DeviceNum=%d"> #%d %s</a><br>]]
  local Scene   = [[<a href="data_request?id=action&serviceId=%s&action=RunScene&SceneNum=%d"> #%d %s</a><br>]]  
  local Action  = [[<a href="data_request?id=action&DeviceNum=%d&serviceId=%s&action=%s">%s%s</a><br>]]
  local Service = [[<br><i>%s</i><br>]]

  local body
  local D, S = {}, {}
  local dev = luup.devices[tonumber(p.DeviceNum)]
  
  -- sort by name and parent/child structure? Too much trouble!
  if dev then
    -- Services and Actions for specific device
    for s, srv in spairs (dev.services) do
      S[#S+1] = Service: format (s)
      local implemented_actions = srv.actions
      for _,act in spairs ((loader.service_data[s] or {}).actions or {}) do
        local name = act.name
        local star = implemented_actions[name] and '*' or ''
        S[#S+1] = Action: format (p.DeviceNum, s, name, star, name)
      end
    end
    body = table.concat (S, '\n')
  else
    -- Devices and Scenes
    for n,d in spairs(luup.devices) do
      D[#D+1] = Device:format (n, n, d.description)
    end
    
    local S = {}
    for n,s in spairs(luup.scenes) do
      S[#S+1] = Scene:format (hag, n, n, s.description)
    end
    
    body = table.concat {table.concat (D, '\n'), "<br>Scenes:<br>", table.concat (S, '\n')}
  end
  return html: format (body)
end


-- actions   (thanks to @rigpapa for pointing this out to me)
-- This returns all the XML with all the UPNP device description documents. 
-- Use: http://ip_address:3480/data_request?id=device&output_format=xml&DeviceNum=x 
-- [or &UDN=y -- NOT implemented] to narrow it down.
local function actions (_, p)
  local S = {}
  
  local dev = luup.devices[tonumber(p.DeviceNum)]
  if not dev then 
    return "BAD_DEVICE", "text/plain"
  end
  
  for s, srv in spairs (dev.services) do
    local A = {}
    S[#S+1] = {serviceId = s, actionList = A}
--      local implemented_actions = srv.actions
    for _,act in spairs ((loader.service_data[s] or {}).actions or {}) do
      local args = {}
      for i,arg in ipairs (act.argumentList or {}) do
          args[i] = {name = arg.name, dataType = arg.dataType}    -- TODO: dataType not in arg?
      end
--        local star = implemented_actions[name] and '*' or ''
      A[#A+1] = {name = act.name, arguments = args}
    end
  end
  
  local j, err = json.encode {serviceList = S}
  j = j or {error = err or "unknown error"}
  return j, "application/json"
end


-- Returns the recent IP requests in order by most recent first, [ACTUALLY, IT'S NOT ORDERED]
-- including information about devices in use and if the IP is blacklisted (ignored by the plug and play mechanism).  [NOT IMPLEMENTED] 
-- Optionally append timeout to specify the oldest IP request in seconds.  [NOT IMPLEMENTED]
local function iprequests () 
  local ips = json.encode({ip_requests = iprequests_table ()})
  return ips, "application/json" 
end

--
-- SDATA
--

local function sdata_devices_table (devices)
  local dev = {}
  for i,d in pairs (devices or luup.devices) do
    if not d.invisible then
      local info = {
        name = d.description,
        altid = d.id,
        id = i,
        category = d.category_num,
        subcategory = d.subcategory_num,
        room = d.room_num,
        parent = d.device_num_parent,
        state = d:status_get() or -1,             -- 2018.04.05 sdata: reflect true state from job status
      }
      -- add the additional information from short_code variables indexed in the service_data
      local sd = loader.service_data
      for svc, s in pairs (d.services) do
        local known_service = sd[svc]
        if known_service then
          for var, v in pairs(s.variables) do
            local short = known_service.short_codes[var]
            if short then info[short] = v.value end
          end
        end
      end
      dev[#dev+1] = info
    end
  end
  return dev
end

local function sdata_scenes_table ()
  local info = {}
  for id, s in pairs (luup.scenes) do    -- TODO: actually, should only return changed ones
    local running = s.running
    info[#info + 1] = {
      id = id,
      room = s.room_num,
      name = s.description,
      active = running and "1" or "0",
      state  = running and 4 or -1,
    }
  end
  return info
end

-- This is an abbreviated form of user_data and status (sdata = summary data). 
-- It allows a user interface that is only worried about control, and not detailed configuration, 
-- to get a summary of the data that would normally be presented to the user and to monitor the changes.
-- http://VeraIP:3480/data_request?id=sdata&output_format=json
local function sdata(...)
  local sdata = {
    categories = categories_table (),
    dataversion = devutil.dataversion.value,
    devices = sdata_devices_table (),
    full = 1,       -- TODO: make full=0 for partial updates
    loadtime = timers.loadtime,
    mode = tonumber(luup.attr_get "Mode"),
    rooms = rooms_table(),
    scenes = sdata_scenes_table(),
    serial_number = tostring (luup.pk_accesspoint),
    sections = sections_table(),
    state = -1,
    temperature = luup.attr_get "TemperatureFormat",
    version = luup.attr_get "BuildVersion",
  }
  return json.encode (sdata) or 'error in sdata', "application/json"
end 
--
-- STATUS
--

local function status_devices_table (device_list, data_version)
  local info 
  local dv = data_version or 0
--  local dev_dv
  for i,d in pairs (device_list) do 
--    dev_dv = d:version_get() or 0
    if d:version_get() > dv then
      info = info or {}         -- create table if not present
      local states = {}
      for serviceId, srv in pairs(d.services) do
        for name,item in pairs(srv.variables) do
--          local ver = item.version
--          if item.version > dv then
          do
            states[#states+1] = {
              id = item.id, 
              service = serviceId,
              variable = name,
              value = item.value,
            }
          end
        end
      end
      -- The lu_status URL will show for the device: <tooltip display="1" tag2="Lua Failure"/>
      local status = {
        id = i, 
        status = d:status_get() or -1,      -- 2016.04.29
        tooltip = {display = "0"},
        Jobs = d.jobs or {},                -- 2018.04.03
        PendingJobs = 0, 
        states = states
      }
      info[#info+1] = status
    end
  end
  return info
end

local function status_scenes_table ()
  local info = {}
  for id, s in pairs (luup.scenes) do    -- TODO: actually, should only return changed scenes ?
    local running = s.running
    info[#info + 1] = {
      id = id,
      Jobs = s.jobs or {},
      active = running,
      status = running and 4 or -1,
    }

    -- DEBUG
    --luup.log("SCENE TABLES")

    -- Continuous scene status mode fix (ex. Vera feature (webUI v5))
    local shared = require "openLuup.shared"
    local custom_rules = require "openLuup.scene_status_rules"
    local knownschm = shared.known_action_schemes
    if s.status_mode == "continuous" then

      -- DEBUG
      --luup.log("SCENE STATUS MODE - CONTINUOUS")

      info[#info].active = true
      info[#info].status = 4
      for groupidx, group in pairs(s.groups or {}) do
        for actidx, actinfo in pairs(group.actions or {}) do

          local actname = actinfo.action
          local actserv = actinfo.service
          local actdev = tonumber(actinfo.device)

          -- Action is in rule_overrides list
          if actserv
          and custom_rules[actserv]
          and actname
          and type(custom_rules[actserv][actname]) == "function"
          then
            local is_active = custom_rules[actserv][actname](actinfo)
            if not is_active then
              info[#info].active = false
              info[#info].status = -1

              -- DEBUG
              --luup.log(string.format("SCENECONTSTATUSDBG OVERRIDEST_TRUE %s %s (dev. %s)",
              --    tostring(actserv),
              --    tostring(actname),
              --    tostring(actdev)
              --))

            else

              -- DEBUG
              --luup.log(string.format("SCENECONTSTATUSDBG OVERRIDEST_FALSE %s %s (dev. %s)",
              --    tostring(actserv),
              --    tostring(actname),
              --    tostring(actdev)
              --))
            end

          -- No rule overrides found. Try to check state vars from S_*.xml file
          else

            -- DEBUG
            --luup.log(string.format("SCENECONTSTATUSDBG NOOVERRIDES %s %s (dev. %s)",
            --    tostring(actserv),
            --    tostring(actname),
            --    tostring(actdev)
            --))

            if not next(actinfo.arguments) then

              info[#info].active = false
              info[#info].status = 2
            --  luup.log(string.format("SCENECONTSTATUSWARN ENOPROCNOARGS"
            --      .." scene #%s "
            --      .."service=\"%s\", action=\"%s\", device=%s",
            --      tostring(id),
            --      tostring(actserv),
            --      tostring(actname),
            --      tostring(actdev)
            --  ))

            else

              for argidx, arginfo in pairs(actinfo.arguments or {}) do

                local argname = arginfo.name
                local argexpval = arginfo.value -- expected value

                -- Is argument in known_action_schemes (out state vars
                -- from S_*.xml file)
                if actserv
                and knownschm[actserv]
                and actname
                and knownschm[actserv][actname]
                and argname
                and knownschm[actserv][actname][argname]
                and actdev
                and luup.devices[actdev]
                then
                  local argstatevarname = knownschm[actserv][actname][argname]
                  local curval = luup.variable_get(actserv, argstatevarname, actdev)
                  if curval ~= nil and curval ~= argexpval then

                    -- DEBUG
                    luup.log(
                          "DEBUG: scene is not active: \""
                        ..tostring(curval)
                        .."\" != \""
                        ..tostring(argexpval)
                        .."\""
                    )

                    info[#info].active = false
                    info[#info].status = -1
                  end

                -- Not enough information or no device
                else
                  info[#info].active = false
                  info[#info].status = 2
                  luup.log(string.format("SCENECONTSTATUSWARN ENOINFODEV"
                      .." scene #%s "
                      .."service=\"%s\", action=\"%s\", device=%s",
                      tostring(id),
                      tostring(actserv),
                      tostring(actname),
                      tostring(actdev)
                  ))
                end
              end
            end
          end
        end
      end
    end    

  end
  return info
end

-- TODO: job messages

--[[
"startup": {
"tasks": [
{
"id": 0,
"status": 2,
"type": "GET_LANG(system_error,System error)",
"comments": "Device: 149. Fail to load implementation file D_InsecurityCamera1.xml"
}
]
}, 
--]]
local function status_startup_table ()
  local tasks = {}
  local startup = {tasks = tasks}
  for id, job in pairs (scheduler.startup_list) do
    if job.status ~= scheduler.state.Done then
      tasks[#tasks + 1] = {
        id = id,
        status = job.status,
        type = job.type or ("device_no_" .. (job.devNo or '(system)')), 
        comments = job.notes,
      }
    end
  end
  return startup
end

-- This returns the current status for all devices including all the current UPnP variables and the status of any active jobs. 
-- http://172.16.42.14:3480/data_request?id=status&DeviceNum=47
local function status (_,p)
  local status = {                                -- basic top level attributes
    alerts = {},
    TimeStamp = os.time(),
    Mode = tonumber(luup.attr_get "Mode"),       
    LoadTime = timers.loadtime,
    DataVersion = devutil.dataversion.value,
    UserData_DataVersion = devutil.userdata_dataversion.value 
  }
  local d = os.date "*t"
  local x = os.date ("%Y-%m-%d %H:%M:%S")   -- LocalTime = "2015-07-26 14:23:50 D" (daylight savings)
  status.LocalTime = (x .. (({[true] = " D"})[d.isdst] or ''))
  local dv = tonumber(p.DataVersion)
  local device_list = luup.devices
  local DeviceNum = tonumber(p.DeviceNum)
  if DeviceNum then                                     -- specific device
    if not luup.devices[DeviceNum] then return "Bad Device" end
    device_list = {[DeviceNum] = luup.devices[DeviceNum]} 
  else                                                  -- ALL devices
  end
  local info = status_devices_table (device_list, dv)
  if DeviceNum then 
--        (info[1].id or _) = nil    
    status["Device_Num_"..DeviceNum] = (info or {})[1]
  else 
    status.devices = info
    status.startup = {tasks = {}}
    status.scenes  = status_scenes_table ()
    status.startup = status_startup_table () 
  end
  --TODO: status.visible_devices = ?
  return json.encode (status) or 'error in status', "application/json"
end

--
-- USER_DATA
--

local category_filter = {
  {
    Label = {
      lang_tag = "ui7_all",
      text = "All"},
    categories = {},
    id = 1},
  {
    Label = {
      lang_tag = "ui7_av_devices",
      text = "Audio/Video"},
    categories = {"15"},
    id = 2},
  {
    Label = {
      lang_tag = "ui7_lights",
      text = "Lights"},
    categories = {"2","3"},
    id = 3},
  {
    Label = {
      lang_tag = "ui7_cameras",
      text = "Cameras"},
    categories = {"6"},
    id = 4},
  {
    Label = {
      lang_tag = "ui7_door_locks",
      text = "Door locks"},
    categories = {"7"},
    id = 5},
  {
    Label = {
      lang_tag = "ui7_sensors",
      text = "Sensors"},
    categories = {"4","12","16","17","18"},
    id = 6},
  {
    Label = {
      lang_tag = "ui7_thermostats",
      text = "Thermostats"},
    categories = {"5"},
    id = 7}
}


local function user_scenes_table()
  local scenes = {}
  for _,sc in pairs (luup.scenes) do
    scenes[#scenes+1] = sc.user_table()
  end
  return scenes
end

-- This returns the configuration data for Vera, 
-- which is a list of all devices and the UPnP variables which are persisted between resets
-- as well as rooms, names, and other data the user sets as part of the configuration.
local function user_data (_,p) 
  local result = "NO_CHANGES"
  local mime_type = "text/plain"
  local dv = tonumber(p.DataVersion)
  local distance = math.abs (devutil.dataversion.value - (dv or 0))
  if not dv 
  or (dv < devutil.dataversion.value) 
  or distance > 1000        -- ignore silly values
  then 
    local user_data2 = {
      LoadTime = timers.loadtime,
      DataVersion = devutil.userdata_dataversion.value, -- NB: NOT the same as the status DataVersion
      InstalledPlugins2 = userdata.attributes.InstalledPlugins2,
      category_filter = category_filter,
      devices = userdata.devices_table (luup.devices),
      ip_requests = iprequests_table(),
      rooms = rooms_table(),
      scenes = user_scenes_table(),
      sections = sections_table(),
    }
    for a,b in pairs (userdata.attributes) do      -- add all the top-level attributes
      user_data2[a] = b
    end
    if p.ns ~= '1' then     -- 2018.01.29
      user_data2.static_data = static_data()
    end
    mime_type = "application/json"
    result = json.encode (user_data2)
  end
  return result, mime_type
end

-- This returns the static data only (undocumented, but used in UI5 JavaScript code)
-- see: http://forum.micasaverde.com/index.php/topic,35904.0.html
local function static ()
  local sd = {
    category_filter = category_filter,
    static_data = static_data(),
  }
  local mime_type = "application/json"
  local result = json.encode (sd)
  return result, mime_type
end

-- room
--
--Example: http://ip_address:3480/data_request?id=room&action=create&name=Kitchen
--Example: http://ip_address:3480/data_request?id=room&action=rename&room=5&name=Garage
--Example: http://ip_address:3480/data_request?id=room&action=delete&room=5

--This creates, renames, or deletes a room depending on the action. 
--To rename or delete a room you must pass the room id for the with room=N.
--
local function room (_,p)
  local name = (p.name ~= '') and p.name
  local number = tonumber (p.room)

  -- 2018.03.24  use luup.rooms metatable methods
  local function create () luup.rooms.create (name) end
  local function rename () luup.rooms.rename (number, name) end
  local function delete () luup.rooms.delete (number) end
  local function noop () end

  do -- room ()
    local valid = {create = create, rename = rename, delete = delete};
    (valid[p.action or ''] or noop) ()
    devutil.new_userdata_dataversion ()     -- say something major has changed
  end
  return "OK"       -- seems not to be specific about errors!
end

--[[

SCENES

When using the 'create' command json must be valid JSON for a scene as documented in Scene_Syntax. 
The name, room and optional id (if you're overwriting an existing scene) are passed in the json, so nothing is on the command line except the json. 

Because the json data can be long it is recommended to send it as an http POST instead of GET with the data passed with the name "json" 

list returns the JSON data for an existing scene. 

Example: http://ip_address:3480/data_request?id=scene&action=rename&scene=5&name=Chandalier&room=Garage
Example: http://ip_address:3480/data_request?id=scene&action=delete&scene=5
Example: http://ip_address:3480/data_request?id=scene&action=create&json=[valid json data]
Example: http://ip_address:3480/data_request?id=scene&action=list&scene=5

--]]

local function scene (_,p)  
  local name = (p.name ~= '') and p.name
  local room = (p.room ~= '') and p.room
  local number = tonumber (p.scene)
  local response
  --Example: http://ip_address:3480/data_request?id=scene&action=delete&scene=5
  local function delete (scene) 
    if scene then 
      scene:stop()                             -- stop scene triggers and timers
      luup.scenes[scene.user_table().id] = nil -- remove reference to the scene
    end
  end
  --Example: http://ip_address:3480/data_request?id=scene&action=create&json=[valid json data]
  local function create () 
    local new_scene, msg = scenes.create (p.json)
    if new_scene then
      local id = new_scene.user_table().id
      if luup.scenes[id] then
        delete (luup.scenes[id])               -- remove the old scene with this id
      end
      luup.scenes[id] = new_scene              -- slot into scenes table
    end
    return msg    -- nil if all OK
  end
  --Example: http://ip_address:3480/data_request?id=scene&action=rename&scene=5&name=Chandelier&room=Garage
  local function rename (scene) 
    local new_room_num
    if room then
      local room_index = {}
      for i, name in pairs (luup.rooms) do room_index[name] = i end
      new_room_num = room_index[room]
    end
    if scene then scene.rename (name, new_room_num) end
  end
  --Example: http://ip_address:3480/data_request?id=scene&action=list&scene=5
  local function list (scene)
    if scene and scene.user_table then
      return json.encode (scene.user_table()) or "ERROR"
    end
    return "ERROR"
  end
  local function noop () return "ERROR" end

  do -- scene ()
    local valid = {create = create, rename = rename, delete = delete, list = list}
    response = (valid[p.action or ''] or noop) (luup.scenes[number or ''])
    if p.action ~= "list" then devutil.new_userdata_dataversion () end  -- say something major has changed
  end
  return response or "OK"
end

-- http://ip_address:3480/data_request?id=variableset&DeviceNum=6&serviceId=urn:micasaverde-com:serviceId:DoorLock1&Variable=Status&Value=1
-- If you leave off the DeviceNum and serviceID, then this sets a top-level json tag called "Variable" with the value.
local function variableset (_,p)
  local devNo = tonumber (p.DeviceNum) or 0
--  if devNo == 0 and not p.serviceId and p.Variable then
  if (not p.serviceId) and p.Variable then
    luup.attr_set (p.Variable, p.Value, devNo)
  else
    luup.variable_set (p.serviceId, p.Variable, p.Value or '', devNo) 
  end
  return "OK"
end

-- http://ip_address:3480/data_request?id=variableget&DeviceNum=6&serviceId=urn:micasaverde-com:serviceId:DoorLock1&Variable=Status
-- If you leave off the DeviceNum and serviceId, then this gets a top-level json tag called "Variable".
local function variableget (_,p)
  local result
  local devNo = tonumber (p.DeviceNum) or 0
  if devNo == 0 and p.Variable then
    result = tostring (userdata.attributes[p.Variable])
  else
    result = luup.variable_get (p.serviceId, p.Variable, devNo) 
  end
  return result
end

-- reports the current energy usage in a tab delimited format. 
local function live_energy_usage ()
  local live_energy_usage = {}
  local sid = "urn:micasaverde-com:serviceId:EnergyMetering1"
  local fmt = "%d\t%s\t%s\t%d\t%d"
  for devNo, dev in pairs (luup.devices) do
    local svc = dev.services[sid]
    if svc then
      local Watts = svc.variables.Watts 
      if Watts and tonumber (Watts.value)then       -- 2017.01.10 thanks @reneboer
        local room = luup.rooms[dev.room_num or 0] or ''
        local line = fmt: format (devNo, dev.description, room, dev.category_num, Watts.value)
        live_energy_usage[#live_energy_usage+1] = line
      end
    end
  end 
  return table.concat (live_energy_usage, '\n')
end

-- eg:  /data_request?id=action&output_format=json&DeviceNum=0&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=SetHouseMode&Mode=2
-- with response:
--{"u:SetHouseModeResponse": {"OK": "OK"}}

local function action (_,p,f)
  -- notice that the argument list is the full HTTP query including DeviceNum, serviceId, and action
  local error, error_msg, _, arguments = luup.call_action (p.serviceId, p.action, p, tonumber(p.DeviceNum))
  local result, mime_type = '', "text/plain"
  if error ~= 0 then
    if error == -1 then error_msg = "Device does not handle service/action" end
    result = "ERROR: " .. (error_msg or error or '?')
  else
    arguments = arguments or {}
    arguments.OK = "OK"
    result = {["u:"..p.action.."Response"] = arguments}
    if f == "json" then
      result = json.encode (result)
      mime_type = "application/json"
    else
      result = xml.encode (result)
      result = result: gsub ("^(%s*<u:[%w_]+)", '<?xml version="1.0"?>\n%1 xmlns:u="' .. (p.serviceId or "UnknownService") .. '"')
      mime_type = "application/xml"
    end
  end
  return result, mime_type
end

-- jobstatus
-- Returns the status of a job. 
-- The parameters are job, which is the job ID and optionally plugin, which is the plugin name. 
-- For a Z-Wave job the plugin parameter must be zwave. [NOT IMPLEMENTED]
-- If job is invalid the status returned is -1.

local function jobstatus ()
  error "NOT YET IMPLEMENTED: jobstatus"
end

--
-- CAMERA
--
--[[
 request_image

Returns an image from a camera. This fetches the image from the camera using the URL variable for the device. Pass arguments:

cam = the device id of the camera.  This is the only mandatory argument.
res = optional: a resolution, which gets appended to the variable.  
      So passing "low" means the image from the URL_low variable will be returned.
      If it doesn't exist it reverts to the standard URL or DirectStreamingURL
timeout = optional: how long to wait for the image to be retrieved, 
      or how long to retrieve video. defaults to 10 seconds.
url = optional: override the camera's default URL
ip = optional: override the camera's default ip
user or pass = optional: override the camera's default username/password

--]]

local function request_image (_, p)
  for a,b in pairs (p) do p[a:lower()] = b end    -- wrap parameters to lowercase, so no confusions
  local sid = "urn:micasaverde-com:serviceId:Camera1"
  local image, status
  local devNo = tonumber(p.cam)
  local cam = luup.devices[devNo]
  local response
  
  if cam then
    local url = p.url or luup.variable_get (sid, "URL", devNo) or ''
    local ip = p.ip or luup.attr_get ("ip", devNo) or ''
    local protocol = p.protocol or luup.variable_get (sid, "Protocol", devNo) or ''
    
    -- note, once again, the glaring inconsistencies in Vera naming conventions
    local user = p.user or luup.attr_get ("username", devNo) or luup.variable_get (sid, "username", devNo) 
    local pass = p.pass or luup.attr_get ("password", devNo) or luup.variable_get (sid, "password", devNo)
    local timeout = tonumber(p.timeout) or 10
    
    if url then
  if protocol == "http" then
    _, image, status = luup.inet.wget ("http://"..ip..url, timeout, user, pass)
                --_, image, status = http.wget ("http://"..ip..url, timeout, user, pass)
    _log ("Image Request User" .. user)
  end
  if protocol == "https" then
    _, image, status = luup.inet.wget ("https://"..ip..url, timeout, user, pass)
                --_, image, status = http.wget ("https://"..ip..url, timeout, user, pass)
    _log ("Image Request User" .. user)
  end
  
      if status ~= 200 then
        response = "camera URL returned HTTP status: " .. status
        image = nil
      end
    end
  else
    response = "No such device"   -- TODO: return image of this message
  end
  
  if image then
    return image, "image/jpeg"
  else
    return response or "Unknown ERROR"
  end
end

--[[
archive_video

Archives a MJPEG video or a JPEG snapshot. [NB: only snapshot implemented in openLuup]

Parameters:

    cam: the device # of the camera.
    duration: the duration, in seconds, of the video. The default value is 60 seconds.
    format: set it to 1 for snapshots. If this is missing or has any other value, 
              the archive will be a MJPEG video. 

--]]
local function archive_video (_, p)       -- 2018.04.09
  local response
  for a,b in pairs (p) do p[a:lower()] = b end    -- wrap parameters to lowercase, so no confusions
  
  if p.format == "1" then 
    if p.cam then
      local image, contentType = request_image (_, {cam = p.cam})
      if contentType == "image/jpeg" then
        local filename = os.date "%Y%m%d-%H%M%S-snapshot.jpg"
        local f,err = io.open ("images/" .. filename, 'wb')
        image = image or "---no image---"
        if f then
          f: write (image)
          f: close ()
          local msg = "ArchiveVideo: Format=%s, Duration=%s, %d bytes written to %s"
          response = msg:format (p.format or '?', p.duration or '', #image, filename)
        else
          response = "ERROR writing image file: " .. (err or '?')
        end
      else
        response = "ERROR getting image: " .. (image or '?')
      end
    else
      response = "no such device"
    end
  else
    response = "Video Archive NOT IMPLEMENTED (only snapshots)" 
  end
  
  _log (response)
  return response
end

--[[
---------------------------------------------------------

PLUGIN UPDATES: THINGS TO KNOW:

From the Plugins page, AltUI issues two types of requests 
depending on whether or not anything is entered into the Update box:

empty request to openLuup:

/data_request?id=update_plugin&Plugin=openLuup

entry of "v0.8.2" to VeraBridge update box:

/data_request?id=action&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=CreatePlugin&PluginNum=VeraBridge&Version=v0.8.2

... NOTE: the difference between the parameter names specifying the Plugin!!

Because the MiOS plugin store Version has nothing to do with AltUI build versions, @amg0 tags GitHub releases and passes these to openLuup when a browser refresh plugin update is initiated:

This, for example, is an update request from AltUI after a browser refresh discovers there's a new version

/data_request?id=action&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=CreatePlugin&PluginNum=8246&Version=31806&TracRev=1788

---------------------------------------------------------
--]]

--
-- update_plugin ()
-- This is a genuine Vera-style request for an update
-- originated from the Update button of the plugins page
-- the TracRev parameter (pre-GitHub!) is used by AltUI to override the MiOS Version number 
local function update_plugin (_,p) 
  
  local Plugin = p.PluginNum or p.Plugin
  local tag = p.TracRev or p.Version          -- pecking order for parameter names
  local meta, errmsg = userdata.plugin_metadata (Plugin, tag)
    
  if meta then
    local sid = "urn:upnp-org:serviceId:AltAppStore1"
    local act = "update_plugin"
    local arg = {metadata = json.encode (meta)}
    local dev = device_present "urn:schemas-upnp-org:device:AltAppStore:1"
    
    -- check for pre-install device-specific configuration, failure means do NOT install
    local status
    status, errmsg = luup.call_action ("openLuup", "plugin_configuration", meta, 2) 
    
    if status == 0 then
      _, errmsg = luup.call_action (sid, act, arg, dev)       -- actual install
      
      -- NOTE: that the above action executes asynchronously and the function call
      --       returns immediately, so you CAN'T do a luup.reload() here !!
      --       (it's done at the end of the <job> part of the called action)
    end
  end
  
  if errmsg then _log (errmsg) end
  return errmsg or "OK", "text/plain" 
end

-- delete_plugin ()
local function delete_plugin (_, p)
  local Plugin = p.PluginNum  or '?'
  local IP, idx = userdata.find_installed_data (Plugin)
  if idx then
    local device_type = IP.Devices[1].DeviceType                -- assume it's there!
    table.remove (userdata.attributes.InstalledPlugins2, idx)   -- move all the higher indices down, also
    _log ("removing plugin devices of type: " .. (device_type or '?'))
    for devNo, d in pairs (luup.devices) do                     -- remove associated devices....
      if (d.device_type == device_type) 
      and (d.device_num_parent == 0) then     -- local device of correct type...
        _log ("delete device #" .. devNo)
        local msg = device (_, {action="delete", device=devNo}) -- call device action in this module
        _log (msg or ("Plugin removed: " .. devNo))
      end
    end
    _log ("Plugin_removed: " .. Plugin)
  end
  return "No such plugin: " .. Plugin, "text/plain"
end

--[[
 request_streaming

Returns an video from a camera as image which reloads periodically.
Arguments:
cam = the device id of the camera.  This is the only mandatory argument.
TODO STRICT TIMEOUTS
--]]

local req_streaming_listen_sock = nil
local req_streaming_daemon_socks = {}

local function request_streaming (_, p)

  -- Check dependencies
  if not posix then
    _log("request_streaming(): *** \"lua-posix\" module required."
        .." Please, install it in your system. ***")
    return "MODULE MISSED"
  end

  local sid = "urn:micasaverde-com:serviceId:Camera1"

  local function str_escape(str) -- unused
    if type(str) ~= "string" then
      return nil
    end
    return table.concat({string.byte(str, 1, -1)}, ",")
  end

  -- Check arguments
  local devNo = tonumber(p.cam)
  if not devNo then
    return "ERROR (device No# not number)", "text/plain"
  end
  local cam = luup.devices[devNo]
  if not cam then
    return "ERROR (no device)", "text/plain"
  end

  -- Get IP configuration util
  -- Tries to extract ip:port from address
  -- passed as 1st argument.
  -- Resets camip, camport if error.
  local camip, camport
  local function extract_addr(camaddr)
    if camaddr and not camip then
      camip, camport = string.match(camaddr, "([^:]+):(%d+)")
      if not tonumber(camport) then -- Port error. decline
        camip = nil
      end
      if not camip then           -- No port specified
        camip = camaddr
        camport = 80
      else                      -- All ok
        camport = tonumber(camport)
      end
    end
  end
  -- Priority: first is most important
  -- If first is found, others will be ignored
  extract_addr(p.ip)
  extract_addr(luup.variable_get(sid, "IP", devNo))
  extract_addr(luup.attr_get("ip", devNo))

  -- Get other configuration variables
  local imgurl         = luup.variable_get(sid, "URL", devNo)
  local streamingurl   = luup.variable_get(sid, "DirectStreamingURL",
                                                            devNo)
  local camusername    = luup.variable_get(sid, "username", devNo)
  local campassword    = luup.variable_get(sid, "password", devNo)
  local camprotocol    = luup.variable_get(sid, "Protocol", devNo)
  local timeout        = luup.variable_get(sid, "Timeout",  devNo)
  local myIP           = http.myIP

  -- Timeout control tools
  timeout = tonumber(timeout) or DEFAULT_REQUEST_STREAMING_TIMEOUT
  local starttime = socket.gettime()
  local function is_timeout()
    local curtime = socket.gettime()
    local timeelapsed = curtime - starttime
    local timeleft = timeout - timeelapsed
    if timeelapsed >= timeout then
      local timeelapsed
      return true, timeelapsed, timeleft
    else
      return false, timeelapsed, timeleft
    end
  end

  -- DEBUG
  local function printcfg()
    print("camip", camip)
    print("camport", camport)
    print("streamurl", streamingurl)
    print("camusername", camusername)
    print("campassword", campassword)
    print("camprotocol", camprotocol)
  end

  -- DEBUG
  --print("CFG received ------------")
  --printcfg()

  -- Check mandatory arguments
  if (not camip or camip == "")
  or (not camport)
  or (not streamingurl or streamingurl == "")
  or (not camprotocol or
          (camprotocol ~= "http" and camprotocol ~= "https"))
  then
    _log("request_streaming(): Unsupported device configuration")
    return "UNSUPPORTED DEVICE CONFIGURATION"
  end

  -- Main logic ---------

  local pid = posix.fork()
  local client_sock, server_listen_sock
  local cam_sock, cam_ssl_sock

  if pid == -1 then
    return "fork() ERROR"
  end

  if pid == 0 then
    -- Video streaming thread:
    -- Server socket should be closed because
    -- openLuup reloading/restarting will be
    -- impossible until video transmission ends.
    server_listen_sock = shared.get_current_server_sock()
    -- Should work. But not works. I guess
    -- problem is in the lua-socket.
    -- But maybe in me.
    -- reload() request will kill all childrens
    -- before openLuup reload because of this.
    --server_listen_sock:close() -- XXX
    client_sock = shared.get_current_client_sock()

    if not http.close_all_sockets_except_client(client_sock) then
      os.exit(1)
    end
  else
    -- Server:
    -- This connection should be unavailable for
    -- server to avoid data corrupting.
    client_sock = http.get_current_client_sock()
    http.close_client_socket(client_sock)
    client_sock:close()
    luup.child_processes[pid] = true
    _log(string.format("request_streaming():"
        .." forked to PID %s", tostring(pid)))
    -- Return control to server's main loop
    return nil
  end

  -- Video streaming thread: -----

  -- Generate authorization header
  local auth_header = string.format("Authorization: Basic %s",
      mime.b64(camusername..":"..campassword))
  -- Generate GET
  local get_req_1st_str = string.format("GET %s HTTP/1.1", streamingurl)

  -- Build request
  local HTTP_REQUEST = table.concat({
    get_req_1st_str,
    "Host: "..tostring(camip),
    auth_header,
    "",
    "",
  }, "\r\n")

  local function connect_to_camera()

    local sock, sslsock

    -- Create sock
    sock = socket.tcp()
    if not sock then
      print("connect_to_camera(): cannot create tcp socket")
      os.exit(1)
    end

    -- Connect to host
    local connected = false
    local ok, descr = sock:connect(camip, tonumber(camport))
    if ok then
      connected = true
    else
      print("connect_to_camera(): cannot connect to host: "..tostring(descr))
      sock:close()
    end

    -- SSL wrap
    if camprotocol == "https" then

      sslsock, descr = ssl.wrap(sock, {
        mode = "client",
        protocol = "tlsv1_2",
        --verify = { "peer", "fail_if_no_peer_cert" },
        verify = "none",
        options = "all",
      })

      if not sslsock then
        print("connect_to_camera(): cannot wrap socket by ssl: "..tostring(descr))
        sock:close()
        os.exit(45)
      end

      local ok, descr = sslsock:dohandshake()
      if not ok then
        print("connect_to_camera(): cannot do ssl handshake: "..tostring(descr))
        sslsock:close()
        connected = false
      end
    end

    if connected then
      cam_sock = sock
      cam_ssl_sock = sslsock
      return true
    else
      return false
    end
  end

  local function send_request_to_camera()
    local sock = cam_ssl_sock or cam_sock
    sock:settimeout(timeout)
    local ok, descr = sock:send(HTTP_REQUEST)
    if not ok then
      print("Cannot send HTTP request to camera:", descr)
      os.exit(1)
    end
    return true
  end

  local function transfer_part_of_video_to_client()
    local sock = cam_ssl_sock or cam_sock
    local data, descr, datapart = sock:receive("*a")
    if not data
    and descr == "timeout"
    or descr == "wantread" then
      data = datapart
    else
      print("Video thread: Cannot receive part of data from camera:", descr)
      os.exit(1)
    end

    local ok, descr = client_sock:send(data)
    if not ok then
      print("Video thread: Cannot send part of data to client:", descr)
      os.exit(1)
    end
    return true
  end

  connect_to_camera()
  send_request_to_camera()

  cam_sock:settimeout(CAM_RECV_FRAME_TIMEOUT)
  if cam_ssl_sock then
    cam_ssl_sock:settimeout(CAM_RECV_FRAME_TIMEOUT)
  end
  client_sock:settimeout()

  -- Video thread main loop
  while true do
    transfer_part_of_video_to_client()
  end

  os.exit(0)
end

local function change_scene_mode (_, p)
  local mode_name = p.ModeName;
  local scene_id = tonumber(p.SceneID);
  if not mode_name or not scene_id then
    return "ERROR_ARG"
  end
  if mode_name ~= "continuous"
  and mode_name ~= "normal"
  then
    return "ERROR_MODE_IS_NOT_SUPPORTED"
  end
  if not luup.scenes[scene_id] then
    return "ERROR_NO_SUCH_SCENE"
  end
  luup.scenes[scene_id].status_mode = mode_name;
  luup.scenes[scene_id].scene_private_data.status_mode = mode_name;
  return "OK"
end

--
-- Miscellaneous
--

--  TODO: add &id=lua&DeviceNum=xxx request
local function lua ()    -- 2018.04.22 
  local lines = {}
  local function pr (x) lines[#lines+1] = x end
  
  pr "--Devices with UPNP implementations:"

  -- implementation files
  local ignore = {['']=1,X=1}
  for i in pairs (luup.devices) do
      local impl = luup.attr_get ("impl_file", i)
      if impl and not ignore [impl] then pr ("-lu_lua&DeviceNum=" ..i) end
  end

  pr "\n\n--GLOBAL LUA CODE:"

  -- scenes
  for i,s in pairs (luup.scenes) do
      local lua = s:user_table().lua
      if #lua > 0 then
          pr ("function scene_" .. i .. "()")
          pr (lua)
          pr "end"
      end
  end
  -- startup code
  local glc = luup.attr_get "StartupCode"

  pr(glc)
  return table.concat (lines, '\n')
end

-- return OK if the engine is running
local function alive () return "OK" end

-- file access
local function file (_,p) 
  local _,f = http.wget ("http://localhost:3480/" .. (p.parameters or '')) 
  return f 
end

-- reload openLuup
local function reload () luup.reload () end

--
-- openLuup additions
--
local function test (r,p)
  local d = {"data_request","id=" .. r}   -- 2017.11.08
  for a,b in pairs (p) do
    d[#d+1] = table.concat {a,'=',b}
  end
  return table.concat (d,'\n')
end

-- easy HTTP request to force a download of AltUI
local function altui (_,p) return update_plugin (_, {PluginNum = "8246", Version= p.Version}) end

-- easy HTTP request to force openLuup update (not used by AltUI)
local function update (_,p) return update_plugin (_, {PluginNum = "openLuup", Version = p.Version}) end

-- toggle debug flag (not yet used)
local function debug() luup.debugON = not luup.debugON; return "DEBUG = ".. tostring(luup.debugON) end

-- force openLuup final exit openLuup (to exit calling script reload loop)
local function exit () scheduler.stop() ; return ("requested openLuup exit at "..os.date()) end

--
-- INITIALISATION
--
-- export all Luup requests
--

local luup_requests = {
  
  action              = action, 
  actions             = actions,
  alive               = alive,
  archive_video       = archive_video,
  device              = device,
  delete_plugin       = delete_plugin,
  file                = file,
  iprequests          = iprequests,
  invoke              = invoke,
  jobstatus           = jobstatus,
  live_energy_usage   = live_energy_usage,
  lua                 = lua,
  reload              = reload,
  request_image       = request_image,
  request_streaming   = request_streaming,
  room                = room,
  scene               = scene,
  sdata               = sdata, 
  static              = static,
  status              = status, 
  status2             = status, 
  user_data           = user_data, 
  user_data2          = user_data,
  update_plugin       = update_plugin,      -- download latest plugin version
  variableget         = variableget, 
  variableset         = variableset,
  get_task_messages   = get_task_messages,  -- get last ~100 unread messages of luup.task() (json)
  change_scene_mode   = change_scene_mode,
  
  -- openLuup specials
  altui               = altui,              -- download AltUI version from GitHub
  debug               = debug,              -- toggle debug flag
  exit                = exit,               -- shutdown
  test                = test,               -- for testing!
  update              = update,             -- download openLuup version from GitHub
}

do -- CALLBACK HANDLERS
  -- Register lu_* style (ie. luup system, not luup user) callbacks with HTTP server
  local extendedList = {}
  for name, proc in pairs (luup_requests) do 
    extendedList[name]        = proc
    extendedList["lu_"..name] = proc              -- add compatibility with old-style call names
  end
  http.add_callback_handlers (extendedList)     -- tell the HTTP server to use these callbacks
end

luup_requests.ABOUT = ABOUT   -- add module info (NOT part of request list!)


return luup_requests

------------


