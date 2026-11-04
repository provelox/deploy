<p align="center"><img src="assets/logo.svg" alt="Provelox" height="56"></p>

# Provelox Deploy

A GitHub Action that rolls a [Provelox](https://provelox.com) app onto a new image and waits for the deploy to settle. The step fails if the deploy fails, so a broken release stops your pipeline.

## Usage

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # ...build and push your image here...

      - uses: provelox/deploy@v1
        with:
          server-url: https://api.example.com
          deploy-key: ${{ secrets.PROVELOX_DEPLOY_KEY }}
          image: ghcr.io/acme/web:${{ github.sha }}
```

## Setup

1. In the Provelox console, open the app and create a **deploy key**. It is shown once.
2. Add it to your repository as a secret, for example `PROVELOX_DEPLOY_KEY`.
3. Note your API address: `https://api.<your domain>` unless you installed with `--api-host`.
4. Add the step above to your workflow.

A deploy key belongs to one app and can only roll that app to a new version of its own image. If the key leaks, it cannot run something else with the app's secrets and data. You can revoke it at any time.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `server-url` | yes | | Base URL of your Provelox **API**, such as `https://api.example.com`. By default that is `api.<your domain>` (what you gave `--root-domain`), not the console's address. |
| `deploy-key` | yes | | The app's deploy key. |
| `image` | yes | | Image to deploy, such as `ghcr.io/acme/web:1.4.2`. |
| `wait` | no | `true` | Wait for the deploy to settle and fail the step if it fails. |
| `timeout` | no | `600` | Seconds to wait before failing the step. |

## Outputs

| Output | Description |
| --- | --- |
| `app` | Name of the app that was deployed. |
| `version` | Deploy version Provelox assigned. |
| `image` | Image the app is now rolling onto. |

## Coming from CapRover?

The shape is the same: a server URL, a credential kept in a secret, and an image to deploy. Create a deploy key in Provelox where you would have used an app token, and point `server-url` at your Provelox server.

## What it does, and when the step fails

The step starts the deploy, prints Provelox's progress as it happens, and ends when the app is running.

| What happens | The step |
| --- | --- |
| The new version starts and stays up | passes |
| Docker rolls the update back, or the containers keep failing | fails, with Docker's reason |
| The deploy does not settle within `timeout` | fails (the deploy may still finish: check the app in Provelox) |
| The key is wrong, revoked, or the image is another repository's | fails at once, with Provelox's own message |
| Provelox is restarted while the deploy runs (an update, for one) and forgets it | fails: it cannot say whether the deploy worked, and a pipeline must not report success it did not see |
| A newer deploy of the same app replaces this one before it settles | fails, naming the newer deploy |
| The server or a proxy in front of it is briefly unreachable while waiting | keeps waiting (about a minute), then fails |

Each request is limited to 30 seconds, so a server that accepts the connection and never answers cannot hold the job.

If two runs deploy the same app at the same time, Provelox follows the newer one; the older step fails and says so. Use a [`concurrency`](https://docs.github.com/actions/using-jobs/using-concurrency) group in your workflow to run deploys one at a time.

## Requirements

Runs on GitHub-hosted Linux and macOS runners, or any runner with `bash`, `curl` and `jq`.

## License

Apache-2.0. See [LICENSE](LICENSE).
