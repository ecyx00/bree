// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum FrontendFocusTarget implements WireEnum {
    PANE("pane"),
    MACHINE_RAIL("machine_rail"),
    WORKSPACE_RAIL("workspace_rail"),
    TABS_RAIL("tabs_rail"),
    PROJECTION_RAIL("projection_rail");

    private final Object wireValue;

    FrontendFocusTarget(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static FrontendFocusTarget fromWire(Object value) {
        for (FrontendFocusTarget candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown FrontendFocusTarget value " + value, null);
    }
}
