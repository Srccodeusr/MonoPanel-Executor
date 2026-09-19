# MonoPanel

MonoPanel is a UI-revamped fork of **JexPanel (Jexactyl)**, which is built
on **Pterodactyl Panel** — a game server management panel. This fork keeps
Jexactyl's functionality intact; the changes here are a front-end/UI revamp
rather than a functional rewrite.

- **Repository:** https://github.com/Srccodeusr/MonoPanel
- **Branch:** `develop` (forked from the original authoritative source,
  changes made on top)
- **License:** MIT — see [`LICENSE.md`](./LICENSE.md)

---

## What's in this repo

- The MonoPanel application itself (Laravel + React/TypeScript, same stack
  as Jexactyl/Pterodactyl).
- `monopanel.sh` — a bash executor that installs, runs, updates, and manages
  MonoPanel and its node daemon (Wings) end-to-end.

## Requirements

- A Linux VPS or container (Ubuntu/Debian or AlmaLinux/Rocky/CentOS/Fedora
  recommended) — real VPS, container, systemd host, and supervisor-managed
  host are all supported by the executor.
- Root access.
- PHP 8.4+, Composer, Node.js 18+, pnpm, MySQL/MariaDB, and Redis — the
  executor will detect and install any of these that are missing.
- A domain name if you plan to use Cloudflare Tunnel for public access.

## Quick start: the executor script

The fastest way to get MonoPanel running is `monopanel.sh`:

```bash
curl -O https://raw.githubusercontent.com/Srccodeusr/MonoPanel/develop/monopanel.sh
chmod +x monopanel.sh
sudo ./monopanel.sh
```

You'll get a numbered, colour-coded menu:

| # | Option | What it does |
|---|--------|---------------|
| 1 | **Install Panel** | Full install: checks/installs dependencies, clones the `develop` branch, asks for DB + app + admin credentials, runs migrations, creates the admin account, builds the frontend, sets permissions, configures cron, and sets up a queue worker. Works on real VPS, containers, systemd, or supervisor setups. |
| 2 | **Run Panel** | Sub-menu: **Run Production Mode** (persistent service via systemd/supervisor) or **Run Development Mode** (Laravel + Vite dev servers with hot reload). |
| 3 | **Configure Nodes** | Interactively creates a node in the panel and generates its Wings (daemon) configuration file. |
| 4 | **Start the Nodes** | Installs Docker + Wings if needed and starts the node daemon as a managed service. |
| 5 | **Connect Cloudflared** | Installs `cloudflared`, connects a Cloudflare Tunnel using your tunnel token, and points your domain at the panel. |
| 6 | **Update Panel** | Pulls the latest changes from GitHub (`develop`), rebuilds, re-migrates, and restarts services — safe to re-run any time. |
| 7 | Status / Info | Shows current install state, git commit, detected environment, and panel info. |

Logs for every run are written to `/var/log/monopanel-executor.log` for
troubleshooting.

## Manual installation

If you'd rather not use the executor, standard Jexactyl/Pterodactyl
installation steps apply — clone the repo, `composer install`, `pnpm
install && pnpm build`, configure `.env`, `php artisan migrate --seed`,
create an admin user with `php artisan p:user:make`, and point a
webserver at `public/`. See the Pterodactyl/Jexactyl documentation for the
underlying panel mechanics, since MonoPanel does not change them.

## Features

- Advanced authentication and security setup
- Integrated billing (Stripe + PayPal)
- Clean, revamped administrative interface
- Built with PHP, Laravel, TypeScript, React, and Docker
- Fully open-source

## Credits

MonoPanel is owned and maintained by **prime.dev1**, who forked JexPanel to
build a customised panel for his hosting business and commercial use. This
is a UI revamp on top of the JexPanel codebase, not a functional rewrite.

Full credit for the underlying panel goes to:

- **[Jexactyl](https://github.com/jexactyl/jexactyl)** and its contributors,
  whose codebase MonoPanel is directly forked from.
- **[Pterodactyl Panel](https://pterodactyl.io)**, created by Dane Everitt
  and contributors, which Jexactyl itself is built on.
- The wider open-source hosting-panel community.

Thank you to the original authors and everyone who has contributed to the
projects this one stands on.

The `monopanel.sh` executor script was generated with the assistance of
Claude (Anthropic).

## License

MIT — full text and upstream attributions in [`LICENSE.md`](./LICENSE.md).
