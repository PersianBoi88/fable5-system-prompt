/**
 * Ex-Xfinity Zigbee door/window contact sensor - TEMPLATE
 *
 * INERT AS SHIPPED. The zigbeeModel below is a placeholder that will never
 * match a real device, so this file is safe to deploy untouched. Replace the
 * placeholder with the real modelID before it does anything.
 *
 * Get the real modelID with:  .\scripts\Get-DeviceFingerprint.ps1
 *
 * ---------------------------------------------------------------------------
 * BEFORE USING THIS: check that the device is not already supported upstream.
 * Sercomm XHS2-SE, Visonic MCT-340 E / MCT-340 SMA, Centralite 3323-G and
 * SmartThings 3300-S contact sensors all have working built-in definitions.
 * ---------------------------------------------------------------------------
 *
 * Modelled on the upstream Sercomm XHS2-SE definition, which is the closest
 * relative of most ex-Xfinity contact hardware.
 */

import * as fz from 'zigbee-herdsman-converters/converters/fromZigbee';
import * as exposes from 'zigbee-herdsman-converters/lib/exposes';
import * as reporting from 'zigbee-herdsman-converters/lib/reporting';

const e = exposes.presets;

export default {
    // The modelID string reported by the device during interview, exactly as
    // it appears in the fingerprint dump - including any trailing spaces,
    // which some of this hardware really does emit.
    zigbeeModel: ['REPLACE_WITH_REAL_MODEL_ID'],

    model: 'XHS2-CONTACT-TEMPLATE',
    vendor: 'Sercomm',
    description: 'Ex-Xfinity magnetic door & window contact sensor',

    // ias_contact_alarm_1 decodes the IAS Zone status bitmap: alarm_1 becomes
    // the contact state (inverted - alarm set means open), bit 2 becomes
    // tamper, bit 3 becomes battery_low.
    fromZigbee: [fz.ias_contact_alarm_1, fz.temperature, fz.battery],
    toZigbee: [],

    // These sensors report battery VOLTAGE, not percentage. Without a curve
    // the battery entity never populates. 3V_2100 is the correct non-linear
    // curve for a CR2 / CR123A style 3V cell as used across this fleet.
    //
    // If the battery entity populates but reads roughly half of reality,
    // the device is reporting 0-100 where ZCL specifies 0-200 - in that case
    // replace the line below with:
    //     meta: {battery: {dontDividePercentage: true}},
    meta: {battery: {voltageToPercentage: '3V_2100'}},

    // Runs at pairing and on Reconfigure. Will time out if the device is
    // asleep - wake it by opening/closing the contact, then Reconfigure.
    configure: async (device, coordinatorEndpoint) => {
        const endpoint = device.getEndpoint(1);

        // Drop any cluster the fingerprint dump did not list for this device.
        // Binding a cluster the device does not implement fails the whole
        // configure step, so the temperature entries are the usual thing to
        // remove for a contact-only variant.
        await reporting.bind(endpoint, coordinatorEndpoint, [
            'msTemperatureMeasurement',
            'genPowerCfg',
        ]);

        await reporting.temperature(endpoint);
        await reporting.batteryVoltage(endpoint);
    },

    exposes: [
        e.contact(),
        e.battery_low(),
        e.tamper(),
        e.temperature(),
        e.battery(),
    ],
};
