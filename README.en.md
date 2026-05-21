English | [日本語](README.md)

# letsencrypt-dns-conoha

Obtain and renew Let's Encrypt (wildcard) certificates on ConoHa VPS using the
DNS-01 challenge, automated through the ConoHa DNS API.

This is a fork of [k2snow/letsencrypt-dns-conoha](https://github.com/k2snow/letsencrypt-dns-conoha) (MIT).
The main changes are support for the **ConoHa API v3** (`c3j1`) in addition to
the legacy v2 (`tyo1` / `tyo2`), more robust DNS propagation handling, and basic
logging.

## What's different from the original

- **API v2 / v3 auto-switching** based on `CNH_REGION` (v2 for `tyo1`/`tyo2`,
  otherwise v3).
- **Configuration via `.env`** (instead of a `conoha_id` file).
- **Authoritative-NS propagation polling** instead of a fixed `sleep`. The hook
  resolves the zone's authoritative nameservers and waits until the TXT record
  is visible on *all* of them (this is what the ACME validator queries), with a
  timeout.
- **Longest-suffix zone matching** against the ConoHa DNS domain list, so
  subdomain certificates and multi-label TLDs (e.g. `co.jp`, `ne.jp`) resolve to
  the correct registered zone.
- **HTTP status checking** on API calls and **fail-fast validation** of the
  token and domain ID, so misconfiguration surfaces immediately instead of
  hanging.
- **Logging** to `conoha_dns.log` with timestamps.
- The deprecated `--manual-public-ip-logging-ok` certbot flag is **not** used
  (it was removed in certbot 2.0).

## Requirements

- ConoHa VPS account, with the target domain managed by ConoHa DNS
- certbot (recent version; tested without the removed
  `--manual-public-ip-logging-ok` flag)
- `jq`
- `dig` (provided by `bind-utils` on RHEL-family distros)
- bash 4+ (uses `mapfile`)

Example install on AlmaLinux 9:

```
sudo dnf install -y certbot jq bind-utils
```

## Setup

1. Place the scripts on your server, e.g. `/etc/letsencrypt/conoha/`.
2. Create your credentials file from the template and edit it:

   ```
   cp .env.example .env
   $EDITOR .env
   ```

3. Make the hook scripts executable:

   ```
   chmod +x create_conoha_dns_record.sh delete_conoha_dns_record.sh
   ```

### `.env` values

| Variable         | Description                                                       |
| ---------------- | ----------------------------------------------------------------- |
| `CNH_REGION`     | `c3j1` for ConoHa VPS 3.0 (API v3); `tyo1` / `tyo2` for VPS 2.0   |
| `CNH_TENANT_ID`  | Tenant (project) ID from the ConoHa control panel, "API" page     |
| `CNH_USERNAME`   | API user name (the `gncu...` value), from the "API user" section  |
| `CNH_PASSWORD`   | Password set when the API user was created                        |

> The `.env` file is git-ignored. Never commit real credentials.

## Usage

### Dry run (staging test)

```
sudo certbot certonly \
  --dry-run \
  --manual \
  --agree-tos \
  --no-eff-email \
  --preferred-challenges dns-01 \
  --server https://acme-v02.api.letsencrypt.org/directory \
  -d "<base domain name>" \
  -d "*.<base domain name>" \
  -m "<mail address>" \
  --manual-auth-hook /etc/letsencrypt/conoha/create_conoha_dns_record.sh \
  --manual-cleanup-hook /etc/letsencrypt/conoha/delete_conoha_dns_record.sh
```

### Obtain the certificate

Run the same command without `--dry-run`.

### Renewal

```
sudo certbot renew --dry-run   # test
sudo certbot renew             # actual
```

certbot stores the hook configuration with the certificate, so `renew` reuses
the same hooks automatically.

## Files

| File                          | Role                                              |
| ----------------------------- | ------------------------------------------------- |
| `create_conoha_dns_record.sh` | `--manual-auth-hook`: create TXT, wait for propagation |
| `delete_conoha_dns_record.sh` | `--manual-cleanup-hook`: delete the TXT record    |
| `conoha_dns_api_v2.sh`        | API functions for ConoHa API v2 (`tyo1`/`tyo2`)   |
| `conoha_dns_api_v3.sh`        | API functions for ConoHa API v3 (`c3j1`)          |
| `.env.example`                | Credentials template (copy to `.env`)             |

## Notes

- For a `*.example.com` certificate, certbot calls the auth hook **twice** with
  the same name `_acme-challenge.example.com` but different values; two TXT
  records coexist during validation, which is expected.
- `conoha_dns.log` is rotated by the script itself once it exceeds a size
  threshold (configurable via `LOG_MAX_BYTES` / `LOG_GENERATIONS` in `.env`;
  defaults are 1 MiB and 3 generations). Total size is bounded by
  `LOG_MAX_BYTES × (generations + 1)`.
- Do not delete `_acme-challenge` records that are a **CNAME** (used for
  delegation, e.g. acme-dns); only the throwaway TXT records are safe to remove.

## License

MIT License. See [LICENSE](LICENSE). Original work Copyright (c) k2snow.
