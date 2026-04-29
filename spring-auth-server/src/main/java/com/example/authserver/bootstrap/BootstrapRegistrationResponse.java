package com.example.authserver.bootstrap;

import java.util.List;

public record BootstrapRegistrationResponse(
    String clientId,
    List<String> redirectUris,
    List<String> scopes,
    List<RegisteredUser> users
) {
    public record RegisteredUser(
        String username,
        List<String> groups
    ) {
    }
}
