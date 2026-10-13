// Generated from bree-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.bree.raw;

public enum Authority implements WireEnum {
    CONTROL("control"),
    FRONTEND("frontend"),
    LOCAL_ADMIN("local-admin"),
    PROVIDER_AUTHORITY("provider-authority");

    private final String wireValue;
    Authority(String wireValue) { this.wireValue = wireValue; }
    @Override public String wireValue() { return wireValue; }
}
