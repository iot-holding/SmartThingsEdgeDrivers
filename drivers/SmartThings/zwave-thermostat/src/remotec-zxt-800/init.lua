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
--- @type remotec-zxt-800.SimpleAVControl
local AVControl = (require "remotec-zxt-800.SimpleAVControl")({version = 4})

local utils = require "st.utils"

local LAST_COMMAND = 'last_command'
local LAST_SEQUENCE = 'last_sequence'

local supported_modes = {
  capabilities.thermostatMode.thermostatMode.off.NAME,
  capabilities.thermostatMode.thermostatMode.heat.NAME,
  capabilities.thermostatMode.thermostatMode.cool.NAME,
  capabilities.thermostatMode.thermostatMode.auto.NAME,
  capabilities.thermostatMode.thermostatMode.resume.NAME,
  capabilities.thermostatMode.thermostatMode.fanonly.NAME,
  capabilities.thermostatMode.thermostatMode.dryair.NAME
}

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

local REMOTEC_FINGERPRINTS = {
    {mfr = 0x5254, prod = 0x0004, model = 0x8492} -- Remotec ZXT 800
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

local function find_child(parent, ep_id)
  if ep_id == 1 then
    return parent
  else
    return parent:get_child_by_parent_assigned_key(string.format("%02X", ep_id))
  end
end

local function component_to_endpoint(device, component)
  return { 1 }
end

local function create_child_devices(driver, device)
  local name = "ZXT 800 AV"
  local metadata = {
    type = "EDGE_CHILD",
    label = name,
    profile = "remotec-zxt-800-child",
    parent_device_id = device.id,
    parent_assigned_child_key = string.format("%02X", 2),
    vendor_provided_label = name,
  }
  driver:try_create_device(metadata)
end

local simple_av_handler = function(self, device, cmd)
  local sequ_num = device:get_field(LAST_SEQUENCE) or 0
  local command = cmd.args and cmd.args.keyCode or cmd.command or cmd
  local av_cmd = { sequence_number = sequ_num, key_attributes = 0x00, vg = { { command = KEY_MAP[command] } } }

  if sequ_num < 1 then
    sequ_num = sequ_num + 1
  elseif sequ_num >= 65535 then
    sequ_num = 0
  else
    sequ_num = sequ_num + 1
  end

  device:set_field(LAST_SEQUENCE, sequ_num)
  device:set_field(LAST_COMMAND, command)
  device:send_to_component(AVControl:Set(av_cmd), cmd.component)
  if command == "on" then
    device:emit_event(capabilities.switch.switch.on())
  elseif command == "off" then
    device:emit_event(capabilities.switch.switch.off())
  end
end

local function device_added(driver, device, event)
  if device:is_cc_supported(cc.BATTERY) then
    device:try_update_metadata({ profile = "remotec-zxt-800-battery" })

    device.thread:call_with_delay(2,
      function()
        device:emit_event(capabilities.powerSource.powerSource.battery())
      end
    )
  else
    device:emit_event(capabilities.powerSource.powerSource.mains())
  end

  device:emit_event(capabilities.thermostatMode.supportedThermostatModes(supported_modes,
    { visibility = { displayed = false } }))
  if device.network_type == st_device.NETWORK_TYPE_ZWAVE and
      not (device.child_ids and utils.table_size(device.child_ids) ~= 0) then
    create_child_devices(driver, device)
  end
  device:refresh()
  device:emit_event(capabilities.switch.switch.off())
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

  device.thread:call_with_delay(1, function()
    device:emit_event(capabilities.mediaPlayback.playbackStatus('stopped'))
  end)

end

local remotec_controller = {
  NAME = "remotec-zxt-800",
  supported_capabilities = {
    capabilities.powerSource,
    capabilities.keypadInput,
    capabilities.mediaPlayback,
    capabilities.tV
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
