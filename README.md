---
title: dispatcher-plugins
subtitle: Ready-built plugins for the dispatcher remote execution system
brand: odcc
---

# dispatcher-plugins

A companion repository to [dispatcher](https://github.com/OpenDigitalCC/dispatcher)
providing ready-built plugins across three categories: management interfaces,
agent scripts, and auth hooks.

Dispatcher is a Perl machine-to-machine remote script execution system using
mTLS for transport security. It allows a control host to run allowlisted
scripts on remote agents over HTTPS, with no SSH involved. This repository
provides the ecosystem of integrations that build on that foundation.

Each plugin is self-contained and independently usable. There is no dependency
between plugins, and no requirement to use more than one.


## Categories

`manager/`
: Tools and interfaces for operators and systems that interact with dispatcher
  via the HTTP API or the CLI. Includes browser-based API interfaces, client
  libraries, collection files for HTTP tools, and CLI wrappers.

`agent-scripts/`
: Ready-built scripts deployable to dispatcher agents. Each script is
  installed via the agent's `scripts.conf` allowlist and executed by the
  dispatcher on request. Scripts cover common management tasks across a
  range of services and operating system functions.

`auth/`
: Auth hooks for deployment on dispatcher or agent hosts. Each hook reads
  request context from stdin as JSON and controls access by exit code.
  Hooks integrate dispatcher with external identity and credential systems.

Full documentation for each category is in its own guide:

- [manager/README.md](manager/README.md)
- [agent-scripts/README.md](agent-scripts/README.md)
- [auth/README.md](auth/README.md)


## Prerequisites

A working dispatcher installation is required. Dispatcher runs on Debian,
Ubuntu, and Alpine Linux. For installation and initial setup, see the
[dispatcher repository](https://github.com/OpenDigitalCC/dispatcher).

Individual plugins may have their own dependencies; these are documented in
each plugin's README.


## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
submitting a plugin. Every plugin must pass the validation script before
a pull request will be accepted:

```bash
tools/validate-plugin <category>/<plugin-name>
```


## Licence

Each plugin carries its own licence file. See the `LICENSE` file within each
plugin directory.
