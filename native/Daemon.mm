#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#include "Management.hpp"
#import "RDP.h"
#import "Configuration.h"
#include <winpr/ntlm.h>
#include <sys/stat.h>
#include <signal.h>
#include <dlfcn.h>
#include <mutex>
#include <thread>

static NSString *directoryPath = [NSString stringWithUTF8String:paths::directory];
static NSString *configPath = [NSString stringWithUTF8String:paths::config];
static NSString *statusPath = [NSString stringWithUTF8String:paths::status];
static volatile sig_atomic_t terminating = 0;
static void terminate(int) { terminating = 1; }

static NSDictionary *dictionary(NSData *data, NSError **error) {
    if (!data) return nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![result isKindOfClass:NSDictionary.class]) {
        management::failure(error, @"配置或管理消息必须为 JSON 对象");
        return nil;
    }
    return result;
}

static NSString *persistConfiguration(NSDictionary *config) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:&error];
    if (!data || ![data writeToFile:configPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"RemoteIPad configuration persistence failed: %@", error);
        return @"无法保存配置";
    }
    if (chmod(configPath.fileSystemRepresentation, 0600) != 0) {
        NSLog(@"RemoteIPad configuration permissions failed: %s", strerror(errno));
        return @"无法设置配置文件权限";
    }
    return nil;
}

static NSData *derive(NSString *password, NSData *salt) {
    NSData *utf8 = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *hash = [NSMutableData dataWithLength:32];
    int result = CCKeyDerivationPBKDF(kCCPBKDF2, static_cast<const char *>(utf8.bytes),
        utf8.length, static_cast<const uint8_t *>(salt.bytes), salt.length,
        kCCPRFHmacAlgSHA256, 310000, static_cast<uint8_t *>(hash.mutableBytes), hash.length);
    if (result) {
        NSLog(@"RemoteIPad password derivation failed: %d", result);
        return nil;
    }
    return hash;
}

class Manager {
    __strong NSMutableDictionary *configuration;
    __strong RIEngine *engine;
    __strong RIRDPServer *server;
    __strong NSString *serviceError = @"";
    std::mutex configurationMutex, snapshotMutex;
public:
    explicit Manager(NSDictionary *config) : configuration([config mutableCopy]),
        engine([[RIEngine alloc] initWithConfig:config]) {
        [engine setStreaming:NO];
    }

    NSString *startRemote() {
        [server stop]; server = nil;
        server = [[RIRDPServer alloc] initWithConfig:configuration engine:engine directory:directoryPath];
        serviceError = [server start] ?: @"";
        if (serviceError.length) {
            NSLog(@"RemoteIPad service start failed: %@",serviceError);
            return serviceError;
        }
        return nil;
    }

    void stop() {
        std::lock_guard<std::mutex> guard(configurationMutex);
        [server stop]; server = nil;
    }

    NSDictionary *status() {
        std::lock_guard<std::mutex> guard(configurationMutex);
        NSMutableDictionary *state = [[engine status] mutableCopy];
        NSString *captureError = state[@"error"];
        NSDictionary *transport = server ? [server status] : @{@"listening":@NO,@"clientConnected":@NO};
        [state addEntriesFromDictionary:transport];
        BOOL enabled = [configuration[@"enabled"] boolValue];
        state[@"managerRunning"] = @YES;
        state[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
        state[@"version"] = @"0.4.0~rc7";
        state[@"protocol"] = @"rdp-nla-avc420";
        state[@"port"] = @3389;
        state[@"service"] = !enabled ? @"disabled" : [transport[@"listening"] boolValue] ? @"running" : @"failed";
        state[@"enabled"] = @(enabled);
        state[@"transportAvailable"] = @YES;
        state[@"username"] = configuration[@"username"];
        NSString *transportError = transport[@"error"];
        if (serviceError.length) state[@"error"] = serviceError;
        else if (!transportError.length && enabled && captureError.length) state[@"error"] = captureError;
        else if (!transportError.length && !enabled) state[@"error"] = @"";
        return state;
    }

    void snapshot() {
        std::lock_guard<std::mutex> guard(snapshotMutex);
        NSString *logFile = [directoryPath stringByAppendingPathComponent:@"service.log"];
        const char *logPath = logFile.fileSystemRepresentation;
        struct stat info{};
        if (stat(logPath, &info) == 0 && info.st_size > 2 * 1024 * 1024) {
            if (rename(logPath, [directoryPath stringByAppendingPathComponent:@"service.log.previous"].fileSystemRepresentation) != 0)
                NSLog(@"RemoteIPad log rotation failed: %s", strerror(errno));
            else {
                int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
                if (fd < 0) NSLog(@"RemoteIPad log reopen failed: %s", strerror(errno));
                else {
                    if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0)
                        NSLog(@"RemoteIPad log descriptor replacement failed: %s", strerror(errno));
                    close(fd);
                }
            }
        }
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:status()
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        if (!data || ![data writeToFile:statusPath options:NSDataWritingAtomic error:&error])
            NSLog(@"RemoteIPad status snapshot failed: %@", error);
        else if (chmod(statusPath.fileSystemRepresentation, 0644) != 0)
            NSLog(@"RemoteIPad status permissions failed: %s", strerror(errno));
    }

