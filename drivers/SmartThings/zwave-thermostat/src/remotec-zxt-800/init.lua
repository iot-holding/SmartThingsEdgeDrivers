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

local log = require "log"
local utils = require "st.utils"

local LAST_COMMAND = 'last_command'
local LAST_SEQUENCE = 'last_sequence'

local ENDPOINTS = {
  parent = 1,
  children = 1
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
  --local ep = command.src_channel
  device:refresh()
end
local function component_to_endpoint(device, component)
  return { ENDPOINTS.parent }
end

local function create_child_devices(driver, device)
  for i = 1, ENDPOINTS.children do
    local name = string.format("%s %s", "ZXT 800", "AV #" .. i)
    local metadata = {
        type = "EDGE_CHILD",
        label = name,
        profile = "remotec-zxt-800-child",
        parent_device_id = device.id,
        parent_assigned_child_key = string.format("%02X", i + 1),
        vendor_provided_label = name,
      }
      driver:try_create_device(metadata)
  end
end

local function device_added(driver, device, event)

  if device:is_cc_supported(cc.BATTERY) then
    log.debug("Battery supported")
    device:try_update_metadata({profile = "remotec-zxt-800-battery"})

    device.thread:call_with_delay(2,
      function()
        device:emit_event(capabilities.powerSource.powerSource.battery())
      end
    )
  else
    log.debug("Mains supported")
    device:emit_event(capabilities.powerSource.powerSource.mains())
  end

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
        socket.sleep(1)
      end
    end
  end
  do_refresh(driver, device)
  device:emit_event(capabilities.switch.switch.off())
end

local simple_av_handler = function(self, device, cmd)
  local KEY_MAP = {
    ["on"] = 0x0027,
    ["off"] = 0x0027,
    ["play"] = 0x0013,
    ["pause"] = 0x0015,
    ["stop"] = 0x0014,
    ["rewind"] = 0x0017,
    ["fastForward"] = 0x0016,
    ["channelDown"] = 0x0005,
    ["channelUp"] = 0x0004,
    ["volumeDown"] = 0x0002,
    ["volumeUp"] = 0x0003,
    ["UP"] = 0x0027,
    ["DOWN"] = 0x001F,
    ["LEFT"] = 0x0020,
    ["RIGHT"] = 0x0021,
    ["SELECT"] = 0x0024,
    ["BACK"] = 0x004B,
    ["EXIT"] = 0x004B,
    ["MENU"] = 0x0026,
    ["SETTINGS"] = 0x001D,
    ["HOME"] = 0x00AF,
    ["NUMBER0"] = 0x0006,
    ["NUMBER1"] = 0x0007,
    ["NUMBER2"] = 0x0008,
    ["NUMBER3"] = 0x0009,
    ["NUMBER4"] = 0x000A,
    ["NUMBER5"] = 0x000B,
    ["NUMBER6"] = 0x000C,
    ["NUMBER7"] = 0x000D,
    ["NUMBER8"] = 0x000E,
    ["NUMBER9"] = 0x000F
  }
  local sequ_num = device:get_field(LAST_SEQUENCE) or 0
  log.debug(utils.stringify_table(cmd, "### cmd", true))
  local command = cmd.args and cmd.args.keyCode or cmd.command or cmd
  local av_cmd = { sequence_number = sequ_num, key_attributes = 0x00, vg = { { command = KEY_MAP[command] } } }
  local selected_enpoint = tonumber(device.preferences.selectAVEndpoint) or 2

  log.debug(utils.stringify_table(device.preferences, "### device.preferences", true))

  if sequ_num < 1 then
    sequ_num = sequ_num + 1
  elseif sequ_num >= 65535 then
    sequ_num = 0
  else
    sequ_num = sequ_num + 1
  end

  device:set_field(LAST_SEQUENCE, sequ_num)

  --log.debug(utils.stringify_table(av_cmd, "av_cmd", true))
  device:set_field(LAST_COMMAND, command)

  log.debug("selectedEndpoint:", selected_enpoint)
  --device:send(AVControl:Set(av_cmd))
  device:send_to_component(AVControl:Set(av_cmd), cmd.component)
end

local function device_init(driver, device, event)
  if device.network_type == st_device.NETWORK_TYPE_ZWAVE then
    device:set_find_child(find_child)
    device:set_component_to_endpoint_fn(component_to_endpoint)
  end

  device:emit_event(capabilities.mediaPlayback.supportedPlaybackCommands({
    capabilities.mediaPlayback.commands.play.NAME,
    capabilities.mediaPlayback.commands.pause.NAME,
    capabilities.mediaPlayback.commands.stop.NAME,
    capabilities.mediaPlayback.commands.fastForward.NAME,
    capabilities.mediaPlayback.commands.rewind.NAME
  }))
end

local remotec_controller = {
    NAME = "remotec-zxt-800",
    supported_capabilities = {
      capabilities.powerSource,
      capabilities.keypadInput,
      capabilities.mediaPlayback,
      capabilities.tV
    },
    zwave_handlers = {
        [cc.SIMPLE_AV_CONTROL] = {
          [AVControl.REPORT] = simpleAVHandler
        }
    },
    capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = simple_av_handler,
      [capabilities.switch.commands.off.NAME] = simple_av_handler
    },
      [capabilities.keypadInput.ID] = {
      [capabilities.keypadInput.commands.sendKey.NAME] = simple_av_handler
      },
      [capabilities.mediaPlayback.ID] = {
        [capabilities.mediaPlayback.commands.play.NAME] = simple_av_handler,
      [capabilities.mediaPlayback.commands.stop.NAME] = simple_av_handler,
      [capabilities.mediaPlayback.commands.rewind.NAME] = simple_av_handler,
      [capabilities.mediaPlayback.commands.fastForward.NAME] = simple_av_handler,
      [capabilities.mediaPlayback.commands.pause.NAME] = simple_av_handler
      },
      [capabilities.tV.ID] = {
      [capabilities.tV.commands.channelDown.NAME] = simple_av_handler,
      [capabilities.tV.commands.channelUp.NAME] = simple_av_handler,
      [capabilities.tV.commands.volumeDown.NAME] = simple_av_handler,
      [capabilities.tV.commands.volumeUp.NAME] = simple_av_handler
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
