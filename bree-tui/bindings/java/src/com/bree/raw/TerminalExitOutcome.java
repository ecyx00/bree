// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;


import java.util.Map;


public interface TerminalExitOutcome extends WireValue {
    static TerminalExitOutcome fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalExitOutcome");
        String tag = Wire.string(Wire.required(object, "kind"), "TerminalExitOutcome.kind");
        return switch (tag) {
            case "exit" -> TerminalExitOutcomeExit.fromWire(value);
            case "signal" -> TerminalExitOutcomeSignal.fromWire(value);
            case "unknown" -> TerminalExitOutcomeUnknown.fromWire(value);
            default -> throw new BreeDecodeException("unknown TerminalExitOutcome tag " + tag, null);
        };
    }
}
