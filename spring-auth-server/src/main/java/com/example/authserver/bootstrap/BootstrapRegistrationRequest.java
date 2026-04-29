package com.example.authserver.bootstrap;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import java.util.List;

public record BootstrapRegistrationRequest(
    @NotNull @Valid ClientRegistration client,
    @NotEmpty List<@Valid UserRegistration> users
) {

    public record ClientRegistration(
        @NotBlank String clientId,
        @NotBlank String clientSecret,
        @NotBlank String redirectUri,
        @NotEmpty List<@NotBlank String> scopes
    ) {
    }

    public record UserRegistration(
        @NotBlank String username,
        @NotBlank String password,
        @NotEmpty List<@NotBlank String> groups
    ) {
    }
}
