# LangDocker

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)]()
[![PowerShell](https://img.shields.io/badge/Docker-28%2B-cyan.svg)]()

LangRunner is a **local-first developer tool** that allows seamless execution of code files in multiple programming languages using Docker, as if the **languages were installed locally**. It auto-detects the language by file extension, uses default or configurable Docker images, and runs the code inside lightweight containers with timeout and resource constraints. Supports easy extension to new languages via a simple config file.

---

## Features

- Executes code files in isolated Docker containers
- Language-agnostic: supports multiple programming languages via config
- Automatic language detection by file extension
- Resource-limited container execution (CPU, memory, timeout)
- Secure execution with limited network and file system access
- Logging with flexible verbosity and output modes
- Dynamic PowerShell functions for easy use
- Supports running commands from both PowerShell and Command Prompt
- Simple installation and setup scripts included

---

## Project Structure

```
.
│   README
│
├───.runlang
│       RunLang.psm1
│
├───config
│       langdocker.env
│       lang_docker_config.json
│
├───runlang-cmd-wrapper
│       runlang.cmd
│
└───scripts
        setup.ps1
```

---

## Requirements

- Windows PowerShell 5.1 or newer (including PowerShell 7+)
- [Docker](https://www.docker.com/) installed and running
- Administrator permissions (for initial setup to modify PATH)
- Internet connection for pulling Docker images (initial setup)

---

## Installation

1. Clone or download this repository.

2. Run the setup script from an **elevated PowerShell prompt** (Run as Administrator):

```
.\scripts\setup.ps1
```

3. The setup script will:

   - Install the `RunLang` PowerShell module to your user modules directory
   - Add a command wrapper script (`runlang.cmd`) to a `bin` directory
   - Add that `bin` directory to your system or user PATH environment variable
   - Add auto-import of the module to your PowerShell profile

4. Restart all terminals (PowerShell, cmd.exe, etc.) for changes to take effect.

---

## Usage

### Run a code file by extension

Use the `runlang` command to execute source files based on their extension without specifying the language explicitly.

```

runlang path\to\your\file.go
runlang path\to\your\file.py
runlang path\to\your\file.js

```

### Run explicitly via language function

If your LangDocker config defines dynamic language functions (e.g., `go`, `python`), you can also run:

```

go path\to\your\file.go
python path\to\your\file.py

```

### Configuration

- Modify `lang_docker_config.json` to add or customize language/docker image settings, commands, resource limits, etc.
- Override configuration and paths via the `.env` file (`langdocker.env`).

### Logs

- Logs are stored in the `logs` directory inside `langdocker.log`.
- Console logging can be enabled in the `.env` file by setting `LANGDOCKER_LOG_TO_CONSOLE=true`.

---

## Customization

- Add languages by editing the JSON config with image names, commands, file extensions.
- Tune resource limits like CPU, memory, and command timeout in config.
- Customize security constraints by modifying Docker run options in the module.

---

## Troubleshooting

- Ensure Docker is installed, running, and available in your system PATH.
- If `runlang` commands do not work, check that your `bin` directory is included in your system/user PATH.
- View logs in `logs/langdocker.log` for diagnostic information.
- If module auto-import fails, verify that your PowerShell profile includes the import line:

```
Import-Module RunLang -Force -Verbose
```

- For issues with Docker image pulling, check your internet connection and Docker daemon status.

---

## License

[MIT License](LICENSE)

---

## Contributing

Contributions, issues, and feature requests are welcome! Please open an issue or submit a pull request on GitHub.

---

## Acknowledgments

- Powered by [Docker](https://www.docker.com/)
- Inspired by containerized code execution environments and secure sandboxing best practices

---

_Happy coding within containers! 👨‍💻_
