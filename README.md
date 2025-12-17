# Decentralized Durability Engine

> The Archivist project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)

## Download

### Binaries
Release binaries are available for several platforms on the [Github Release Page](https://github.com/durability-labs/archivist-node/releases/).

1. Download the binaries for your platform.
1. Unpack in an install location of your choice.
1. Skip to [Configuration](#configuration).

### Docker
Docker images are available for each released version. Images are tagged as follows: `durabilitylabs/archivist-node:<VERSION NUMBER>`

For example: `durabilitylabs/archivist-node:0.1.0`

We recommend configuring your Archivist docker container using environment variables. Here is an example [docker-compose.yaml](./docker/docker-compose.yaml)

> WARNING: Release binaries and docker images are built with common CPU instruction sets and may not be optimal for your system. To get the best performance out of Archivist, we recommend you [build from sources](#build).

## Build

### Prerequisites

The following should be installed before building the node:
- [Nim][nim] 2.2.4
- [Cmake][cmake] 3.x
- [Rust][rustup] 1.79.0
- Optional: [NodeJS][nodejs] 22.x, only required for some tests

### Windows

Building in windows requires the following additional setup:
- install [Mingw64][mingw], e.g. in `C:\mingw64`
  - download the `release-posix-seh-uct` variant from the
    [release page][mingw], and unzip to e.g. `C:\mingw64`
  - create a symbolic link from `mingw32-make.exe` to `make.exe`, e.g:
    - `cd C:\mingw64\bin`
    - `ln -s mingw32-make.exe make.exe`
- install [Msys2][msys], e.g. in `C:\msys64`
- setup Nim to use mingw for building
  - When following the Nim installation instructions, ensure that `finish.exe`
    does not download mingw. It should use the mingw that you just installed
    yourself instead.
- setup Rust to use mingw for building
  - `rustup install stable-x86_64-pc-windows-gnu`
  - `rustup default stable-x86_64-pc-windows-gnu`
- setup PATH
  - ensure that your mingw folder occurs before the msys2 folder, e.g:
    `C:\mingw64\bin;C:\msys64\usr\bin`
  - if you have WSL installed, ensure that the WSL binaries occur after the
    mingw and msys2 folders, e.g:
    `C:\mingw64\bin;C:\msys64\usr\bin;%USERPROFILE%\AppData\Local\Microsoft\WindowsApps`
  - if you have WSL installed and your C:\Windows\System32 contains bash.exe
    you're on an old version of WSL and the Archivist build will not work until
    it is uninstalled

> Note: the commands in the rest of this document should be executed in
> powershell or cmd, not in an msys shell.

[nim]: https://nim-lang.org/
[cmake]: https://cmake.org/download/
[rustup]: https://rustup.rs/
[nodejs]: https://nodejs.org/en/download
[mingw]: https://github.com/niXman/mingw-builds-binaries/releases
[msys]: https://www.msys2.org/

### Build

To build the project, clone it and run:

```bash
nimble build
```

The executable will be placed under the `build` directory under the project root.

## Configuration

It is possible to configure an Archivist node in several ways:
 1. CLI options
 2. Environment variables
 3. Configuration file

The order of priority is the same as above: CLI options --> Environment variables --> Configuration file.

### Setup

Archivist comes with a guided setup tool. This will generate a configuration file for you.

```bash
build/setup
```

## Run

Run the archivist executable to start the node:

```bash
build/archivist
```

## API

The node exposes a REST API that can be used to interact with it. [Overview of the API](https://durability-labs.github.io/archivist-node).

## Contributing and development

Feel free to dive in, contributions are welcomed! Open an issue or submit PRs.

### Linting and formatting

We use [nph](https://github.com/arnetheduck/nph) for formatting our code and it
is required to adhere to its styling. In order to format files run `nimble
format`. If you are using VSCode and the
[NimLang](https://marketplace.visualstudio.com/items?itemName=NimLang.nimlang)
extension you can enable "Format On Save" (eq. the `nim.formatOnSave` property)
that will format the files using `nph`.
