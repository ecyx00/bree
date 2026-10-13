// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;


import java.util.Map;


public interface DeclarativeLayout extends WireValue {
    static DeclarativeLayout fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeclarativeLayout");
        String tag = Wire.string(Wire.required(object, "type"), "DeclarativeLayout.type");
        return switch (tag) {
            case "leaf" -> DeclarativeLayoutLeaf.fromWire(value);
            case "split" -> DeclarativeLayoutSplit.fromWire(value);
            case "stack" -> DeclarativeLayoutStack.fromWire(value);
            default -> throw new BreeDecodeException("unknown DeclarativeLayout tag " + tag, null);
        };
    }
}
