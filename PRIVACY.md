# GTerminal Privacy Policy

**Last updated: August 12, 2026**

GTerminal is built to keep everything on your machine.

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

## Changes

Updates to this policy will appear in this file in the app's public source
repository: https://github.com/guscatalano/GTerminal

## Contact

Questions: gus@guscatalano.com
