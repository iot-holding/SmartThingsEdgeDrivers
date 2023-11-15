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
local socket = require "cosock.socket"

--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type remotec-zxt-800.SimpleAVControl
local AVControl = (require "remotec-zxt-800.SimpleAVControl")({version = 4})
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultiLevel = (require "st.zwave.CommandClass.SensorMultilevel")({version = 2})
--- @type st.zwave.CommandClass.ThermostatFanMode
local ThermostatFanMode = (require "st.zwave.CommandClass.ThermostatFanMode")({ version = 3 })
--- @type st.zwave.CommandClass.ThermostatMode
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({ version = 2 })

local log = require "log"
local utils = require "st.utils"

local LAST_COMMAND = 'last_command'

local ENDPOINTS = {
  parent = 0,
  children = 3
}

local supported_modes = {
  capabilities.thermostatMode.thermostatMode.off.NAME,
  capabilities.thermostatMode.thermostatMode.heat.NAME,
  capabilities.thermostatMode.thermostatMode.cool.NAME,
  capabilities.thermostatMode.thermostatMode.auto.NAME,
  capabilities.thermostatMode.thermostatMode.resume.NAME,
  capabilities.thermostatMode.thermostatMode.fanonly.NAME,
  capabilities.thermostatMode.thermostatMode.dryair.NAME
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

local function info_changed(driver, device, event, args)
    preferencesMap.update_preferences(driver, device, args)
  end

local function simpleAVHandler(driver, device, event, args)
    log.debug("simpleAVHandler called!")
  log.debug(utils.stringify_table(event, "simpleAVHandler event", true))
  log.debug(utils.stringify_table(args, "simpleAVHandler args", true))
  end

local function find_child(parent, ep_id)
    if ep_id == ENDPOINTS.parent then
      return parent
    else
      return parent:get_child_by_parent_assigned_key(string.format("%02X", ep_id))
    end
  end

local function do_refresh(driver, device, command)
  local ep = command.args.end_point
  device:refresh()
  device:send(SensorMultiLevel:Get({}):to_endpoint(ep))
  device:send(ThermostatMode:SupportedGet({}):to_endpoint(ep))
  device:send(ThermostatFanMode:SupportedGet({}):to_endpoint(ep))
end

local function component_to_endpoint(device, component)
  return { ENDPOINTS.parent }
end

local function switch_handler_factory(av_key)
  return function (driver, device, command)
    local ep = command.args.end_point or 1
    local cmd = device:get_field(LAST_COMMAND) ~= 0x0027 and 0x0027 or 0x0024
    log.debug("cmd:", cmd)
    device:set_field(LAST_COMMAND, cmd)
    device:send(AVControl:Set({ key_attributes = 0, vg = {{command = cmd}}}))
    --device:send(AVControl:Get({}):to_endpoint(ep))
    device:send(AVControl:Get({}))
  end
end

local function create_child_devices(driver, device)
  for i = 1, ENDPOINTS.children do
    local name = string.format("%s %s", device.label, " - AV Control #" .. i)
    local metadata = {
        type = "EDGE_CHILD",
        label = name,
        profile = "remotec-zxt-800-child-fourtyone-buttons",
        parent_device_id = device.id,
        parent_assigned_child_key = string.format("%02X", i + 1),
        vendor_provided_label = name,
      }
      driver:try_create_device(metadata)
  end
end

local function device_added(driver, device, event)
  device:emit_event(capabilities.thermostatMode.supportedThermostatModes(supported_modes, { visibility = { displayed = false } }))
  if device.network_type == st_device.NETWORK_TYPE_ZWAVE and
    not (device.child_ids and utils.table_size(device.child_ids) ~= 0) then

    create_child_devices(driver, device)
    log.debug("Childs Created ... Set btn caps")
    -- Set Button Capabilities for scene switches
    if device:supports_capability_by_id(capabilities.button.ID) then
      log.debug("Setting button capabilities")
      for _, component in pairs(device.profile.components) do
        device:emit_component_event(component,
          capabilities.button.supportedButtonValues({ "pushed" }, { visibility = { displayed = false } }))
        if component.id == "main" then
          device:emit_component_event(component,
            capabilities.button.numberOfButtons({ value = 20 }, { visibility = { displayed = false } }))
        else
          device:emit_component_event(component,
            capabilities.button.numberOfButtons({ value = 1 }, { visibility = { displayed = false } }))
        end
        -- Without this time delay, the state of some buttons cannot be updated
        --socket.sleep(1)
      end
    end
  end
  do_refresh(driver, device)
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
    capability_handlers = {
        [capabilities.switch.ID] = {
          [capabilities.switch.commands.on.NAME] = switch_handler_factory(0x00), -- Power
          [capabilities.switch.commands.off.NAME] = switch_handler_factory(0x0D) -- Mute
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