    NSString *credentials(NSDictionary *body) {
        NSString *name = body[@"username"], *password = body[@"password"];
        if (![name isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class] ||
            name.length < 1 || name.length > 64 || password.length < 12 || password.length > 256 ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":\\"]].location != NSNotFound)
            return @"用户名须为 1–64 位，新密码须为 12–256 位";
        uint8_t saltBytes[32];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(saltBytes), saltBytes) != errSecSuccess)
            return @"安全随机数生成失败";
        NSData *salt = [NSData dataWithBytes:saltBytes length:sizeof(saltBytes)];
        NSData *hash = derive(password, salt);
        if (!hash) return @"密码哈希生成失败";
        NSData *utf8 = [password dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t nt[16]{};
        if (!NTOWFv1A(static_cast<const char *>(utf8.bytes),uint32_t(utf8.length),nt))
            return @"NLA 密码哈希生成失败";
        NSMutableString *ntHash = [NSMutableString stringWithCapacity:32];
        for (auto byte : nt) [ntHash appendFormat:@"%02x",byte];
        volatile uint8_t *clear = nt;
        for (unsigned i=0; i<sizeof(nt); ++i) clear[i]=0;
        NSMutableDictionary *updated = [configuration mutableCopy];
        updated[@"username"] = name;
        updated[@"salt"] = [salt base64EncodedStringWithOptions:0];
        updated[@"passwordHash"] = [hash base64EncodedStringWithOptions:0];
        updated[@"iterations"] = @310000;
        updated[@"ntHash"] = ntHash;
        updated[@"schemaVersion"] = @3;
        updated[@"port"] = @3389;
        NSString *error = persistConfiguration(updated);
        if (error) return error;
        configuration = updated;
        [server stop]; server = nil;
        if ([configuration[@"enabled"] boolValue]) return startRemote();
        return nil;
    }

    NSDictionary *manage(NSDictionary *body) {
        NSString *error = nil;
        {
            std::lock_guard<std::mutex> guard(configurationMutex);
            id operation = body[@"op"];
            if ([operation isEqual:@"setEnabled"]) {
                id value = body[@"enabled"];
                if (![value isKindOfClass:NSNumber.class] ||
                    CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
                    error = @"服务开关必须为布尔值";
                else {
                    bool desired = [value boolValue];
                    bool previous = [configuration[@"enabled"] boolValue];
                    if (desired && (!previous || ![[server status][@"listening"] boolValue]))
                        error = startRemote();
                    NSMutableDictionary *updated = [configuration mutableCopy];
                    updated[@"enabled"] = @(desired);
                    if (!error) error = persistConfiguration(updated);
                    if (!error) {
                        configuration = updated;
                        if (!desired) { [server stop]; server = nil; serviceError = @""; }
                    } else if (!previous) { [server stop]; server = nil; }
                }
            } else if ([operation isEqual:@"setCredentials"]) error = credentials(body);
            else if (![operation isEqual:@"status"]) error = @"未知管理操作";
        }
        snapshot();
        if (error) {
            NSLog(@"RemoteIPad management operation failed: %@", error);
            return @{@"error": error};
        }
        return @{@"ok": @YES, @"state": status()};
    }

    bool start() {
        if ([configuration[@"enabled"] boolValue]) startRemote();
        auto processPath = reinterpret_cast<int (*)(int, void *, uint32_t)>(
            dlsym(RTLD_DEFAULT, "proc_pidpath"));
        if (!processPath) {
            NSLog(@"RemoteIPad management peer verification unavailable"); return false;
        }
        struct stat existing{};
        if (lstat(management::socketPath, &existing) == 0) {
            if (!S_ISSOCK(existing.st_mode) || existing.st_uid != 0 || unlink(management::socketPath)) {
                NSLog(@"RemoteIPad unsafe or unavailable management socket path"); return false;
            }
        } else if (errno != ENOENT) {
            NSLog(@"RemoteIPad management path check failed: %s", strerror(errno)); return false;
        }
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { NSLog(@"RemoteIPad management socket failed: %s", strerror(errno)); return false; }
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, management::socketPath, sizeof(address.sun_path));
        if (bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) ||
            chmod(management::socketPath, 0666) || listen(fd, 4)) {
            NSLog(@"RemoteIPad management listen failed: %s", strerror(errno));
            close(fd); return false;
        }
        std::thread([this, fd, processPath] {
            for (;;) {
                int peer = accept(fd, nullptr, nullptr);
                if (peer < 0) {
                    if (errno != EINTR) {
                        NSLog(@"RemoteIPad management accept failed: %s", strerror(errno)); exit(1);
                    }
                    continue;
                }
                @autoreleasepool {
                    int noSignal = 1;
                    if (setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal)) ||
                        fcntl(peer, F_SETFL, O_NONBLOCK) < 0) {
                        NSLog(@"RemoteIPad management peer setup failed: %s", strerror(errno));
                        close(peer); continue;
                    }
                    uid_t uid; gid_t gid;
                    pid_t pid = 0; socklen_t length = sizeof(pid);
                    char path[4096]{};
                    bool authorized = getpeereid(peer, &uid, &gid) == 0 &&
                        (uid == 0 || (uid == 501 &&
                        getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 &&
                        processPath(pid, path, sizeof(path)) > 0 &&
                        strcmp(path, "/Applications/Preferences.app/Preferences") == 0));
                    NSError *error = nil;
                    NSData *data = management::readPacket(peer, &error, authorized ? 3000 : 250);
                    NSDictionary *reply;
                    if (!authorized) {
                        NSLog(@"RemoteIPad unauthorized local management client");
                        reply = @{@"error": @"Unauthorized management client"};
                    } else {
                        NSDictionary *body = dictionary(data, &error);
                        if (!body) {
                            NSLog(@"RemoteIPad invalid management request: %@", error);
                            reply = @{@"error": @"无效的管理请求"};
                        } else reply = manage(body);
                    }
                    if (!management::writePacket(peer, reply, &error))
                        NSLog(@"RemoteIPad management response failed: %@", error);
                    close(peer);
                }
            }
        }).detach();
        return true;
    }
};

