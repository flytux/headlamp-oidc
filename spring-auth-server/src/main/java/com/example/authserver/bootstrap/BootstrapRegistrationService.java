package com.example.authserver.bootstrap;

import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.ClientAuthenticationMethod;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.oauth2.server.authorization.settings.ClientSettings;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;
import org.springframework.stereotype.Service;

@Service
public class BootstrapRegistrationService {

    private final MutableRegisteredClientRepository registeredClientRepository;
    private final InMemoryUserDetailsManager userDetailsManager;
    private final PasswordEncoder passwordEncoder;

    public BootstrapRegistrationService(
        MutableRegisteredClientRepository registeredClientRepository,
        InMemoryUserDetailsManager userDetailsManager,
        PasswordEncoder passwordEncoder
    ) {
        this.registeredClientRepository = registeredClientRepository;
        this.userDetailsManager = userDetailsManager;
        this.passwordEncoder = passwordEncoder;
    }

    public BootstrapRegistrationResponse register(BootstrapRegistrationRequest request) {
        RegisteredClient registeredClient = upsertClient(request.client());
        List<BootstrapRegistrationResponse.RegisteredUser> users = request.users().stream()
            .map(this::upsertUser)
            .toList();

        return new BootstrapRegistrationResponse(
            registeredClient.getClientId(),
            List.copyOf(registeredClient.getRedirectUris()),
            List.copyOf(registeredClient.getScopes()),
            users
        );
    }

    private RegisteredClient upsertClient(BootstrapRegistrationRequest.ClientRegistration request) {
        RegisteredClient existingClient = registeredClientRepository.findByClientId(request.clientId());
        String registeredClientId = existingClient != null ? existingClient.getId() : UUID.randomUUID().toString();

        RegisteredClient registeredClient = RegisteredClient.withId(registeredClientId)
            .clientId(request.clientId())
            .clientSecret(passwordEncoder.encode(request.clientSecret()))
            .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
            .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
            .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
            .redirectUri(request.redirectUri())
            .scopes((scopes) -> scopes.addAll(request.scopes()))
            .clientSettings(ClientSettings.builder().requireAuthorizationConsent(false).build())
            .build();

        registeredClientRepository.save(registeredClient);
        return registeredClient;
    }

    private BootstrapRegistrationResponse.RegisteredUser upsertUser(BootstrapRegistrationRequest.UserRegistration request) {
        if (userDetailsManager.userExists(request.username())) {
            userDetailsManager.deleteUser(request.username());
        }

        userDetailsManager.createUser(
            User.withUsername(request.username())
                .password(passwordEncoder.encode(request.password()))
                .authorities(toAuthorities(request.groups()))
                .build()
        );

        return new BootstrapRegistrationResponse.RegisteredUser(request.username(), request.groups());
    }

    private String[] toAuthorities(List<String> groups) {
        return groups.stream()
            .map(group -> "GROUP_" + group)
            .toArray(String[]::new);
    }
}
