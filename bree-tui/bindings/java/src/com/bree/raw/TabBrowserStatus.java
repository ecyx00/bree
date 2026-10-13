// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum TabBrowserStatus implements WireEnum {
    STARTING("starting"),
    LIVE("live"),
    FAILED("failed");

    private final Object wireValue;

    TabBrowserStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TabBrowserStatus fromWire(Object value) {
        for (TabBrowserStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown TabBrowserStatus value " + value, null);
    }
}
