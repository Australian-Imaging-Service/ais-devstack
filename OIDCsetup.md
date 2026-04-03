# Stanford OIDC Authentication Setup for XNAT

This document describes the Stanford OIDC (OpenID Connect) authentication setup for XNAT, including a custom plugin patch required for clean username mapping.

## Overview

XNAT authenticates users via Stanford's Shibboleth-based OIDC provider at `login.stanford.edu`. Users log in with their SUNet ID and get XNAT accounts with their email prefix as the username (e.g., `sciget` from `sciget@stanford.edu`).

## Stanford RP (Relying Party) Configuration

The relying party is registered at Stanford's RP Manager. Key settings:

| Setting | Value |
|---------|-------|
| Client Nickname | rad_xnat |
| Client Type | confidential |
| Application Type | web |
| Subject Type | public |
| Token Endpoint Auth | client_secret_basic |
| Grant Types | authorization_code, refresh_token |
| Response Types | code |
| Scopes | email, offline_access, openid, profile |
| PKCE | enabled |
| Redirect URIs | `https://<domain>/openid-login` |

## XNAT Plugin Configuration

The OIDC config is in `manifests/values.yaml` under `openid-auth-plugin`:

```yaml
openid:
  stanford:
    pkceEnabled: true
    usernamePattern: "[email_prefix]"
    accessTokenUri: https://login.stanford.edu/idp/profile/oidc/token
    userAuthUri: https://login.stanford.edu/idp/profile/oidc/authorize
    userInfoUri: https://login.stanford.edu/idp/profile/oidc/userinfo
    clientId: "<from Stanford RP Manager>"
    clientSecret: "<from Stanford RP Manager>"
    scopes: "openid,profile,email"
    forceUserCreate: true
    userAutoEnabled: true
    userAutoVerified: true
    emailProperty: email
    givenNameProperty: given_name
    familyNameProperty: family_name
```

### Critical settings explained

- **`userInfoUri`** — Must be set. Stanford's ID token contains minimal claims. Without the UserInfo endpoint, user attributes (name, email) won't be populated.

