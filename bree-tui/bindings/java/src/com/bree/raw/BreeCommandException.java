package com.bree.raw;

public final class BreeCommandException extends BreeException {
    private static final long serialVersionUID = 1L;
    private final String serverMessage;
    @SuppressWarnings("serial")
    private final Object commandId;
    private final String errorCode;
    private final BreeErrorDelivery errorDelivery;

    public BreeCommandException(String serverMessage, Object commandId) {
        this(serverMessage, commandId, null, null);
    }

    public BreeCommandException(
        String serverMessage,
        Object commandId,
        BreeErrorDelivery errorDelivery
    ) {
        this(serverMessage, commandId, null, errorDelivery);
    }

    public BreeCommandException(
        String serverMessage,
        Object commandId,
        String errorCode,
        BreeErrorDelivery errorDelivery
    ) {
        super(serverMessage);
        this.serverMessage = serverMessage;
        this.commandId = commandId;
        this.errorCode = errorCode;
        this.errorDelivery = errorDelivery;
    }

    public String serverMessage() {
        return serverMessage;
    }

    public Object commandId() {
        return commandId;
    }

    public String errorCode() {
        return errorCode;
    }

    public BreeErrorDelivery errorDelivery() {
        return errorDelivery;
    }
}
