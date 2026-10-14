#pragma once
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <chrono>
#include "Paths.hpp"

namespace management {
constexpr const char *socketPath = paths::socket;
constexpr size_t maxPacket = 8192;
inline void failure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RemoteIPadManagement" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
inline bool transfer(int fd, void *buffer, size_t size, bool writing,
                     std::chrono::steady_clock::time_point deadline, NSError **error) {
    auto *bytes = static_cast<uint8_t *>(buffer);
    while (size) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) { failure(error, @"管理请求超时"); return false; }
        pollfd item{fd, short(writing ? POLLOUT : POLLIN), 0};
        int ready = poll(&item, 1, int(remaining));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || (item.revents & (POLLERR | POLLNVAL))) {
            failure(error, ready == 0 ? @"管理请求超时" : @"管理连接不可用"); return false;
        }
        ssize_t count = writing ? send(fd, bytes, size, 0) : recv(fd, bytes, size, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) { failure(error, @"管理连接已关闭"); return false; }
        bytes += count; size -= size_t(count);
    }
    return true;
}
inline NSData *readPacket(int fd, NSError **error, int timeout = 3000) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    uint32_t size;
    if (!transfer(fd, &size, sizeof(size), false, deadline, error)) return nil;
    size = ntohl(size);
    if (!size || size > maxPacket) { failure(error, @"无效的管理消息长度"); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return transfer(fd, data.mutableBytes, size, false, deadline, error) ? data : nil;
}
inline bool writePacket(int fd, NSDictionary *message, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:error];
    if (!data) return false;
    if (data.length > maxPacket) { failure(error, @"管理消息过长"); return false; }
    uint32_t size = htonl(uint32_t(data.length));
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    return transfer(fd, &size, sizeof(size), true, deadline, error) &&
        transfer(fd, const_cast<void *>(data.bytes), data.length, true, deadline, error);
}
inline NSDictionary *request(NSDictionary *message, NSError **error) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { failure(error, @"无法创建管理连接"); return nil; }
    int noSignal = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal)) ||
        fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
        failure(error, @"无法初始化管理连接"); close(fd); return nil;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath, sizeof(address.sun_path));
    if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        if (errno != EINPROGRESS) {
            failure(error, [NSString stringWithFormat:@"管理连接失败：%s", strerror(errno)]);
            close(fd); return nil;
        }
        pollfd item{fd, POLLOUT, 0};
        int connectionError = 0; socklen_t length = sizeof(connectionError);
        if (poll(&item, 1, 3000) <= 0 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &length) ||
            connectionError) {
            failure(error, @"后台管理进程不可用或连接超时"); close(fd); return nil;
        }
    }
    NSData *data = writePacket(fd, message, error) ? readPacket(fd, error) : nil;
    close(fd);
    if (!data) return nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![result isKindOfClass:NSDictionary.class]) {
        failure(error, @"无效的管理响应"); return nil;
    }
    return result;
}
}
