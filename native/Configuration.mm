#import "Configuration.h"
#include "Paths.hpp"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <sys/stat.h>
#include <unistd.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/x509v3.h>
#include <memory>

NSString *RIValidateConfiguration(NSDictionary *config, BOOL requireNla) {
    if (![config isKindOfClass:NSDictionary.class]) return @"配置必须是 JSON 对象";
    id name = config[@"username"], passwordHash = config[@"passwordHash"], salt = config[@"salt"];
    if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 64 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":\\"]].location != NSNotFound ||
        ![salt isKindOfClass:NSString.class] || ![passwordHash isKindOfClass:NSString.class])
        return @"用户名或密码验证材料无效";
    NSData *saltBytes = [[NSData alloc] initWithBase64EncodedString:salt options:0];
    NSData *hashBytes = [[NSData alloc] initWithBase64EncodedString:passwordHash options:0];
    for (NSString *key in @[@"iterations",@"schemaVersion",@"port",@"fps",@"width",@"bitrate"])
        if (![config[key] isKindOfClass:NSNumber.class]) return [NSString stringWithFormat:@"配置字段无效：%@",key];
    int rounds = [config[@"iterations"] intValue], schema = [config[@"schemaVersion"] intValue];
    id enabled = config[@"enabled"];
    if (saltBytes.length != 32 || hashBytes.length != 32 || rounds < 310000 || rounds > 1000000 ||
        (schema != 2 && schema != 3) || ![enabled isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID())
        return @"凭据格式、版本或服务开关无效";
    if (requireNla || schema == 3) {
        id nt = config[@"ntHash"];
        NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
        if (schema != 3 || ![nt isKindOfClass:NSString.class] || [nt length] != 32 ||
            [nt rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound)
            return @"缺少有效 NLA 凭据，请重新生成配置或修改账号";
    }
    struct in_addr address{};
    if (![config[@"bind"] isKindOfClass:NSString.class] ||
        inet_pton(AF_INET,[config[@"bind"] UTF8String],&address) != 1 ||
        [config[@"port"] intValue] != 3389 || [config[@"width"] intValue] != 1440 ||
        ([config[@"fps"] intValue] != 30 && [config[@"fps"] intValue] != 60) ||
        [config[@"bitrate"] intValue] < 500000 || [config[@"bitrate"] intValue] > 20000000)
        return @"RDP 端口必须为 3389，或采集参数不受支持";
    return nil;
}

static NSDictionary *readConfiguration(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL privateFile(NSString *path) {
    struct stat info{};
    return !lstat(path.fileSystemRepresentation,&info) && S_ISREG(info.st_mode) &&
        info.st_uid == 0 && !(info.st_mode & 077);
}

static BOOL addExtension(X509 *certificate, int nid, const char *value) {
    X509V3_CTX context{};
    X509V3_set_ctx(&context,certificate,certificate,nullptr,nullptr,0);
    X509_EXTENSION *extension = X509V3_EXT_conf_nid(nullptr,&context,nid,value);
    if (!extension) return NO;
    int result = X509_add_ext(certificate,extension,-1);
    X509_EXTENSION_free(extension);
    return result == 1;
}

static NSString *prepareCertificate(NSString *directory) {
    NSString *keyPath = [directory stringByAppendingPathComponent:@"server.key"];
    NSString *certPath = [directory stringByAppendingPathComponent:@"server.crt"];
    struct stat info{};
    bool hasKey = lstat(keyPath.fileSystemRepresentation,&info) == 0;
    if (!hasKey && errno != ENOENT) return @"无法检查 TLS 私钥";
    bool hasCert = lstat(certPath.fileSystemRepresentation,&info) == 0;
    if (!hasCert && errno != ENOENT) return @"无法检查 TLS 证书";
    if (hasKey || hasCert) {
        if (!privateFile(keyPath) || !privateFile(certPath)) return @"TLS 文件不完整或权限不安全，不会覆盖现有身份";
        std::unique_ptr<BIO,decltype(&BIO_free)> keyBio(BIO_new_file(keyPath.fileSystemRepresentation,"r"),BIO_free);
        std::unique_ptr<BIO,decltype(&BIO_free)> certBio(BIO_new_file(certPath.fileSystemRepresentation,"r"),BIO_free);
        if (!keyBio || !certBio) return @"无法读取 TLS 身份";
        std::unique_ptr<EVP_PKEY,decltype(&EVP_PKEY_free)> key(PEM_read_bio_PrivateKey(keyBio.get(),nullptr,nullptr,nullptr),EVP_PKEY_free);
        std::unique_ptr<X509,decltype(&X509_free)> cert(PEM_read_bio_X509(certBio.get(),nullptr,nullptr,nullptr),X509_free);
        return key && cert && X509_check_private_key(cert.get(),key.get()) == 1 ? nil : @"TLS 私钥与证书不匹配";
    }
    std::unique_ptr<EVP_PKEY_CTX,decltype(&EVP_PKEY_CTX_free)> generator(EVP_PKEY_CTX_new_id(EVP_PKEY_RSA,nullptr),EVP_PKEY_CTX_free);
    EVP_PKEY *generated = nullptr;
    if (!generator || EVP_PKEY_keygen_init(generator.get()) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(generator.get(),2048) <= 0 ||
        EVP_PKEY_keygen(generator.get(),&generated) <= 0) return @"TLS 密钥生成失败";
    std::unique_ptr<EVP_PKEY,decltype(&EVP_PKEY_free)> key(generated,EVP_PKEY_free);
    std::unique_ptr<X509,decltype(&X509_free)> cert(X509_new(),X509_free);
    unsigned char serial[16]{};
    if (!cert || RAND_bytes(serial,sizeof(serial)) != 1) return @"TLS 证书随机数生成失败";
    serial[0] = (serial[0] & 0x7f) | 1;
    std::unique_ptr<BIGNUM,decltype(&BN_free)> number(BN_bin2bn(serial,sizeof(serial),nullptr),BN_free);
    if (!number || !BN_to_ASN1_INTEGER(number.get(),X509_get_serialNumber(cert.get())) ||
        X509_set_version(cert.get(),2) != 1 || !X509_gmtime_adj(X509_getm_notBefore(cert.get()),-300) ||
        !X509_gmtime_adj(X509_getm_notAfter(cert.get()),825L*24*60*60) ||
        X509_set_pubkey(cert.get(),key.get()) != 1) return @"TLS 证书初始化失败";
    X509_NAME *name = X509_get_subject_name(cert.get());
    if (!name || X509_NAME_add_entry_by_txt(name,"CN",MBSTRING_ASC,
        reinterpret_cast<const unsigned char *>("remoteipad.local"),-1,-1,0) != 1 ||
        X509_set_issuer_name(cert.get(),name) != 1) return @"TLS 证书名称设置失败";
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSetWithArray:@[@"DNS:remoteipad.local",@"IP:127.0.0.1"]];
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces)) return @"无法读取网络地址以创建 TLS 证书";
    for (auto *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) continue;
        char text[INET_ADDRSTRLEN]{};
        auto *address = reinterpret_cast<sockaddr_in *>(item->ifa_addr);
        if (inet_ntop(AF_INET,&address->sin_addr,text,sizeof(text)))
            [names addObject:[NSString stringWithFormat:@"IP:%s",text]];
    }
    freeifaddrs(interfaces);
    NSString *san = [names.array componentsJoinedByString:@","];
    if (!addExtension(cert.get(),NID_basic_constraints,"critical,CA:FALSE") ||
        !addExtension(cert.get(),NID_key_usage,"critical,digitalSignature,keyEncipherment") ||
        !addExtension(cert.get(),NID_ext_key_usage,"serverAuth") ||
        !addExtension(cert.get(),NID_subject_alt_name,san.UTF8String) ||
        X509_sign(cert.get(),key.get(),EVP_sha256()) <= 0) return @"TLS 证书签名失败";
    std::unique_ptr<BIO,decltype(&BIO_free)> keyBio(BIO_new(BIO_s_mem()),BIO_free);
    std::unique_ptr<BIO,decltype(&BIO_free)> certBio(BIO_new(BIO_s_mem()),BIO_free);
    if (!keyBio || !certBio || PEM_write_bio_PrivateKey(keyBio.get(),key.get(),nullptr,nullptr,0,nullptr,nullptr) != 1 ||
        PEM_write_bio_X509(certBio.get(),cert.get()) != 1) return @"TLS 身份序列化失败";
    char *keyBytes = nullptr, *certBytes = nullptr;
    long keyLength = BIO_get_mem_data(keyBio.get(),&keyBytes), certLength = BIO_get_mem_data(certBio.get(),&certBytes);
    NSError *error = nil;
    if (keyLength <= 0 || certLength <= 0 ||
        ![[NSData dataWithBytes:keyBytes length:keyLength] writeToFile:keyPath options:NSDataWritingAtomic error:&error] ||
        ![[NSData dataWithBytes:certBytes length:certLength] writeToFile:certPath options:NSDataWritingAtomic error:&error] ||
        chmod(keyPath.fileSystemRepresentation,0600) || chmod(certPath.fileSystemRepresentation,0600)) {
        NSLog(@"RemoteIPad TLS identity persistence failed: %@",error);
        return @"无法保存 TLS 身份；请检查文件后重试安装";
    }
    NSLog(@"RemoteIPad: created device-specific TLS identity");
    return nil;
}

