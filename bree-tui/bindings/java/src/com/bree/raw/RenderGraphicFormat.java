// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum RenderGraphicFormat implements WireEnum {
    RGB("rgb"),
    RGBA("rgba");

    private final Object wireValue;

    RenderGraphicFormat(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static RenderGraphicFormat fromWire(Object value) {
        for (RenderGraphicFormat candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown RenderGraphicFormat value " + value, null);
    }
}
