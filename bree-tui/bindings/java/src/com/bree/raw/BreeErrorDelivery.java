package com.bree.raw;

public enum BreeErrorDelivery {
    KNOWN_NOT_DELIVERED,
    AMBIGUOUS;

    static BreeErrorDelivery fromWire(Object value) {
        if ("known-not-delivered".equals(value)) {
            return KNOWN_NOT_DELIVERED;
        }
        if ("ambiguous".equals(value)) {
            return AMBIGUOUS;
        }
        return null;
    }
}
