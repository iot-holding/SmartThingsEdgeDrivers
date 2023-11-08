-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local preferencesMap = require "remotec-zxt-800.preferences"
local st_device = require "st.device"
local capabilities = require "st.capabilities"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({version=1})
--- @type remotec-zxt-800.SimpleAVControl
local AVControl = (require "remotec-zxt-800.SimpleAVControl")({version=3})
local SensorMultiLevel = (require "st.zwave.CommandClass.SensorMultilevel")({version = 2})
local log = require "log"
local utils = require "st.utils"

local ENDPOINTS = {
  parent = 0,
  child = 1
}

local REMOTEC_FINGERPRINTS = {
    {mfr = 0x5254, prod = 0x0004, model = 0x8492}, -- Remotec ZXT 800
}
local function can_handle_remotec(opts, driver, device, ...)
    for _, fingerprint in ipairs(REMOTEC_FINGERPRINTS) do
        if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
            return true
        end
    end
  
    return false
  end


  local function component_to_endpoint(device, component)
    log.debug(ENDPOINTS)
    return { ENDPOINTS.parent }
end
local function info_changed(driver, device, event, args)
    preferencesMap.update_preferences(driver, device, args)
  end

local function simpleAVHandler(driver, device, event, args)
    log.debug("simpleAVHandler called!")
  end

local function find_child(parent, ep_id)
    if ep_id == ENDPOINTS.parent then
      return parent
    else
      return parent:get_child_by_parent_assigned_key(string.format("%02X", ep_id))
    end
  end

local function do_refresh(driver, device, command)
    local component = command and command.component and command.component or "main"
    device:send_to_component(SensorMultiLevel:Get({}), component)
    device:send(SensorMultilevel:Get({}))
    device:send(thermostatFanMode:Get({}))
    device:send(thermostatMode:Get({}))
  end

local function device_added(driver, device, event)
    if device.network_type == st_device.NETWORK_TYPE_ZWAVE and
      not (device.child_ids and utils.table_size(device.child_ids) ~= 0) and
      find_child(device, ENDPOINTS.child) == nil then
  
      local name = string.format("%s %s", device.label, "Sensors")
      local metadata = {
        type = "EDGE_CHILD",
        label = name,
        profile = "remotec-zxt-800-child",
        parent_device_id = device.id,
        parent_assigned_child_key = string.format("%02X", ENDPOINTS.child),
        vendor_provided_label = name,
      }
      driver:try_create_device(metadata)
    end
    
  end

local function device_init(driver, device, event)
    if device.network_type == st_device.NETWORK_TYPE_ZWAVE then
      device:set_find_child(find_child)
      device:set_component_to_endpoint_fn(component_to_endpoint)
    end
  end
local remotec_controller = {
    NAME = "remotec-zxt-800",
    zwave_handlers = {
        [cc.SIMPLE_AV_CONTROL] = {
          [AVControl.REPORT] = simpleAVHandler
        }
    },
    lifecycle_handlers = {
        init = device_init,
        added = device_added,
        infoChanged = info_changed

    },
    can_handle = can_handle_remotec
  }

return remotec_controller