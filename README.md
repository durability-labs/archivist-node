# Decentralized Durability Engine

> The Archivist project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)


## Build and Run

To build the project, clone it and run:

```bash
make update && make
```

The executable will be placed under the `build` directory under the project root.

Run the node with:

```bash
build/archivist
```

## Configuration

It is possible to configure an Archivist node in several ways:
 1. CLI options
 2. Environment variables
 3. Configuration file

The order of priority is the same as above: CLI options --> Environment variables --> Configuration file.

## API

The node exposes a REST API that can be used to interact with it. [Overview of the API](https://durability-labs.github.io/archivist-node).

## Contributing and development

Feel free to dive in, contributions are welcomed! Open an issue or submit PRs.

### Linting and formatting

We use [nph](https://github.com/arnetheduck/nph) for formatting our code and it is required to adhere to its styling.
If you are setting up fresh setup, in order to get `nph` run `make build-nph`.
In order to format files run `make nph/<file/folder you want to format>`. 
If you want you can install Git pre-commit hook using `make install-nph-commit`, which will format modified files prior committing them. 
If you are using VSCode and the [NimLang](https://marketplace.visualstudio.com/items?itemName=NimLang.nimlang) extension you can enable "Format On Save" (eq. the `nim.formatOnSave` property) that will format the files using `nph`.