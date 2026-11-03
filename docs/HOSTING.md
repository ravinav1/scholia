# Hosting the web workspace

The hosted service runs independently of the Mac app. Each account has private
workspaces, files, conversations, provider credentials, and a Canvas connection.
Accounts on this service do not synchronize with native or extension libraries.
The repository supplies the service and container definition; it does not
provision a cloud server, domain, or TLS certificate.

Use Node.js 24 or newer and one service process with persistent local storage.
SQLite and in-memory task coordination currently assume a single instance.
Horizontal replicas and shared-network-filesystem deployments are not supported.

## Run locally

```sh
npm ci
npm run build:web
npm run web:user -- --email you@example.com
npm run start:web
```

Open `http://127.0.0.1:3000`. The account command reads one password line from
standard input; it must contain 12–256 characters. The interactive prompt hides
your input. For automation, supply it through a private input file or your
secret-management tooling rather than a command argument or shell history.
There is no public registration form.

## Configuration

| Variable               | Default                         | Purpose                                                          |
| ---------------------- | ------------------------------- | ---------------------------------------------------------------- |
| `SCHOLIA_ORIGIN`       | `http://127.0.0.1:3000`         | Exact public origin, including a nonstandard port if used        |
| `SCHOLIA_DATA_DIR`     | `.data`                         | Persistent database, original files, indexes, and encryption key |
| `SCHOLIA_CANVAS_HOSTS` | `canvas.ntnu.no`                | Comma-separated allowed Canvas hostnames                         |
| `SCHOLIA_SECRET_KEY`   | Generated in the data directory | Optional 64-character hexadecimal encryption key                 |
| `SCHOLIA_OCR`          | Enabled when Tesseract is installed | Set to `off` to disable local image/scanned PDF OCR            |
| `SCHOLIA_OCR_LANGUAGES` | `eng`                          | Installed Tesseract languages, for example `eng+nor`              |
| `SCHOLIA_TESSERACT`    | `tesseract`                    | Optional absolute path to the local OCR executable               |
| `HOST`                 | `127.0.0.1`                     | Listening interface; container default is `0.0.0.0`              |
| `PORT`                 | `3000`                          | Listening port                                                   |

The application does not load `.env` automatically. Export variables with your
process manager, or use Docker's `--env-file`. `.env.example` is a starting point
for a container deployment. Keep secrets and data outside version control.

