# Client launch: Admin1, Google login and Render

The current GitHub Pages site displays the README. GitHub Pages is static hosting and cannot execute Django or provide the shared ERP database. The repository now includes a public entry page plus a Render Blueprint for the actual application and PostgreSQL.

## Prepared account

| Setting | Value |
|---|---|
| Username and display name | `Admin1` |
| Google sign-in email | `inventory.choco@gmail.com` |
| Company | `Binderclip` |
| Initial role | Company administrator, full company access |
| Other active users on a fresh deployment | None |
| Password | None; Google verifies the user's existing account |

The pre-deploy command creates this account and the empty company automatically. It creates Operations, Finance and Read-only role presets, **not extra users or sample transactions**. Repeated deployments preserve existing user/role changes. `--disable-demo` deactivates only the known local demonstration identity and its memberships, preserving history. It does not delete unrelated users or issued accounting records.

## 1. Publish the prepared repository

Push the changes to `https://github.com/flyingpensil/Binderclip`. The root `index.html` replaces README rendering for Pages configured to publish from the root branch. The supplied Pages workflow publishes only the entry page and its public assets if Pages is configured to use GitHub Actions.

No Google client secret, database password, or application secret belongs in GitHub, the public Pages files, Actions variables for the public app URL, or a client browser bundle.

## 2. Create the Google OAuth web client

In [Google Cloud Console](https://console.cloud.google.com/), select or create the project for Binderclip. Configure Google Auth Platform branding and audience, then create an OAuth client of type **Web application**. Use an External audience when signing in with this consumer Gmail account. If the app is in testing, add `inventory.choco@gmail.com` as a test user. Add future client users to Google's test audience as well until the Google application is published for its intended audience.

For a local login test, register:

```text
Authorized redirect URI: http://127.0.0.1:8001/auth/google/callback/
Authorized JavaScript origin: http://127.0.0.1:8001
```

The server-side OAuth flow requires the exact redirect URI. The JavaScript origin is provided for clarity; this implementation does not use a browser-side Google token SDK. Keep the client secret in your password/secret manager until it is entered in Render.

## 3. Create the Render application

1. Sign in to [Render](https://dashboard.render.com/) and connect the GitHub repository.
2. Choose **New → Blueprint**, select `flyingpensil/Binderclip` and use `render.yaml` from the repository root.
3. Review the paid compute plans before applying: one small web service (`0.5c-512mb`, formerly Starter) and one PostgreSQL instance (`0.1c-256mb`, formerly Basic-256mb), both in Frankfurt. The Blueprint is prepared only; no services or charges are created just by committing it. Review Render's current pricing in its dashboard.
4. Enter the **Google OAuth Client ID** and **Google OAuth Client Secret** when prompted for `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Render generates `SECRET_KEY` and supplies the database URL automatically.
5. Apply the Blueprint. The build installs dependencies and collects static assets. The pre-deploy step migrates PostgreSQL and provisions Admin1. Gunicorn then serves the application over Render's HTTPS hostname.
6. Copy the **actual service URL** shown by Render. Do not assume that `binderclip.onrender.com` is available: Render may assign another hostname.

Public database access is disabled by the Blueprint. The web service uses the database's internal connection string with TLS required. `DEBUG=false`, `DEMO_LOGIN=false`, secure cookies and trusted Render proxy handling are configured. Django automatically recognizes Render's assigned hostname.

## 4. Finish the exact Google callback

For the actual Render URL, register these values in the same Google OAuth web client:

```text
Authorized redirect URI: https://YOUR-ACTUAL-HOST.onrender.com/auth/google/callback/
Authorized JavaScript origin: https://YOUR-ACTUAL-HOST.onrender.com
```

`GOOGLE_REDIRECT_URI` defaults to the correct callback using `RENDER_EXTERNAL_HOSTNAME`. For a custom domain, set `APP_BASE_URL=https://your-domain.example`, register that exact callback in Google, and configure the custom domain with Render. A mismatch yields Google's `redirect_uri_mismatch` error; a GitHub Pages URL is not the Django callback.

In the Render Shell, run:

```sh
python manage.py check_login --strict
python manage.py check --deploy
```

The readiness command prints configuration status and exact callback/origin values without printing credentials. The supplied GitHub Actions workflow is the primary PostgreSQL test environment. Run `python manage.py test erp.tests --verbosity 2` only against an isolated validation database/CI environment: Django's test runner creates and deletes a separate `test_...` database. If the managed database role cannot create test databases, run tests in CI instead of widening its production privileges.

Open the actual application URL and sign in using Google account `inventory.choco@gmail.com`. The profile should show **Admin1**. There should be no demo-access button or sample transactions in this fresh company.

## 5. Connect the existing GitHub Pages address

The public entry page deliberately has no login link until a real backend URL is configured. It never displays fake authenticated ERP screens.

Preferred with the supplied Pages workflow:

1. In GitHub repository **Settings → Pages**, choose **GitHub Actions** as the build/deployment source.
2. In **Settings → Secrets and variables → Actions → Variables**, add repository variable `BINDERCLIP_APP_URL` with the actual HTTPS Render origin, e.g. `https://YOUR-ACTUAL-HOST.onrender.com`. This URL is public; it is not an OAuth secret.
3. Run **Publish client entry page** from the Actions tab. The workflow packages the public page, CSS, JavaScript, favicon and a JSON file containing that origin only.

Alternatively, for branch-based Pages deployment, put the actual HTTPS origin in the committed `deployment.json`:

```json
{"appUrl": "https://YOUR-ACTUAL-HOST.onrender.com"}
```

The existing `https://flyingpensil.github.io/Binderclip/` then becomes the client-facing entry point. **Sign in to Binderclip** sends users to the real application; Google sign-in and ERP data stay on that application origin. This avoids cross-origin session-cookie complexity.

## 6. Demonstrate adding a client user

Admin1 signs in, opens **Users & access → Add user**, and enters the client's exact Google email, display name and branch. Assign **Read-only**, **Operations**, **Finance**, or a custom role. Save, then share the real application sign-in URL with the client. They can open it on their own computer and select **Continue with Google**.

Saving access does not send an invitation email. A client not yet in the company is rejected, even if Google authentication succeeds. If the Google OAuth application is still in testing, also add the client's email to Google's test-user list.

For now only Admin1 is provisioned. No client account is guessed or added without an email. The client-user creation and read-only restrictions are exercised in automated tests without adding a real second user to the live workspace.

## Verification and current boundary

Local tests validate provisioning, idempotence, no sample transactions, demo denial, member creation, role restrictions, tenant isolation, and public-only Pages packaging. Actual Render deployment, PostgreSQL CI success and real Google sign-in need verification after your accounts and credentials are connected. Client users see all **implemented** modules according to their assigned role; [release-scope.md](release-scope.md) still lists the accounting features that have not been implemented. Removing a demo label does not turn those remaining features into completed functionality.

References: [GitHub Pages limitations](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site), [Render Django deployment](https://render.com/docs/deploy-django), [Render Blueprint specification](https://render.com/docs/blueprint-spec), [Render compute plans](https://render.com/docs/compute-plans), [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect).
