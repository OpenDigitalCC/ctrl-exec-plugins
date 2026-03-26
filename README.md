---
title: exec-plugins
subtitle: Ready-built plugins for the ctrl-exec remote execution system
brand: odcc
---

# exec-plugins

A companion repository to [ctrl-exec](https://github.com/OpenDigitalCC/ctrl-exec)
providing ready-built plugins across three categories: management interfaces,
agent scripts, and auth hooks.

ctrl-exec is a Perl machine-to-machine remote script execution system using
mTLS for transport security. It allows a control host to run allowlisted
scripts on remote agents over HTTPS, with no SSH involved. This repository
provides the ecosystem of integrations that build on that foundation.

Each plugin is self-contained and independently usable. There is no dependency
between plugins, and no requirement to use more than one.


## Categories

`ce-api-plugins/`
: Tools and interfaces for operators and systems that interact with ctrl-exec
  via the HTTP API or the CLI. Includes browser-based API interfaces, client
  libraries, collection files for HTTP tools, and CLI wrappers.

`ce-agent-plugins/`
: Ready-built scripts deployable to ctrl-exec agents. Each script is
  installed via the agent's `scripts.conf` allowlist and executed by ctrl-exec
 Scripts cover common management tasks across a
  range of services and operating system functions.

`ce-auth-plugins`
: Auth hooks for deployment on ctrl-exec or agent hosts. Each hook reads
  request context from stdin as JSON and controls access by exit code.
  Hooks integrate ctrl-exec with external identity and credential systems.

Full documentation for each category is in its own guide:

- [ce-api-plugins/README.md](ce-api-plugins/README.md)
- [ce-agent-plugins/README.md](ce-agent-plugins/README.md)
- [ce-auth-pluginsREADME.md](ce-auth-pluginsREADME.md)


## Prerequisites

A working ctrl-exec installation is required. ctrl-exec runs on Debian,
Ubuntu, and Alpine Linux. For installation and initial setup, see the
[ctrl-exec repository](https://github.com/OpenDigitalCC/ctrl-exec).

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
