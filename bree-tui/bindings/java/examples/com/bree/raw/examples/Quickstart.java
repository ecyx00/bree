package com.bree.raw.examples;

import com.bree.raw.BreeClient;
import com.bree.raw.UInt64;
import com.bree.raw.IdentifyResult;
import com.bree.raw.ReadScreenRequest;
import com.bree.raw.SendRequest;

public final class Quickstart {
    private Quickstart() {}

    public static void main(String[] args) throws Exception {
        try (BreeClient client = BreeClient.builder().build()) {
            IdentifyResult server = client.identify();
            System.out.println("bree protocol " + server.protocol());

            UInt64 surface = UInt64.parse(args[0]);
            client.send(
                SendRequest.builder()
                    .surface(surface)
                    .text("printf 'hello from Java\\r'")
                    .build()
            );
            System.out.println(
                client.readScreen(ReadScreenRequest.builder().surface(surface).build()).text()
            );
        }
    }
}
