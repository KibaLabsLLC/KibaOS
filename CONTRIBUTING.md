# Contributing to KibaOS

Thank you for your interest in contributing to **KibaOS**!

KibaOS is a ready-to-use Linux desktop built on Arch Linux with the Budgie desktop environment. Our goal is simple: **nothing should look or feel like it is showing you the plumbing**. Every contribution — whether code, design, documentation, or testing — should help keep that experience calm, coherent, and approachable.

This guide will help you get started.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Ways to Contribute](#ways-to-contribute)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Style Guidelines](#style-guidelines)
- [Pull Request Process](#pull-request-process)
- [Related Projects](#related-projects)
- [Community](#community)
- [License](#license)

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to [corporate@kibaos.com](mailto:corporate@kibaos.com).

## Ways to Contribute

There are many ways to help, and not all of them involve writing code.

### Report Bugs
- Search existing [issues](https://github.com/KibaLabsLLC/KibaOS/issues) first to avoid duplicates.
- Use a clear title and provide steps to reproduce, expected behavior, actual behavior, and relevant system information (hardware, whether you were in the live session or installed, etc.).
- Screenshots or short recordings are very helpful, especially for UI issues.

### Suggest Enhancements
- Open an issue describing the problem you’re trying to solve and why the proposed change would improve the KibaOS experience.
- For larger ideas, start with a discussion so we can align on the approach before significant work begins.

### Improve Documentation
- Fix typos, clarify instructions, or expand the Wiki and README.
- Documentation changes are some of the most valuable contributions.

### Test and Provide Feedback
- Download the latest ISO, try the live session, and report issues.
- Test installation on different hardware (UEFI systems only).
- Help verify that new changes preserve the “no plumbing” design principle.

### Design and Theming
- Icon theme refinements, Plymouth boot splash improvements, motion/animation polish, or visual consistency work are welcome.
- Keep the calm, coherent aesthetic in mind.

### Code Contributions
- Bug fixes, packaging improvements, build script enhancements, and new features that fit the project’s vision.
- Changes to the core build process (`build.sh`) require extra care and discussion.

## Getting Started

1. Read this guide and the [Code of Conduct](CODE_OF_CONDUCT.md).
2. Check existing issues and pull requests.
3. For anything non-trivial, open an issue first to discuss your idea.
4. Fork the repository and create a branch from `main`.

## Development Setup

### Prerequisites
- A Linux system (or a machine capable of running Docker)
- Docker
- At least 15 GB of free disk space
- Git

### Building KibaOS Locally

```bash
git clone https://github.com/KibaLabsLLC/KibaOS.git
cd KibaOS

docker run --rm --privileged \
  -v "$PWD:/w" \
  -e RUN_NUM=local \
  archlinux:latest \
  /w/build.sh
```

The `build.sh` script sets up the Arch Linux base, configures the Budgie desktop, applies KibaOS customizations, builds related components, and produces a bootable ISO.

Official builds are produced via GitHub Actions when changes are merged.

### Testing
- Boot the generated ISO in a UEFI virtual machine (QEMU/KVM recommended) or on real hardware via a USB drive.
- Test both the live session and a full installation.
- Verify that the experience remains simple and that no “plumbing” is exposed to the user.

## Style Guidelines

### Commit Messages
We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`.

Examples:
- `fix(build): correct package list ordering`
- `docs(readme): clarify UEFI requirement`
- `feat(theme): update Plymouth splash animation`

### Code and Scripts
- Prefer clear, readable code over cleverness.
- Shell scripts should be POSIX-friendly where practical and include helpful comments for non-obvious sections.
- Match the style of surrounding code.
- Keep changes focused. Smaller, well-scoped pull requests are easier to review and merge.

### Design Principle
When proposing changes, ask: **Does this make the system feel simpler and more coherent, or does it expose more plumbing?** Favor the former.

## Pull Request Process

1. Fork the repository and create a feature branch from `main`.
2. Make your changes and test them (especially if they affect the build or user-facing experience).
3. Ensure your commits follow the conventional commit style.
4. Open a pull request against the `main` branch.
5. Fill out the pull request template clearly. Link related issues.
6. Be responsive to feedback. Maintainers may request changes.
7. Once approved, a maintainer will merge the pull request.

For significant changes, please open an issue for discussion before starting work.

## Related Projects

KibaOS consists of more than this repository. You may also want to contribute to:

- **[Okami](https://github.com/KibaLabsLLC/Okami)** — The KibaOS app store (Qt / Kirigami / QML)
- **[Roko](https://github.com/KibaLabsLLC/Roko)** — The KibaOS installer (Vala / GTK4)

Check each repository for its own contribution guidelines when applicable.

## Security Issues

If you discover a security vulnerability, please follow the process outlined in [SECURITY.md](SECURITY.md). Do not open a public issue for security reports.

## Community

- Website: [kibaos.com](https://kibaos.com)
- Issues and discussions: [GitHub Issues](https://github.com/KibaLabsLLC/KibaOS/issues)
- Community chat: Discord, Matrix, and Fluxer (links available on the website)

## License

By contributing to KibaOS, you agree that your contributions will be licensed under the [GNU General Public License v3.0](LICENSE).

Thank you for helping make KibaOS a calmer, simpler way to compute. 🐾