NSString *RIPrepareInstallation(void) {
    NSString *directory = [NSString stringWithUTF8String:paths::directory];
    NSString *configPath = [NSString stringWithUTF8String:paths::config];
    NSString *seedPath = [NSString stringWithUTF8String:paths::initial];
    struct stat info{};
    if (lstat(directory.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 022)) return @"配置目录不安全";
    if (!privateFile(seedPath)) return @"初始凭据文件缺失或权限不安全";
    NSError *error = nil;
    NSDictionary *seed = readConfiguration(seedPath,&error);
    NSString *failure = RIValidateConfiguration(seed,YES);
    if (failure) return failure;
    NSMutableDictionary *candidate = [seed mutableCopy];
    bool existing = lstat(configPath.fileSystemRepresentation,&info) == 0;
    if (!existing && errno != ENOENT) return @"无法检查现有配置";
    if (existing) {
        if (!privateFile(configPath)) return @"现有配置不是 root 私有普通文件";
        NSDictionary *old = readConfiguration(configPath,&error);
        if (!old) return @"无法读取现有配置，不会重置账号";
        candidate = [old mutableCopy];
        if ([old[@"schemaVersion"] isEqual:@2]) {
            for (NSString *field in @[@"username",@"salt",@"passwordHash",@"iterations"])
                if (![old[field] isEqual:seed[field]]) return @"旧账号与安装包的 NLA 材料不匹配，请先提供匹配配置；不会覆盖原账号";
            candidate[@"ntHash"] = seed[@"ntHash"];
            candidate[@"schemaVersion"] = @3;
        }
        candidate[@"port"] = @3389;
        failure = RIValidateConfiguration(candidate,YES);
        if (failure) return failure;
    }
    failure = prepareCertificate(directory);
    if (failure) return failure;
    NSData *data = [NSJSONSerialization dataWithJSONObject:candidate options:0 error:&error];
    if (!data || ![data writeToFile:configPath options:NSDataWritingAtomic error:&error] ||
        chmod(configPath.fileSystemRepresentation,0600)) {
        NSLog(@"RemoteIPad install configuration persistence failed: %@",error);
        return @"无法保存安装配置";
    }
    NSLog(@"RemoteIPad installation prepared; existing credentials and service switch preserved on upgrade");
    return nil;
}
