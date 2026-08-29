# GTerminal Privacy Policy

**Last updated: August 29, 2026**

GTerminal is built to keep everything on your machine. The only things it
ever sends anywhere are listed below, and each of them is either off by
default or can be turned off.

## What we collect

Nothing. GTerminal has no telemetry, no analytics, no crash reporting, no
accounts, and no ads. The developer receives no data from the app, ever.

## What stays on your device

Everything the app needs lives locally under `%LOCALAPPDATA%\GTerminal`:

- **Session checkpoints** — scrollback, working directories, and session
  metadata, saved so your terminals survive restarts and reboots.
- **Configuration** — themes, fonts, shell preferences, and settings.

The background daemon that keeps sessions alive listens on localhost only and
is never reachable from the network.

## The optional AI endpoint

The tab-title suggestion feature works entirely locally by default. You may
optionally configure your own AI endpoint (an Anthropic- or OpenAI-compatible
URL, including local gateways such as Ollama) in Settings. Only if you do:

- Short excerpts of terminal content are sent **to the endpoint you chose**
  when you request AI title suggestions (or enable auto-titles).
- Your API key, if you enter one, is stored locally and sent only to that
  endpoint.
- The developer never sees this traffic. Clearing the endpoint in Settings
  fully disables the feature; it is blank by default and nothing is ever
  called until you configure it.

## Checking for updates (installer builds only)

Builds installed from the Microsoft Store are updated by the Store, and never
contact anything themselves.

A build installed from the project's own installer asks GitHub which versions
have been published, so it can offer newer ones and let you go back to older
ones. That request goes to `api.github.com`, carries nothing but the app's
name and version, and is not to a service of the developer's. Turn it off with
**Update automatically** in Settings, and no request is made. Installers are
only ever downloaded from this project's own releases.

## Weather and air quality (off by default)

The status bar can show the weather and air quality for a postcode. It is
blank by default, and while it is blank **nothing is requested at all**.

If you enter one:

- The postcode goes to **Zippopotam** (`api.zippopotam.us`) to become
  coordinates.
- Those coordinates go to **Open-Meteo** (`api.open-meteo.com` and
  `air-quality-api.open-meteo.com`) for the forecast and air quality.

Neither needs an account or an API key, so there is no identifier tying those
requests to you or to each other. The developer never sees this traffic and
receives nothing. Clearing the postcode fully disables it. A postcode is the
most locating thing this app would ever send anywhere, which is exactly why it
is off until you ask for it.

## Changes

Updates to this policy will appear in this file in the app's public source
repository: https://github.com/guscatalano/GTerminal

## Contact

Questions: gus@guscatalano.com
