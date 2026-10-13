// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum PaneDirection implements WireEnum {
    LEFT("left"),
    RIGHT("right"),
    UP("up"),
    DOWN("down");

    private final Object wireValue;

    PaneDirection(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static PaneDirection fromWire(Object value) {
        for (PaneDirection candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown PaneDirection value " + value, null);
    }
}