The Docker image includes Tesseract and English/Norwegian language data. For a
local Node deployment, install Tesseract with your operating system package
manager to enable OCR. OCR runs on this server without uploading files to a
provider or downloading models at runtime. Scanned PDFs use up to six sampled
pages and a 24-second OCR budget; images have a six-second budget. Low-confidence
words are excluded from classification. Clear handwriting can sometimes be
recognized, but cursive handwriting and mathematical notation are unreliable;
see the [Tesseract documentation](https://tesseract-ocr.github.io/tessdoc/tess3/FAQ-Old.html#can-i-use-tesseract-for-handwriting-recognition).
The document notice reports incomplete or unavailable OCR, and originals remain
available. Workspace categories and topic headings use extracted text and OCR
evidence, preserve Canvas modules, and leave ambiguous files under Documents.
Analysis is saved with each import. Existing saved text is classified in bounded
batches on workspace visits, and older PDF/image indexes upgrade on opening.

A non-loopback public origin must use HTTPS. Terminate TLS at a reverse proxy
and forward the original `Host` header exactly. The application validates Host
and Origin and rejects cross-site requests. Do not expose the backend port
publicly when a proxy is handling TLS.

## Docker deployment

From the repository root:

```sh
docker build -t scholia-web .
cp .env.example .env
# Set SCHOLIA_ORIGIN to your HTTPS address and configure allowed Canvas hosts.
docker volume create scholia-data
docker run -d --name scholia --restart unless-stopped \
  --env-file .env \
  -p 127.0.0.1:3000:3000 \
  -v scholia-data:/data \
  scholia-web
```

The image runs as the unprivileged `node` user. A new named volume inherits the
image's data-directory ownership. If you use a host bind mount instead, make it
writable by the container's user and restrict access to the service operator.

Create the first account with a private, single-line password file:

```sh
docker exec -i scholia node scripts/web-user.mjs \
  --email you@example.com < /secure/path/scholia-password.txt
```

Remove the temporary password file securely according to your secret-management
policy. Sign in through the HTTPS origin, open account settings to configure a
provider and API key, and connect your own Canvas token if needed.

A minimal Nginx proxy configuration looks like this; supply your own certificate
paths and normal HTTP-to-HTTPS redirect:

```nginx
server {
    listen 443 ssl;
    server_name scholia.example.com;
    ssl_certificate /etc/ssl/scholia/fullchain.pem;
    ssl_certificate_key /etc/ssl/scholia/privkey.pem;

    client_max_body_size 135m;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $http_host;
        proxy_http_version 1.1;
        proxy_read_timeout 180s;
    }
}
```

The app does not trust arbitrary forwarded headers. Its login limiter sees the
proxy's connection address, so add appropriate authentication rate limits at the
proxy when serving a larger group. `/healthz` returns a small status response;
health probes must also use the configured Host header.

## Accounts and credentials

Create additional accounts with the same command and a different email address.
To reset a password, pass `--reset`; this also revokes the account's existing
sessions:

```sh
docker exec -i scholia node scripts/web-user.mjs \
  --email person@example.com --reset < /secure/path/new-password.txt
```

When running without Docker, use `npm run web:user -- --email …` with the same
`SCHOLIA_DATA_DIR` and `SCHOLIA_SECRET_KEY` as the service. A command pointed at a
different directory creates or changes a different account database.

Passwords are salted and hashed with scrypt. Provider keys and Canvas tokens are
encrypted with AES-256-GCM using a server-held key. Session cookies are HttpOnly,
SameSite=Strict, and Secure on HTTPS; sessions expire after seven days. The
server enforces account ownership for API, document, index, and image access.
These protections separate users from one another, but the server operator can
access files, conversations, and decrypted credentials. They are not end-to-end
encrypted. Publish the operator's retention and contact policy before inviting
users; see [Privacy](PRIVACY.md).

## Backups and upgrades

Back up the entire data directory, including `accounts.sqlite`, any SQLite WAL
files, the `files` tree, and `encryption.key`. If `SCHOLIA_SECRET_KEY` is supplied
externally, back up that secret separately with the same access protections.
Losing or replacing the key makes saved provider and Canvas credentials
unreadable.

For a consistent simple backup, stop the service before copying its data:

```sh
docker stop scholia
mkdir -p backups/scholia
chmod 700 backups/scholia
docker cp scholia:/data/. backups/scholia/
docker start scholia
```

Move backups to protected storage and apply your retention policy. Test a restore
using the same key and an isolated service before relying on it. Preserve file
ownership when restoring. Prior document revisions are retained and consume
storage; do not remove arbitrary files from an active data directory.

Before upgrading, take a backup, build the new image, then replace the container
using the same persistent volume and configuration. Keep the previous image
until the new deployment has passed sign-in, file reading, and provider checks.

## Scope and limits

Hosted web supports workspaces, assignment status and hidden lists, Canvas
catalogs and on-demand downloads, document imports, text/notebook edits, and
conversational tutoring. Saved files live on the server; they are not a browser
offline cache. Native **Practice this**, spaced review, Vision OCR, desktop
capture, local provider bridges, and the Mac's frequent-course preloading are
not hosted features.

Imports are limited to 100 MB per file. Document indexing uses bounded worker
threads and timeouts; accounts also have storage and collection limits. Large
or scanned documents may have incomplete searchable text even when their
original PDF can be displayed. This is a small-service deployment model, not a
claim of unlimited concurrency. Monitor memory, disk usage, backups, and failed
requests as usage grows.

Run the checks before deployment:

```sh
npm run check
npm run build:web
node scripts/smoke-hosted-web.mjs
```

The hosted integration tests check account separation and revision conflicts;
the Chromium smoke checks sign-in, imports, chat, settings, sign-out, and another
account's empty workspace. CI also builds the Docker image and checks the running
container's health endpoint. These checks need no live Canvas or model account.
