// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

import java.util.Objects;

public enum ViewAttachmentOutcome implements WireEnum {
    APPLIED("applied"),
    PASSIVE("passive"),
    SUPERSEDED("superseded");

    private final Object wireValue;

    ViewAttachmentOutcome(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static ViewAttachmentOutcome fromWire(Object value) {
        for (ViewAttachmentOutcome candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new BreeDecodeException("unknown ViewAttachmentOutcome value " + value, null);
    }
}
