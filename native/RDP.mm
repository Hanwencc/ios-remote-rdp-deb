#import "RDP.h"
#include "AVCSample.hpp"
#include "OutputFlow.hpp"
#include "LatencyFlow.hpp"
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/settings.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/server/rdpgfx.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/codec/color.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>
#include <winpr/error.h>
#include <winpr/string.h>
#include <winpr/winsock.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;
static uint64_t millis() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
}
struct Frame {
    std::vector<uint8_t> bytes;
    uint64_t timestamp, queued;
    uint32_t epoch;
    uint16_t width, height;
    bool key;
};
class Transport;
struct PeerContext {
    rdpContext base;
    Transport *server;
    HANDLE channels;
    RdpgfxServerContext *gfx;
    bool gfxOpened, ready, touching, authenticated;
    uint32_t sent, acknowledged, epoch;
    uint64_t lastAck, activatedAt, outputBlockedAt;
    latencyFlow::PendingMove move;
};
static PeerContext *peerContext(freerdp_peer *peer) {
    return reinterpret_cast<PeerContext *>(peer->context);
}
static bool privateFile(NSString *path) {
    struct stat info{};
    return !lstat(path.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
        info.st_uid == 0 && !(info.st_mode & 077);
}
static bool lanAddress(uint32_t network) {
    uint32_t ip = ntohl(network);
    return (ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8 ||
        (ip >> 24) == 127;
}

class Transport {
public:
    __strong RIEngine *engine;
    __strong NSDictionary *config;
    __strong NSString *directory, *failure = @"";
    std::mutex queueMutex, stateMutex, socketMutex;
    std::deque<std::shared_ptr<Frame>> queue;
    size_t queuedBytes = 0;
    std::atomic<bool> stopping{true}, ready{false}, connected{false};
    std::atomic<bool> acknowledgementsSuspended{false};
    std::atomic<bool> tcpNoDelay{false};
    std::atomic<bool> outputBlocked{true}, negotiated{false};
    std::atomic<int> listener{-1}, activeSocket{-1};
    std::atomic<uint64_t> acceptedAt{0}, sentFrames{0}, ackFrames{0}, dropped{0};
    std::atomic<uint64_t> borrowedFrames{0}, copiedFrames{0}, coalescedMoves{0};
    std::atomic<uint64_t> queuedWaitTotal{0}, queuedWaitMax{0};
    std::atomic<bool> frameEventFailed{false};
    HANDLE frameAvailable = nullptr;
    std::thread worker, clientWorker, watchdog;
    bool needsKey = true;

    Transport(NSDictionary *settings, RIEngine *capture, NSString *path)
        : engine(capture), config(settings), directory(path) {}
    ~Transport() { if (frameAvailable) CloseHandle(frameAvailable); }
    void error(NSString *message) {
        std::lock_guard<std::mutex> guard(stateMutex);
        if (![failure isEqual:message]) NSLog(@"RemoteIPad RDP: %@", message);
        failure = [message copy];
    }
    NSString *path(NSString *file) { return [directory stringByAppendingPathComponent:file]; }
    NSDictionary *status() {
        std::lock_guard<std::mutex> guard(stateMutex);
        size_t count, bytes;
        { std::lock_guard<std::mutex> qguard(queueMutex); count = queue.size(); bytes = queuedBytes; }
        uint64_t sent = sentFrames.load();
        return @{@"listening": @(listener.load() >= 0), @"clientConnected": @(connected.load()),
            @"gfxReady": @(ready.load()), @"sentFrames": @(sentFrames.load()),
            @"frameAcknowledgementsSuspended": @(acknowledgementsSuspended.load()),
            @"tcpNoDelay": @(tcpNoDelay.load()),
            @"annexBBorrowedFrames": @(borrowedFrames.load()),
            @"annexBCopiedFrames": @(copiedFrames.load()),
            @"coalescedMouseMoves": @(coalescedMoves.load()),
            @"queuedToSendAverageMs": @(sent ? double(queuedWaitTotal.load()) / sent : 0),
            @"queuedToSendMaxMs": @(queuedWaitMax.load()),
            @"ackFrames": @(ackFrames.load()), @"droppedFrames": @(dropped.load()),
            @"queuedFrames": @(count), @"queuedBytes": @(bytes), @"error": failure};
    }
    void clearQueue() {
        std::lock_guard<std::mutex> guard(queueMutex);
        queue.clear(); queuedBytes = 0; needsKey = true;
        updateCapturePressureLocked();
    }
    void updateCapturePressureLocked() {
        [engine setCapturePressure:unsigned(queue.size()) blocked:!ready || outputBlocked.load()];
        if (frameAvailable && !(queue.empty() ? ResetEvent(frameAvailable) : SetEvent(frameAvailable))) {
            frameEventFailed = true;
            NSLog(@"RemoteIPad RDP: frame notification failed, error=%lu", static_cast<unsigned long>(GetLastError()));
        }
    }
    void setOutputBlocked(bool blocked) {
        outputBlocked = blocked;
        std::lock_guard<std::mutex> guard(queueMutex);
        updateCapturePressureLocked();
    }
    void encoded(CMSampleBufferRef sample, BOOL key, uint64_t timestamp, uint32_t epoch) {
        if (!ready || stopping) return;
        auto frame = std::make_shared<Frame>();
        frame->timestamp = timestamp; frame->queued = millis(); frame->epoch = epoch; frame->key = key;
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
        auto size = CMVideoFormatDescriptionGetDimensions(format);
        if (size.width != 1080 || size.height != 1440) {
            error(@"首版仅支持竖屏 1080×1440，请恢复竖屏后重连");
            shutdownActive(); return;
        }
        frame->width = uint16_t(size.width); frame->height = uint16_t(size.height);
        int nalPrefix = 0;
        size_t parameterCount = 0, length = 0;
        const uint8_t *parameter = nullptr;
        OSStatus result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, 0, &parameter, &length, &parameterCount, &nalPrefix);
        if (result || nalPrefix < 1 || nalPrefix > 4 || parameterCount < 2) {
            error(@"无法读取 H.264 参数集"); shutdownActive(); return;
        }
        if (key) {
            for (size_t i = 0; i < parameterCount; ++i) {
                result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, i, &parameter, &length, nullptr, nullptr);
                if (result || !length || length > avc::maxBytes - 4 ||
                    frame->bytes.size() > avc::maxBytes - length - 4) {
                    error(@"无效的 H.264 参数集"); shutdownActive(); return;
                }
                frame->bytes.insert(frame->bytes.end(), {0,0,0,1});
                frame->bytes.insert(frame->bytes.end(), parameter, parameter + length);
            }
        }
        auto bufferPath = avc::appendBlock(CMSampleBufferGetDataBuffer(sample),
            unsigned(nalPrefix), frame->bytes);
        if (bufferPath == avc::BufferPath::Invalid) {
            error(@"H.264 NAL 格式转换失败"); shutdownActive(); return;
        }
        if (bufferPath == avc::BufferPath::Borrowed) ++borrowedFrames;
        else ++copiedFrames;
        bool requestKey = false;
        {
            std::lock_guard<std::mutex> guard(queueMutex);
            if (!ready || stopping) return;
            if (queue.size() >= 2 || queuedBytes + frame->bytes.size() > avc::maxBytes ||
                (!queue.empty() && frame->queued - queue.front()->queued > 100)) {
                dropped += queue.size();
                queue.clear(); queuedBytes = 0;
                needsKey = true; requestKey = true;
            }
            if (needsKey && !key) ++dropped;
            else {
                needsKey = false;
                queuedBytes += frame->bytes.size();
                queue.push_back(std::move(frame));
            }
            updateCapturePressureLocked();
        }
        if (requestKey) [engine requestKeyframe];
    }
    void shutdownActive() {
        std::lock_guard<std::mutex> guard(socketMutex);
        int fd = activeSocket.load();
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
    }
    static BOOL contextNew(freerdp_peer *peer, rdpContext *base) {
        auto *ctx = reinterpret_cast<PeerContext *>(base);
        ctx->server = static_cast<Transport *>(peer->ContextExtra);
        ctx->channels = WTSOpenServerA(reinterpret_cast<LPSTR>(base));
        if (!ctx->channels || ctx->channels == INVALID_HANDLE_VALUE) return FALSE;
        ctx->gfx = rdpgfx_server_context_new(ctx->channels);
        if (!ctx->gfx) return FALSE;
        ctx->gfx->custom = ctx;
        ctx->gfx->rdpcontext = base;
        ctx->gfx->CapsAdvertise = caps;
        ctx->gfx->FrameAcknowledge = acknowledge;
        return ctx->gfx->Initialize(ctx->gfx, TRUE);
    }
    static void contextFree(freerdp_peer *, rdpContext *base) {
        auto *ctx = reinterpret_cast<PeerContext *>(base);
        if (ctx->gfx) rdpgfx_server_context_free(ctx->gfx);
        if (ctx->channels && ctx->channels != INVALID_HANDLE_VALUE) WTSCloseServer(ctx->channels);
    }
    static BOOL logon(freerdp_peer *peer, const SEC_WINNT_AUTH_IDENTITY *, BOOL automatic) {
        auto *ctx = peerContext(peer);
        if (!automatic) {
            ctx->server->error(@"必须使用 NLA 认证"); return FALSE;
        }
        // FreeRDP 3.32 stores decoded CredSSP credentials in settings, not the legacy identity.
        const char *username = freerdp_settings_get_string(peer->context->settings, FreeRDP_Username);
        NSString *user = username ? [NSString stringWithUTF8String:username] : nil;
        if (!user.length) {
            ctx->server->error(@"NLA 完成但缺少用户身份"); return FALSE;
        }
        if (![user isEqual:ctx->server->config[@"username"]]) {
            ctx->server->error(@"NLA 用户身份不匹配"); return FALSE;
        }
        ctx->authenticated = true;
        NSLog(@"RemoteIPad RDP: NLA authentication completed");
        return TRUE;
    }
    static BOOL capabilities(freerdp_peer *peer) {
        return freerdp_settings_set_uint32(peer->context->settings, FreeRDP_DesktopWidth, 1080) &&
            freerdp_settings_set_uint32(peer->context->settings, FreeRDP_DesktopHeight, 1440);
    }
    static BOOL postConnect(freerdp_peer *peer) {
        return peerContext(peer)->authenticated ? TRUE : FALSE;
    }
    static BOOL activate(freerdp_peer *peer) {
        auto *ctx = peerContext(peer);
        if (!ctx->authenticated) return FALSE;
        if (!freerdp_settings_get_bool(peer->context->settings, FreeRDP_SupportGraphicsPipeline)) {
            ctx->server->error(@"客户端没有协商 RDPGFX"); return FALSE;
        }
        NSLog(@"RemoteIPad RDP: session activated, drdynvc joined=%d",
            WTSVirtualChannelManagerIsChannelJoined(ctx->channels, "drdynvc"));
        ctx->activatedAt = millis();
        return TRUE;
    }
    static UINT caps(RdpgfxServerContext *gfx, const RDPGFX_CAPS_ADVERTISE_PDU *advertise) {
        auto *ctx = static_cast<PeerContext *>(gfx->custom);
        RDPGFX_CAPSET selected{};
        const uint32_t versions[]{RDPGFX_CAPVERSION_107, RDPGFX_CAPVERSION_106,
            RDPGFX_CAPVERSION_105, RDPGFX_CAPVERSION_104, RDPGFX_CAPVERSION_103,
            RDPGFX_CAPVERSION_102, RDPGFX_CAPVERSION_101, RDPGFX_CAPVERSION_10,
            RDPGFX_CAPVERSION_81};
        for (auto version : versions) {
            for (unsigned i = 0; i < advertise->capsSetCount; ++i) {
                auto candidate = advertise->capsSets[i];
                bool avc420 = version == RDPGFX_CAPVERSION_81 ?
                    (candidate.flags & RDPGFX_CAPS_FLAG_AVC420_ENABLED) != 0 :
                    (candidate.flags & RDPGFX_CAPS_FLAG_AVC_DISABLED) == 0;
                if (candidate.version == version && avc420) {
                    selected.version = version; selected.length = 4;
                    selected.flags = version == RDPGFX_CAPVERSION_81 ? RDPGFX_CAPS_FLAG_AVC420_ENABLED : 0;
                    break;
                }
            }
            if (selected.version) break;
        }
        if (!selected.version) {
            ctx->server->error(@"客户端不支持 AVC420 硬件视频链路"); return ERROR_NOT_SUPPORTED;
        }
        RDPGFX_CAPS_CONFIRM_PDU confirm{&selected};
        UINT result = gfx->CapsConfirm(gfx, &confirm);
        MONITOR_DEF monitor{};
        monitor.right = 1079; monitor.bottom = 1439; monitor.flags = 1;
        RDPGFX_RESET_GRAPHICS_PDU reset{1080,1440,1,&monitor};
        RDPGFX_CREATE_SURFACE_PDU surface{1,1080,1440,GFX_PIXEL_FORMAT_XRGB_8888};
        RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU map{1,0,0,0};
        if (!result) result = gfx->ResetGraphics(gfx,&reset);
        if (!result) result = gfx->CreateSurface(gfx,&surface);
        if (!result) result = gfx->MapSurfaceToOutput(gfx,&map);
        if (result) {
            ctx->server->error(@"RDPGFX surface 初始化失败"); return result;
        }
        ctx->ready = true; ctx->lastAck = millis();
        ctx->server->negotiated = true;
        ctx->server->ready = true;
        ctx->server->setOutputBlocked(false);
        ctx->server->clearQueue();
        ctx->server->error(@"");
        [ctx->server->engine setStreaming:YES];
        NSLog(@"RemoteIPad: NLA + RDPGFX AVC420 ready");
        return CHANNEL_RC_OK;
    }
    static UINT acknowledge(RdpgfxServerContext *gfx, const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack) {
        auto *ctx = static_cast<PeerContext *>(gfx->custom);
        if (ack->queueDepth == SUSPEND_FRAME_ACKNOWLEDGEMENT) {
            if (!ctx->server->acknowledgementsSuspended.exchange(true))
                NSLog(@"RemoteIPad RDP: client suspended frame acknowledgements, using bounded TCP output");
            return CHANNEL_RC_OK;
        }
        if (ack->frameId > ctx->sent) {
            NSLog(@"RemoteIPad RDP: invalid frame acknowledgement %u, sent %u", ack->frameId, ctx->sent);
            ctx->server->error(@"客户端帧确认超出已发送范围"); return ERROR_INVALID_DATA;
        }
        if (ctx->server->acknowledgementsSuspended.exchange(false)) {
            ctx->lastAck = millis();
            NSLog(@"RemoteIPad RDP: client resumed frame acknowledgements");
        }
        if (ack->frameId > ctx->acknowledged) {
            ctx->acknowledged = ack->frameId;
            ctx->server->ackFrames = ack->frameId;
            ctx->lastAck = millis();
        }
        return CHANNEL_RC_OK;
    }
    static BOOL injectTouch(PeerContext *ctx, NSString *phase, UINT16 x, UINT16 y) {
        if (!ctx->epoch) return TRUE;
        NSString *error = [ctx->server->engine touch:@{@"phase":phase,@"id":@1,
            @"x":@(double(std::min<unsigned>(x,1079))/1079),
            @"y":@(double(std::min<unsigned>(y,1439))/1439),@"epoch":@(ctx->epoch)}];
        if (error) {
            ctx->server->error(error); [ctx->server->engine releaseTouches];
            ctx->touching = false; ctx->move.pending = false; return FALSE;
        }
        if ([phase isEqual:@"down"]) ctx->touching = true;
        else if ([phase isEqual:@"up"]) ctx->touching = false;
        return TRUE;
    }
    static BOOL flushMove(PeerContext *ctx) {
        UINT16 x, y;
        if (!ctx->move.take(x, y)) return TRUE;
        if (!ctx->touching || !ctx->ready || !ctx->server->ready || !ctx->authenticated) return TRUE;
        return injectTouch(ctx, @"move", x, y);
    }
    static BOOL mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
        auto *ctx = reinterpret_cast<PeerContext *>(input->context);
        if (!ctx->ready || !ctx->server->ready || !ctx->authenticated) return TRUE;
        if (flags & PTR_FLAGS_BUTTON1) {
            if (!flushMove(ctx)) return FALSE;
            bool down = (flags & PTR_FLAGS_DOWN) != 0;
            if (down == ctx->touching) return TRUE;
            return injectTouch(ctx, down ? @"down" : @"up", x, y);
        }
        if ((flags & PTR_FLAGS_MOVE) && ctx->touching && ctx->epoch) {
            if (ctx->move.stage(x, y)) ++ctx->server->coalescedMoves;
        } else if (!flushMove(ctx)) return FALSE;
        return TRUE;
    }
    static BOOL keyboard(rdpInput *input, UINT16 flags, UINT8 code) {
        auto *ctx = reinterpret_cast<PeerContext *>(input->context);
        if (!flushMove(ctx)) return FALSE;
        if (ctx->ready && ctx->server->ready && code == 0x47 &&
            !(flags & KBD_FLAGS_RELEASE) && (flags & KBD_FLAGS_EXTENDED)) {
            NSString *error = [ctx->server->engine home];
            if (error) { ctx->server->error(error); return FALSE; }
        }
        return TRUE;
    }
    static BOOL refresh(rdpContext *base, BYTE, const RECTANGLE_16 *) {
        [reinterpret_cast<PeerContext *>(base)->server->engine requestKeyframe];
        return TRUE;
    }
    static BOOL suppress(rdpContext *base, BYTE allow, const RECTANGLE_16 *) {
        auto *ctx = reinterpret_cast<PeerContext *>(base);
        if (!flushMove(ctx)) return FALSE;
        ctx->server->ready = ctx->ready && allow;
        ctx->touching = false; ctx->move.pending = false;
        [ctx->server->engine releaseTouches];
        ctx->server->setOutputBlocked(!allow);
        ctx->server->clearQueue();
        [ctx->server->engine setStreaming:ctx->ready && allow];
        return TRUE;
    }
    bool configure(freerdp_peer *peer) {
        int noDelay = 0;
        socklen_t noDelayLength = sizeof(noDelay);
        if (getsockopt(activeSocket.load(), IPPROTO_TCP, TCP_NODELAY, &noDelay, &noDelayLength)) {
            NSLog(@"RemoteIPad TCP_NODELAY query failed: %s", strerror(errno));
            error(@"无法读取 RDP TCP 低延迟状态"); return false;
        }
        tcpNoDelay = noDelay != 0;
        auto *settings = peer->context->settings;
        auto *key = freerdp_key_new_from_file_enc(path(@"server.key").fileSystemRepresentation,nullptr);
        auto *cert = freerdp_certificate_new_from_file(path(@"server.crt").fileSystemRepresentation);
        if (!key || !cert) {
            if (key) freerdp_key_free(key);
            if (cert) freerdp_certificate_free(cert);
            error(@"无法加载 RDP TLS 身份"); return false;
        }
        bool result = freerdp_settings_set_pointer_len(settings,FreeRDP_RdpServerRsaKey,key,1);
        if (!result) freerdp_key_free(key);
        bool certificateSet = freerdp_settings_set_pointer_len(settings,FreeRDP_RdpServerCertificate,cert,1);
        if (!certificateSet) freerdp_certificate_free(cert);
        result = result && certificateSet;
        result = result && freerdp_settings_set_string(settings,FreeRDP_NtlmSamFile,path(@"nla.sam").fileSystemRepresentation);
        for (auto setting : {FreeRDP_RdpSecurity,FreeRDP_ExtSecurity,FreeRDP_RemoteFxCodec,
                             FreeRDP_NSCodec,FreeRDP_SupportMultitransport,FreeRDP_GfxAVC444,
                             FreeRDP_GfxAVC444v2,FreeRDP_RedirectClipboard,
                             FreeRDP_WaitForOutputBufferFlush}) {
            result = result && freerdp_settings_set_bool(settings,setting,FALSE);
        }
        for (auto setting : {FreeRDP_TlsSecurity,FreeRDP_NlaSecurity,FreeRDP_Authentication,
                             FreeRDP_SupportGraphicsPipeline,FreeRDP_GfxH264,FreeRDP_RefreshRect,
                             FreeRDP_SuppressOutput}) {
            result = result && freerdp_settings_set_bool(settings,setting,TRUE);
        }
        result = result && freerdp_settings_set_uint32(settings,FreeRDP_ColorDepth,32) &&
            freerdp_settings_set_uint16(settings,FreeRDP_TLSMinVersion,0x0303) &&
            freerdp_settings_set_uint32(settings,FreeRDP_DesktopWidth,1080) &&
            freerdp_settings_set_uint32(settings,FreeRDP_DesktopHeight,1440) &&
            freerdp_settings_set_uint32(settings,FreeRDP_MultifragMaxRequestSize,0x400000);
        peer->Logon = logon; peer->Capabilities = capabilities;
        peer->PostConnect = postConnect; peer->Activate = activate;
        peer->context->input->MouseEvent = mouse;
        peer->context->input->KeyboardEvent = keyboard;
        peer->context->update->RefreshRect = refresh;
        peer->context->update->SuppressOutput = suppress;
        if (!result) error(@"RDP 配置初始化失败");
        return result;
    }
    bool sendFrame(PeerContext *ctx) {
        std::shared_ptr<Frame> frame;
        {
            std::lock_guard<std::mutex> guard(queueMutex);
            if (queue.empty()) return true;
            frame = queue.front(); queue.pop_front(); queuedBytes -= frame->bytes.size();
            updateCapturePressureLocked();
        }
        if (millis() - frame->queued > 150 || (ctx->epoch != frame->epoch && !frame->key)) {
            clearQueue(); ++dropped; [engine requestKeyframe]; return true;
        }
        if (ctx->epoch != frame->epoch) {
            ctx->touching = false; ctx->move.pending = false;
            [engine releaseTouches]; ctx->epoch = frame->epoch;
        }
        RECTANGLE_16 rectangle{0,0,frame->width,frame->height};
        RDPGFX_H264_QUANT_QUALITY quality{};
        // Advisory metadata; VideoToolbox does not expose the actual per-slice QP.
        quality.qp = 22; quality.qualityVal = 78;
        RDPGFX_AVC420_BITMAP_STREAM bitmap{};
        bitmap.meta.numRegionRects = 1; bitmap.meta.regionRects = &rectangle;
        bitmap.meta.quantQualityVals = &quality;
        bitmap.length = uint32_t(frame->bytes.size()); bitmap.data = frame->bytes.data();
        RDPGFX_SURFACE_COMMAND command{};
        command.surfaceId = 1; command.codecId = RDPGFX_CODECID_AVC420;
        command.format = PIXEL_FORMAT_BGRX32; command.width = frame->width; command.height = frame->height;
        command.right = frame->width; command.bottom = frame->height; command.extra = &bitmap;
        if (ctx->sent == ctx->acknowledged) ctx->lastAck = millis();
        uint32_t id = ++ctx->sent;
        RDPGFX_START_FRAME_PDU start{uint32_t(frame->timestamp/1000),id};
        RDPGFX_END_FRAME_PDU end{id};
        UINT result = ctx->gfx->SurfaceFrameCommand(ctx->gfx,&command,&start,&end);
        if (result) { error(@"RDPGFX 视频发送失败"); return false; }
        uint64_t waited = millis() - frame->queued;
        queuedWaitTotal += waited;
        queuedWaitMax = std::max(queuedWaitMax.load(), waited);
        sentFrames = id;
        return true;
    }
    void session(int fd) {
        sentFrames = 0; ackFrames = 0; acknowledgementsSuspended = false;
        queuedWaitTotal = 0; queuedWaitMax = 0;
        freerdp_peer *peer = freerdp_peer_new(fd);
        if (!peer) {
            error(@"无法分配 RDP 会话");
            std::lock_guard<std::mutex> guard(socketMutex);
            close(fd); activeSocket = -1; connected = false; return;
        }
        peer->ContextExtra = this; peer->ContextSize = sizeof(PeerContext);
        peer->ContextNew = contextNew; peer->ContextFree = contextFree;
        bool allocated = freerdp_peer_context_new(peer);
        uint64_t started = millis();
        if (allocated && configure(peer) && peer->Initialize(peer)) {
            auto *ctx = peerContext(peer);
            while (!stopping) {
                @autoreleasepool {
                    if (!ctx->ready && millis() - started > 30000) {
                        error(@"RDP 认证或图形协商超时"); break;
                    }
                    if (ctx->ready && ready && !acknowledgementsSuspended &&
                        ctx->sent > ctx->acknowledged && millis() - ctx->lastAck > 2000) {
                        error(@"客户端停止确认视频帧"); break;
                    }
                    HANDLE events[32]{};
                    if (frameEventFailed) { error(@"RDP 帧就绪通知失败"); break; }
                    DWORD count = peer->GetEventHandles(peer,events,29);
                    if (!count) { error(@"RDP 网络事件不可用"); break; }
                    events[count++] = WTSVirtualChannelManagerGetEventHandle(ctx->channels);
                    HANDLE gfxEvent = rdpgfx_server_get_event_handle(ctx->gfx);
                    if (gfxEvent) events[count++] = gfxEvent;
                    if (ctx->ready && ready && !outputBlocked &&
                        (acknowledgementsSuspended || ctx->sent - ctx->acknowledged < 3))
                        events[count++] = frameAvailable;
                    DWORD wait = WaitForMultipleObjects(count,events,FALSE,5);
                    if (wait == WAIT_FAILED) { error(@"RDP 事件等待失败"); break; }
                    uint64_t inputStarted = millis();
                    unsigned processed = 0;
                    bool okay;
                    do {
                        okay = peer->CheckFileDescriptor(peer);
                        ++processed;
                    } while (okay && latencyFlow::continueInput(processed, inputStarted,
                        millis(), peer->HasMoreToRead(peer)));
                    if (okay) okay = flushMove(ctx);
                    // Opening drdynvc before its static channel is joined makes initialization stick.
                    if (okay && peer->activated)
                        okay = WTSVirtualChannelManagerCheckFileDescriptor(ctx->channels);
                    if (!okay) {
                        if (!stopping) error(ctx->authenticated ?
                            @"RDP 客户端已断开" : @"RDP 客户端已断开或认证失败");
                        break;
                    }
                    if (peer->activated && WTSVirtualChannelManagerGetDrdynvcState(ctx->channels) == DRDYNVC_STATE_READY &&
                        !ctx->gfxOpened) {
                        if (!ctx->gfx->Open(ctx->gfx)) { error(@"无法打开 RDPGFX 通道"); break; }
                        NSLog(@"RemoteIPad RDP: RDPGFX channel requested");
                        ctx->gfxOpened = true;
                    }
                    if (gfxEvent && WaitForSingleObject(gfxEvent,0) == WAIT_OBJECT_0 &&
                        rdpgfx_server_handle_messages(ctx->gfx) != CHANNEL_RC_OK) {
                        error(@"RDPGFX 客户端消息处理失败"); break;
                    }
                    if (peer->DrainOutputBuffer(peer) < 0) {
                        error(@"RDP 发送缓存排空失败"); break;
                    }
                    bool blocked = peer->IsWriteBlocked(peer);
                    bool canSend = ctx->ready && ready && !blocked &&
                        (acknowledgementsSuspended || ctx->sent - ctx->acknowledged < 3);
                    setOutputBlocked(!canSend);
                    if (outputFlow::expired(ctx->outputBlockedAt, ctx->ready && ready && blocked, millis())) {
                        error(@"RDP 发送缓存持续积压超过 2 秒，已关闭慢连接"); break;
                    }
                    if (canSend) {
                        okay = sendFrame(ctx);
                        if (!okay) break;
                        setOutputBlocked(!acknowledgementsSuspended && ctx->sent - ctx->acknowledged >= 3);
                    }
                }
            }
        } else error(@"RDP 会话初始化失败");
        ready = false;
        setOutputBlocked(true);
        [engine setStreaming:NO]; clearQueue();
        {
            std::lock_guard<std::mutex> guard(socketMutex);
            activeSocket = -1;
            peer->Close(peer);
            if (allocated) freerdp_peer_context_free(peer);
            freerdp_peer_free(peer);
        }
        connected = false;
        acknowledgementsSuspended = false;
    }
    NSString *start() {
        static std::once_flag once;
        static bool initialized = false;
        std::call_once(once, [] {
            WSADATA data{};
            initialized = WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) &&
                winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT) && WSAStartup(MAKEWORD(2,2),&data) == 0;
        });
        if (!initialized) return @"FreeRDP/WinPR 初始化失败";
        if (!privateFile(path(@"server.key")) || !privateFile(path(@"server.crt")))
            return @"RDP TLS 文件缺失或权限不安全";
        NSString *name = config[@"username"], *hash = config[@"ntHash"];
        if (![name isKindOfClass:NSString.class] || !name.length || name.length > 64 ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":\r\n\\"]].location != NSNotFound ||
            ![hash isKindOfClass:NSString.class] || hash.length != 32 ||
            [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound)
            return @"有效的 NLA 凭据缺失，需要安全迁移原密码";
        NSError *fileError = nil;
        NSString *sam = [NSString stringWithFormat:@"%@:::%@:\n",name,hash];
        if (![sam writeToFile:path(@"nla.sam") atomically:YES encoding:NSUTF8StringEncoding error:&fileError] ||
            chmod(path(@"nla.sam").fileSystemRepresentation,0600)) {
            NSLog(@"RemoteIPad SAM write failed: %@",fileError); return @"无法写入受保护的 NLA 数据库";
        }
        int fd = socket(AF_INET,SOCK_STREAM,0);
        if (fd < 0) return @"无法创建 RDP socket";
        int reuse = 1;
        setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
        sockaddr_in address{};
        address.sin_family = AF_INET; address.sin_port = htons(3389);
        if (inet_pton(AF_INET,[config[@"bind"] UTF8String],&address.sin_addr) != 1 ||
            bind(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address)) || listen(fd,4) ||
            fcntl(fd,F_SETFL,O_NONBLOCK) < 0) {
            NSLog(@"RemoteIPad RDP bind failed: %s",strerror(errno)); close(fd);
            return @"无法监听 RDP 3389，请检查地址或端口占用";
        }
        if (!frameAvailable) frameAvailable = CreateEvent(nullptr, TRUE, FALSE, nullptr);
        if (!frameAvailable) { close(fd); return @"无法创建 RDP 帧就绪通知"; }
        frameEventFailed = false;
        listener = fd; stopping = false; error(@"");
        [engine setEncodedHandler:^(CMSampleBufferRef sample, BOOL key, uint64_t timestamp, uint32_t epoch, uint32_t) {
            this->encoded(sample,key,timestamp,epoch);
        }];
        worker = std::thread([this,fd] {
            while (!stopping) {
                @autoreleasepool {
                    pollfd item{fd,POLLIN,0};
                    int result = poll(&item,1,100);
                    if (result < 0 && errno == EINTR) continue;
                    if (result < 0) { error(@"RDP listener 事件失败"); break; }
                    if (!(item.revents & POLLIN)) continue;
                    sockaddr_in remote{}; socklen_t length = sizeof(remote);
                    int peer = accept(fd,reinterpret_cast<sockaddr *>(&remote),&length);
                    if (peer < 0) {
                        if (errno != EAGAIN && errno != EINTR) error(@"RDP 接受连接失败");
                        continue;
                    }
                    if (!lanAddress(remote.sin_addr.s_addr)) {
                        NSLog(@"RemoteIPad: rejected non-LAN RDP peer"); close(peer); continue;
                    }
                    if (connected) {
                        NSLog(@"RemoteIPad: rejected additional RDP client"); close(peer); continue;
                    }
                    int noSignal = 1;
                    if (setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal))) {
                        error(@"RDP socket 初始化失败"); close(peer); continue;
                    }
                    if (clientWorker.joinable()) clientWorker.join();
                    {
                        std::lock_guard<std::mutex> guard(socketMutex);
                        activeSocket = peer; negotiated = false; acceptedAt = millis(); connected = true;
                    }
                    clientWorker = std::thread([this,peer] { @autoreleasepool { session(peer); } });
                }
            }
            listener = -1; close(fd);
        });
        watchdog = std::thread([this] {
            while (!stopping) {
                if (latencyFlow::handshakeExpired(connected, negotiated, acceptedAt.load(), millis())) {
                    @autoreleasepool { error(@"RDP 认证或图形协商超时"); }
                    shutdownActive();
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
        });
        return nil;
    }
    void stop() {
        stopping = true; ready = false;
        shutdownActive();
        if (worker.joinable()) worker.join();
        shutdownActive();
        if (clientWorker.joinable()) clientWorker.join();
        if (watchdog.joinable()) watchdog.join();
        [engine setStreaming:NO];
        [engine setEncodedHandler:nil];
        clearQueue();
    }
};
}

@interface RIRDPServer () {
    std::unique_ptr<Transport> _transport;
}
@end
@implementation RIRDPServer
- (instancetype)initWithConfig:(NSDictionary *)config engine:(RIEngine *)engine directory:(NSString *)directory {
    if (!(self = [super init])) return nil;
    _transport = std::make_unique<Transport>(config,engine,directory);
    return self;
}
- (NSString *)start { return _transport->start(); }
- (void)stop { _transport->stop(); }
- (NSDictionary *)status { return _transport->status(); }
- (void)dealloc { _transport->stop(); }
@end
