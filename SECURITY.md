# Security

## Reporting a vulnerability

Report it privately through **Security › Report a vulnerability** on this repository (GitHub private vulnerability reporting). Please do not open a public issue for it.

Include the version, the platform (Android or Windows), what an attacker needs (same network, a paired device, local access) and the steps to reproduce.

Only the latest release receives fixes.

## What Alero defends

- **Other devices on the network** cannot read or change anything: every connection is TLS with both sides authenticated by the identities exchanged when pairing.
- **A paired device** only gets what the owner switched on. Remote control, the second screen and shared folders on Windows are off by default, as are SMS, calls and notification access on Android. The computer shows a notice whenever a phone watches its screen or drives its input.
- **Other users of the same computer** cannot drive the engine: the local control port takes a random token stored in the user's own data folder.

## Out of scope

- An attacker who already controls an unlocked, paired device or the user's account on the computer.
- USB debugging and wireless debugging, which the phone's owner authorises in Android and which give the authorised computer full control by design.