- **`usernamePattern: "[email_prefix]"`** — Custom token added by our plugin patch. Extracts the part before `@` from the email claim (e.g., `sciget` from `sciget@stanford.edu`). See [Plugin Patch](#plugin-patch) below.

- **`forceUserCreate: true`** — Auto-creates XNAT accounts on first OIDC login.

- **`userAutoEnabled: true` / `userAutoVerified: true`** — New accounts are immediately active.

## XNAT Site Configuration

These settings are managed via the XNAT REST API (not the helm values):

### Disable local login (only Stanford OIDC)

```bash
kubectl -n ais-xnat port-forward svc/xnat-web 8080:80 &
curl -u admin:admin -X POST -H "Content-Type: application/json" \
  -d '{"enabledProviders": ["stanford"]}' \
  http://localhost:8080/xapi/siteConfig
```

### Disable SMTP notifications

SMTP must be disabled if no mail server is available. Without this, user creation succeeds but the auth flow fails when the email notification can't be sent:

```bash
curl -u admin:admin -X POST -H "Content-Type: application/json" \
  -d '{"smtpEnabled": "false"}' \
  http://localhost:8080/xapi/notifications
```

### Grant admin roles to a user

```sql
-- Connect to the XNAT database
kubectl -n ais-xnat exec xnat-web-postgresql-0 -- env PGPASSWORD=<db-password> psql -U xnat -d xnat

-- Find the user ID
SELECT xdat_user_id, login FROM xdat_user WHERE login = '<username>';

-- Grant roles (replace <user_id>)
INSERT INTO xdat_r_xdat_role_type_assign_xdat_user
  (xdat_user_xdat_user_id, xdat_role_type_role_name)
VALUES
  (<user_id>, 'Administrator'),
  (<user_id>, 'DataManager'),
  (<user_id>, 'SiteUser');
```

## Plugin Patch

The standard `openid-auth-plugin-1.4.1-xpl.jar` does not support extracting the email prefix as a username. We patched the `OpenIdConnectUserDetails` class to add a custom `[email_prefix]` token.

### Why the patch is needed

Stanford's OIDC provider returns these claims (from their discovery endpoint):

```
sub, email, name, family_name, given_name, profile, locale, updated_at
```

- **`sub`** is a UUID like `7d9f536f7d0b4f82987c4522124e5f89@stanford.edu` — the `@` character fails XNAT's `sanitizeUsername` validation, and without a prefix the UUID starts with a digit which is also invalid.
- **`preferred_username`** is returned in the UserInfo response but is not listed in the discovery endpoint's `claims_supported` and was unreliable during testing.
- **`email`** is `sciget@stanford.edu` — contains `@` which gets replaced with `_` by sanitization, giving `sciget_stanford.edu` instead of `sciget`.

The patch adds an `email_prefix` virtual claim that extracts the local part of the email address (before `@`).

### Patch details

**Modified file:** `plugins/patches/OpenIdConnectUserDetails.java`

**Change:** Added `email_prefix` handling to the `getFieldValue` method:

```java
if ("email_prefix".equals(fieldName)) {
    String emailVal = null;
    if (this.openIdUserInfo != null) {
        emailVal = this.openIdUserInfo.get("email");
    }
    if (emailVal != null && emailVal.contains("@")) {
        return emailVal.substring(0, emailVal.indexOf("@"));
    }
    return emailVal;
}
```

### Patched JAR location

- **Repo:** `plugins/openid-auth-plugin-1.4.1-xpl.jar` (patched version)
- **NFS (runtime):** Copied to NFS server at `/exports/xnat/plugins/` during install
- **Source:** `plugins/patches/OpenIdConnectUserDetails.java`

### Rebuilding the patch

If the plugin JAR needs to be updated or re-patched:

```bash
# 1. Extract and compile the patched class inside the XNAT pod
kubectl -n ais-xnat exec xnat-web-0 -c xnat-web -- bash -c '
  mkdir -p /tmp/patch/au/edu/qcif/xnat/auth/openid
  cp <source> /tmp/patch/au/edu/qcif/xnat/auth/openid/OpenIdConnectUserDetails.java
  cd /tmp/patch
  CP="/usr/local/tomcat/webapps/ROOT/WEB-INF/lib/*"
  /opt/java/openjdk/bin/javac -cp "$CP" -source 1.8 -target 1.8 \
    au/edu/qcif/xnat/auth/openid/OpenIdConnectUserDetails.java
  cp /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/openid-auth-plugin-1.4.1-xpl.jar /tmp/patched.jar
  jar uf /tmp/patched.jar au/edu/qcif/xnat/auth/openid/OpenIdConnectUserDetails.class
'

# 2. Copy patched JAR to NFS server
kubectl -n ais-xnat cp xnat-web-0:/tmp/patched.jar /tmp/patched.jar -c xnat-web
kubectl -n storage cp /tmp/patched.jar \
  $(kubectl -n storage get pods -l app=nfs-server -o name | cut -d/ -f2):/exports/xnat/plugins/openid-auth-plugin-1.4.1-xpl.jar

# 3. Restart XNAT to load the new JAR
kubectl -n ais-xnat delete pod xnat-web-0
```

## Stanford OIDC Endpoints

| Endpoint | URL |
|----------|-----|
| Discovery | `https://login.stanford.edu/.well-known/openid-configuration` |
| Authorization | `https://login.stanford.edu/idp/profile/oidc/authorize` |
| Token | `https://login.stanford.edu/idp/profile/oidc/token` |
| UserInfo | `https://login.stanford.edu/idp/profile/oidc/userinfo` |
| JWKS | `https://login.stanford.edu/idp/profile/oidc/keyset` |

## Claims returned by Stanford

From the ID token + UserInfo endpoint (with scopes `openid profile email`):

| Claim | Example | Used for |
|-------|---------|----------|
| `sub` | `7d9f536f...@stanford.edu` | Not used (UUID, has `@`) |
| `email` | `sciget@stanford.edu` | Username via `[email_prefix]`, email field |
| `given_name` | `Steffen` | First name |
| `family_name` | `Bollmann` | Last name |
| `name` | `Steffen Bollmann` | Not used |
| `preferred_username` | `sciget` | Available but unreliable |

## Troubleshooting

### OIDC login fails silently (no error message, redirects to login page)

Check the Tomcat access log for 500 errors on the callback:
```bash
kubectl -n ais-xnat exec xnat-web-0 -c xnat-web -- \
  tail -20 /usr/local/tomcat/logs/localhost_access_log.*.txt | grep openid
```

### "OpenID Connect login failed" error

Check the openid plugin log:
```bash
kubectl -n ais-xnat exec xnat-web-0 -c xnat-web -- \
  cat /data/xnat/home/logs/openid.log
```

Common causes:
- **SMTP failure** — User creation succeeds but email notification fails, crashing the auth flow. Fix: disable SMTP via `smtpEnabled: false` in the notifications API.
- **Username sanitization failure** — The `@` in Stanford's `sub` claim fails validation. Fix: use `[email_prefix]` pattern.
- **Missing `userInfoUri`** — Claims like name/email aren't populated. Fix: add `userInfoUri` to the config.

### Emergency: re-enable local login

If OIDC breaks and you can't log in:
```bash
kubectl -n ais-xnat port-forward svc/xnat-web 8080:80 &
curl -u admin:admin -X POST -H "Content-Type: application/json" \
  -d '{"enabledProviders": ["localdb", "stanford"]}' \
  http://localhost:8080/xapi/siteConfig
```

Or via the database:
```sql
UPDATE xhbm_preference SET value = '["localdb","stanford"]'
WHERE name = 'enabledProviders';
```

Note: The `admin` account must exist and be enabled (enabled=1) with admin roles for this to work. It is kept as a system account.
