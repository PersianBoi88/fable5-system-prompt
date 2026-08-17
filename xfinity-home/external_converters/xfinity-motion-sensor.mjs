/**
 * Ex-Xfinity Zigbee PIR motion sensor - TEMPLATE
 *
 * INERT AS SHIPPED. The zigbeeModel below is a placeholder that will never
 * match a real device, so this file is safe to deploy untouched. Replace the
 * placeholder with the real modelID before it does anything.
 *
 * Get the real modelID with:  .\scripts\Get-DeviceFingerprint.ps1
 *
 * ---------------------------------------------------------------------------
 * BEFORE USING THIS: Sercomm SZ-PIR02 / SZ-PIR04N and Centralite 3328-G motion
 * sensors already have working upstream definitions.
 * ---------------------------------------------------------------------------
 *
 * Modelled on the upstream Sercomm AL-PIR02 / SZ-PIR04N definitions.
 */

import * as fz from 'zigbee-herdsman-converters/converters/fromZigbee';
import * as exposes from 'zigbee-herdsman-converters/lib/exposes';
import * as reporting from 'zigbee-herdsman-converters/lib/reporting';

const e = exposes.presets;

export default {
    zigbeeModel: ['REPLACE_WITH_REAL_MODEL_ID'],

    model: 'XHS2-MOTION-TEMPLATE',
    vendor: 'Sercomm',
    description: 'Ex-Xfinity PIR motion sensor',

    // ias_occupancy_alarm_1 maps IAS Zone alarm_1 to occupancy, plus tamper
    // and battery_low from the same status bitmap.
    fromZigbee: [fz.ias_occupancy_alarm_1, fz.temperature, fz.battery],
    toZigbee: [],

    // Two battery reporting styles show up across this hardware. Pick one:
    //
    //   a) Voltage only (most common on the older Sercomm units):
    //        meta: {battery: {voltageToPercentage: '3V_2100'}},
    //
    //   b) A cell whose usable range does not fit the named curve - give an
    //      explicit linear range in millivolts, as the upstream SZ-PIR04N
    //      definition does:
    //        meta: {battery: {voltageToPercentage: {min: 2500, max: 3200}}},
    //
    meta: {battery: {voltageToPercentage: '3V_2100'}},

    configure: async (device, coordinatorEndpoint) => {
        const endpoint = device.getEndpoint(1);

        // Motion sensors are the worst offenders for sleeping through
        // configure. Trigger the PIR immediately before hitting Reconfigure.
        await reporting.bind(endpoint, coordinatorEndpoint, ['genPowerCfg']);

        // Use batteryVoltage OR batteryPercentageRemaining to match what the
        // device actually reports - the fingerprint dump shows which
        // genPowerCfg attributes are present. Binding a reporting config for
        // an attribute the device does not implement fails configure.
        await reporting.batteryVoltage(endpoint);
    },

    exposes: [
        e.occupancy(),
        e.battery_low(),
        e.tamper(),
        e.battery(),
    ],

    // Many PIR units latch occupancy for a fixed window and send no explicit
    // "clear". Uncomment to have Zigbee2MQTT synthesise the clear after N
    // seconds. Match this to the device's own blind time or you will get
    // flapping.
    // options: [exposes.options.no_occupancy_since_false()],
};
