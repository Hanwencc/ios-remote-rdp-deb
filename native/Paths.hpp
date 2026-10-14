#pragma once

#ifndef RI_ROOT_PREFIX
#define RI_ROOT_PREFIX "/var/jb"
#endif

namespace paths {
constexpr const char *directory = RI_ROOT_PREFIX "/var/lib/remoteipad";
constexpr const char *config = RI_ROOT_PREFIX "/var/lib/remoteipad/config.json";
constexpr const char *status = RI_ROOT_PREFIX "/var/lib/remoteipad/status.plist";
constexpr const char *socket = RI_ROOT_PREFIX "/var/lib/remoteipad/control.sock";
constexpr const char *bundle = RI_ROOT_PREFIX "/Library/PreferenceBundles/RemoteIPad.bundle";
constexpr const char *initial = RI_ROOT_PREFIX "/usr/share/remoteipad/initial.json";
}
