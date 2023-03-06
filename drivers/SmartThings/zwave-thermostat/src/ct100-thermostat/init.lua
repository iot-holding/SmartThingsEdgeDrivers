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

local capabilities = require "st.capabilities"
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({ version = 2 })
--- @type st.zwave.CommandClass.ThermostatMode
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({ version = 2 })
--- @type st.zwave.CommandClass.ThermostatOperatingState
local ThermostatOperatingState = (require "st.zwave.CommandClass.ThermostatOperatingState")({ version = 1 })
--- @type st.zwave.CommandClass.ThermostatSetpoint
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({ version = 1 })
--- @type st.zwave.CommandClass.ThermostatFanMode
local ThermostatFanMode = (require "st.zwave.CommandClass.ThermostatFanMode")({ version = 1 })
--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({ version = 1 })
local constants = require "st.zwave.constants"
local utils = require "st.utils"

local CT100_THERMOSTAT_FINGERPRINTS = {
  { manufacturerId = 0x0098, productType = 0x6401, productId = 0x0107 }, -- 2Gig CT100 Programmable Thermostat
  { manufacturerId = 0x0098, productType = 0x6501, productId = 0x000C }, -- Iris Thermostat
}

-- This old device uses separate endpoints to get values of temp and humidity
-- DTH actually uses the old mutliInstance encap, but multichannel should be back-compat
local TEMPERATURE_ENDPOINT = 1
local HUMIDITY_ENDPOINT = 2

--TODO: Update this once we've decided how to handle setpoint commands
local function convert_to_device_temp(command_temp, device_scale)
  -- under 40, assume celsius
  if (command_temp <= 35 and device_scale == ThermostatSetpoint.scale.FAHRENHEIT) then
    command_temp = utils.c_to_f(command_temp)
  elseif (command_temp > 35 and (device_scale == ThermostatSetpoint.scale.CELSIUS or device_scale == nil)) then
    command_temp = utils.f_to_c(command_temp)
  end
  return command_temp
end

local function set_setpoint_factory(setpoint_type)
  return function(driver, device, command)
    local scale = device:get_field(constants.TEMPERATURE_SCALE)
    local value = convert_to_device_temp(command.args.setpoint, scale)

    local set = ThermostatSetpoint:Set({
      setpoint_type = setpoint_type,
      scale = scale,
      value = value
    })
    device:send_to_component(set, command.component)

    local follow_up_poll = function()
      device:send_to_component(ThermostatSetpoint:Get({setpoint_type = setpoint_type}), command.component)
      device:send(SensorMultilevel:Get({},{dst_channels={TEMPERATURE_ENDPOINT}}))
      device:send(ThermostatOperatingState:Get({}))
    end

    device.thread:call_with_delay(1, follow_up_poll)
  end
end

local function can_handle_ct100_thermostat(opts, driver, device)
  for _, fingerprint in ipairs(CT100_THERMOSTAT_FINGERPRINTS) do
    if device:id_match( fingerprint.manufacturerId, fingerprint.productType, fingerprint.productId) then
      return true
    end
  end

  return false
end

local function thermostat_mode_report_handler(self, device, cmd)
  local event = nil

  local mode = cmd.args.mode
  if mode == ThermostatMode.mode.OFF then
    event = capabilities.thermostatMode.thermostatMode.off()
  elseif mode == ThermostatMode.mode.HEAT then
    event = capabilities.thermostatMode.thermostatMode.heat()
  elseif mode == ThermostatMode.mode.COOL then
    event = capabilities.thermostatMode.thermostatMode.cool()
  elseif mode == ThermostatMode.mode.AUTO then
    event = capabilities.thermostatMode.thermostatMode.auto()
  elseif mode == ThermostatMode.mode.AUXILIARY_HEAT then
    event = capabilities.thermostatMode.thermostatMode.emergency_heat()
  end

  if (event ~= nil) then
    device:emit_event(event)
  end

  local heating_setpoint = device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME, 0)
  local cooling_setpoint = device:get_latest_state("main", capabilities.thermostatCoolingSetpoint.ID, capabilities.thermostatCoolingSetpoint.coolingSetpoint.NAME, 0)
  local current_temperature = device:get_latest_state("main", capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME, 0)

  device:send(ThermostatOperatingState:Get({}))
  if mode == ThermostatMode.mode.COOL or
    ((mode == ThermostatMode.mode.AUTO or mode == ThermostatMode.mode.OFF) and (current_temperature > (heating_setpoint + cooling_setpoint) / 2)) then
    device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.COOLING_1}))
    device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}))
  else
    device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}))
    device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.COOLING_1}))
  end
end

local function do_refresh(self, device)
  device:send(ThermostatFanMode:Get({}))
  device:send(ThermostatOperatingState:Get({}))
  device:send(SensorMultilevel:Get({},{dst_channels={TEMPERATURE_ENDPOINT}}))
  device:send(SensorMultilevel:Get({},{dst_channels={HUMIDITY_ENDPOINT}}))
  device:send(Battery:Get({}))
  device:send(ThermostatMode:Get({})) -- this get prompts setpoint gets on report
end

local function added_handler(self, device)
  device:send(ThermostatMode:SupportedGet({}))
  device:send(ThermostatFanMode:SupportedGet({}))
  do_refresh(self, device)
end

local ct100_thermostat = {
  NAME = "CT100 thermostat",
  lifecycle_handlers = {
    added = added_handler
  },
  zwave_handlers = {
    [cc.THERMOSTAT_MODE] = {
      [ThermostatMode.REPORT] = thermostat_mode_report_handler
    }
  },
  capability_handlers = {
    [capabilities.thermostatCoolingSetpoint.ID] = {
      [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = set_setpoint_factory(ThermostatSetpoint.setpoint_type.COOLING_1)
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_setpoint_factory(ThermostatSetpoint.setpoint_type.HEATING_1)
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    }
  },
  can_handle = can_handle_ct100_thermostat,
}

return ct100_thermostat
