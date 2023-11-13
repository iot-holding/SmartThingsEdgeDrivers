-- Copyright 2021 SmartThings
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
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })

local utils = require "st.utils"
local log = require "log"

local REMOTEC_ZXT800_ZWAVE = {
  PARAMETERS = {
    learnACIRcode = { parameter_number = 25, size = 1 },
    learnAVIRCode ={ parameter_number = 26, size = 1 },
    setIRCodefrombuiltinACL ={ parameter_number = 27, size = 2 },
    extIREmitterPowerLevel = { parameter_number = 28, size = 1 },
    setAutoReportCondByTCh = { parameter_number = 30, size = 1 },
    setBuiltInEmitterControl = { parameter_number = 32, size = 1 },
    controlAirCondSwing = { parameter_number = 33, size = 1 },
    tempHumidAutoReport = { parameter_number = 34, size = 1 },
    calibrateTempReading = { parameter_number = 37, size = 1 },
    selectAVEndpoint = { parameter_number = 38, size = 1 },
    calibrateHumidityReading = { parameter_number = 53, size = 1 },
    triggerBLEAdvertising = { parameter_number = 60, size = 1 },
    bleAdvertisingOption = { parameter_number = 61, size = 1 },
    deviceResetToDefault = { parameter_number = 160, size = 1 },
  }
}


local devices = {
  REMOTEC_ZXT800 = {
    MATCHING_MATRIX = {
      mfrs = 0x5254,
      product_types = 0x0004,
      product_ids = 0x8492
    },
    PARAMETERS = REMOTEC_ZXT800_ZWAVE.PARAMETERS
  }
}

local preferences = {}

preferences.update_preferences = function(driver, device, args)
  local preferences = preferences.get_device_parameters(device)
  for id, value in pairs(device.preferences) do
    local oldPreferenceValue = args and args["old_st_store"] and args.old_st_store["preferences"] and args.old_st_store.preferences[id] or nil
    local newParameterValue = device.preferences[id]
    local synchronized = device:get_field(id)
    if preferences and preferences[id] and (oldPreferenceValue ~= newParameterValue or synchronized == false) then
      device:send(Configuration:Set({ parameter_number = preferences[id].parameter_number, size = preferences[id].size,
        configuration_value = newParameterValue }):to_endpoint(0))
      device:set_field(id, true, { persist = true })
      device:send(Configuration:Get({ parameter_number = preferences[id].parameter_number }):to_endpoint(0))
    end
  end
end

preferences.get_device_parameters = function(zw_device)
  for _, device in pairs(devices) do
    if zw_device:id_match(
          device.MATCHING_MATRIX.mfrs,
          device.MATCHING_MATRIX.product_types,
          device.MATCHING_MATRIX.product_ids) then
      return device.PARAMETERS
    end
  end
  return nil
end

preferences.to_numeric_value = function(new_value)
  local numeric = tonumber(new_value)
  if numeric == nil then -- in case the value is boolean
    numeric = new_value and 1 or 0
  end
  return numeric
end

return preferences
