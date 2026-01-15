# HexBSD

A macOS application for managing FreeBSD servers over SSH.

## Features

- SSH connection management
- ZFS pool and dataset management
- Boot environments
- Jail management
- Package management
- Service control
- User and group administration
- Network configuration
- File browser with transfer support
- Poudriere build management
- bhyve VM management
- VNC viewer
- Integrated terminal
- Security vulnerability reporting

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later

## Building

1. Clone the repository:
   ```
   git clone https://github.com/hexbsd/hexbsd.git
   cd hexbsd
   ```

2. Open the project in Xcode:
   ```
   open HexBSD.xcodeproj
   ```

3. Select your signing team in the project settings (Signing & Capabilities)

4. Build and run with `Cmd+R` or Product > Run

## License

BSD 2-Clause. See [LICENSE](LICENSE) for details.
