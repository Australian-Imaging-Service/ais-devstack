package au.edu.qcif.xnat.auth.openid;

import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.apache.commons.lang3.StringUtils;
import org.nrg.xdat.security.XDATUser;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.oauth2.common.OAuth2AccessToken;

public class OpenIdConnectUserDetails extends XDATUser {
    private static final long serialVersionUID = -1568972028866924986L;
    private static final Pattern EXTRACTOR = Pattern.compile("\\[([a-zA-Z0-9_]+)]");
    private static final String DEFAULT_USERNAME_PATTERN = "[providerId]_[sub]";
    private static final Logger log = LoggerFactory.getLogger(OpenIdConnectUserDetails.class);
    private OAuth2AccessToken token;
    private String email;
    private final Map<String, String> openIdUserInfo;
    private String firstName;
    private String lastName;
    private String username;
    private final String providerId;
    private final OpenIdAuthPlugin plugin;

    public OpenIdConnectUserDetails(String providerId, Map<String, String> userInfo, OAuth2AccessToken token, OpenIdAuthPlugin plugin) {
        this.openIdUserInfo = userInfo;
        this.providerId = providerId;
        log.info("OpenIdConnectUserDetails: userInfo keys = {}", userInfo != null ? userInfo.keySet() : "null");
        this.setUsername(this.resolvePattern(plugin.getProperty(providerId, "usernamePattern")));
        this.token = token;
        this.plugin = plugin;
        this.email = this.getUserInfo(userInfo, "emailProperty");
        this.setFirstname(this.getUserInfo(userInfo, "givenNameProperty"));
        this.setLastname(this.getUserInfo(userInfo, "familyNameProperty"));
    }

    public String getFieldValue(String fieldName) {
        if ("email_prefix".equals(fieldName)) {
            // Try to get email from the userInfo map directly since this.email
            // may not be set yet during resolvePattern in the constructor
            String emailVal = null;
            if (this.openIdUserInfo != null) {
                // Try common email claim names
                emailVal = this.openIdUserInfo.get("email");
                if (emailVal == null) {
                    emailVal = this.openIdUserInfo.get("mail");
                }
            }
            // Also try the field if it's already set
            if (emailVal == null && this.email != null && !this.email.isEmpty()) {
                emailVal = this.email;
            }
            log.info("email_prefix: raw email value = '{}'", emailVal);
            if (emailVal != null && emailVal.contains("@")) {
                String prefix = emailVal.substring(0, emailVal.indexOf("@"));
                log.info("email_prefix: resolved to '{}'", prefix);
                return prefix;
            }
            return emailVal;
        }

        String value = null;
        try {
            Field field = this.getClass().getDeclaredField(fieldName);
            value = (String) field.get(this);
        } catch (Exception e) {
            if (this.openIdUserInfo != null) {
                value = this.openIdUserInfo.get(fieldName);
            }
        }
        return value;
    }

    public OAuth2AccessToken getToken() { return this.token; }
    public void setToken(OAuth2AccessToken token) { this.token = token; }
    public void setUsername(String username) { this.username = username; }
    public String getUsername() { return this.username; }
    public String getFirstname() { return this.firstName; }
    public String getLastname() { return this.lastName; }
    public String getEmail() { return this.email; }
    public void setEmail(String e) { this.email = e; }
    public void setFirstname(String firstname) { this.firstName = firstname; }
    public void setLastname(String lastname) { this.lastName = lastname; }

    private String getUserInfo(Map<String, String> userInfo, String propName) {
        String propVal = userInfo.get(this.plugin.getProperty(this.providerId, propName));
        return propVal != null ? propVal : "";
    }

    private String resolvePattern(String usernamePattern) {
        String pattern = (String) StringUtils.defaultIfBlank((CharSequence) usernamePattern, (CharSequence) DEFAULT_USERNAME_PATTERN);
        Matcher matcher = EXTRACTOR.matcher(pattern);
        HashMap<String, String> pairs = new HashMap<String, String>();
        AtomicInteger index = new AtomicInteger();
        while (matcher.find(index.get())) {
            pairs.put(matcher.group(0), matcher.group(1));
            index.set(matcher.end());
        }
        String converted = pattern;
        for (String key : pairs.keySet()) {
            String fieldName = pairs.get(key);
            String fieldValue = this.getFieldValue(fieldName);
            if (StringUtils.isBlank((CharSequence) fieldValue)) {
                throw new IllegalArgumentException("Cannot resolve username pattern '" + pattern + "': the claim or field '" + fieldName + "' was not found or blank in the OpenID response. Available claims: " + (this.openIdUserInfo != null ? this.openIdUserInfo.keySet() : "none") + ". Please check your usernamePattern configuration and ensure the identity provider returns the expected claim.");
            }
            converted = converted.replace(key, fieldValue);
        }
        return converted;
    }
}
