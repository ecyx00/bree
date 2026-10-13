// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum SizeMode implements WireEnum {
    LATEST("latest"),
    SMALLEST("smallest"),
    LARGEST("largest"),
    PRIORITY("priority"),
    FIXED("fixed");

    private final Object wireValue;

    SizeMode(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SizeMode fromWire(Object value) {
        for (SizeMode candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown SizeMode value " + value, null);
    }
}
