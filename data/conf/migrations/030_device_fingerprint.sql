-- SOM-IDLE S5: add device fingerprint to telemetry for multi-account detection.
ALTER TABLE telemetry_event ADD COLUMN fingerprint TEXT DEFAULT '';