int main(int argc, char **argv) {
    @autoreleasepool {
        umask(0077);
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM,terminate);
        signal(SIGINT,terminate);
        if (argc == 2 && strcmp(argv[1],"--prepare-install") == 0) {
            NSString *failure = RIPrepareInstallation();
            if (failure) { NSLog(@"RemoteIPad installation failed: %@",failure); return 1; }
            return 0;
        }
        if (argc != 1) {
            NSLog(@"RemoteIPad invalid daemon arguments"); return 1;
        }
        auto memoryControl = reinterpret_cast<int (*)(uint32_t,int32_t,uint32_t,void *,size_t)>(
            dlsym(RTLD_DEFAULT,"memorystatus_control"));
        struct Limits { int32_t active; uint32_t activeFlags; int32_t inactive; uint32_t inactiveFlags; };
        Limits limits{256,0,256,0}, verified{};
        if (!memoryControl || memoryControl(7,getpid(),0,&limits,sizeof(limits)) ||
            memoryControl(8,getpid(),0,&verified,sizeof(verified)) ||
            verified.active != 256 || verified.inactive != 256) {
            NSLog(@"RemoteIPad cannot verify its bounded video memory budget"); return 1;
        }
        struct stat metadata{};
        if (lstat(configPath.fileSystemRepresentation, &metadata) || metadata.st_uid != 0 ||
            (metadata.st_mode & 077) || !S_ISREG(metadata.st_mode)) {
            NSLog(@"RemoteIPad config missing or not root-owned mode 0600"); return 1;
        }
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:configPath options:0 error:&error];
        NSDictionary *config = dictionary(data, &error);
        if (!config) { NSLog(@"RemoteIPad configuration read failed: %@", error); return 1; }
        NSString *validation = RIValidateConfiguration(config,YES);
        if (validation) { NSLog(@"RemoteIPad invalid configuration: %@",validation); return 1; }
        Manager *manager = new Manager(config);
        if (!manager->start()) return 1;
        manager->snapshot();
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *) {
            @autoreleasepool { manager->snapshot(); }
        }];
        NSLog(@"RemoteIPad manager ready: RDP 3389, NLA, hardware AVC420");
        while (!terminating) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        manager->stop();
    }
    return 0;
}
